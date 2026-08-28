#!/usr/bin/env bash
# restore.sh — Restore a Home Drive backup archive.
#
# Usage:
#   bash scripts/restore.sh /mnt/data/backups/homedrive_20240101_023000.tar.gz
#
# What it does:
#   1. Extracts the archive to a staging directory on the data drive.
#   2. Restores each CouchDB database from its JSON dump, in batches.
#   3. Restores the FileBrowser SQLite database (with the service stopped).
#   4. Points you at the config files for manual review.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found."; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "$(date '+%F %T') ${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "$(date '+%F %T') ${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "$(date '+%F %T') ${RED}[ERROR]${NC} $*" >&2; exit 1; }

ARCHIVE="${1:-}"
[[ -n "$ARCHIVE" ]] || error "Usage: $0 <path-to-archive.tar.gz>"
[[ -f "$ARCHIVE" ]] || error "Archive not found: $ARCHIVE"

DATA_PATH="${DATA_PATH:?DATA_PATH is not set in .env}"
COUCH_URL="http://127.0.0.1:5984"
COUCH_CONTAINER="homedrive-couchdb"
# Documents pushed per _bulk_docs request. A vault with inlined attachments can
# be gigabytes; one giant POST would exhaust RAM on the Pi and time out.
BATCH_SIZE="${RESTORE_BATCH_SIZE:-200}"
FAILED=0

for cmd in docker tar jq; do
  command -v "$cmd" &>/dev/null || error "Required command not found on the host: $cmd"
done

info "======== Starting restore from $(basename "$ARCHIVE") ========"

warn "This will OVERWRITE existing CouchDB data and the FileBrowser database."
if [[ -t 0 ]]; then
  read -rp "Continue? [yes/N] " confirm
  [[ "$confirm" == "yes" ]] || { info "Aborted."; exit 0; }
else
  [[ "${HOMEDRIVE_ASSUME_YES:-false}" == "true" ]] \
    || error "No TTY to confirm on. Set HOMEDRIVE_ASSUME_YES=true to run unattended."
fi

# ── 1. Check the stack is running ─────────────────────────────────────────────
# Done before extracting, so a stopped stack fails in a second rather than after
# unpacking gigabytes.
docker inspect -f '{{.State.Running}}' "$COUCH_CONTAINER" 2>/dev/null | grep -q true \
  || error "$COUCH_CONTAINER is not running. Start the stack first: docker compose up -d"
docker exec "$COUCH_CONTAINER" sh -c 'command -v curl >/dev/null' \
  || error "curl is not available inside $COUCH_CONTAINER — cannot restore."

# ── 2. Extract the archive ────────────────────────────────────────────────────
# Staged on the data drive, not /tmp: /tmp is commonly a RAM-backed tmpfs on
# Raspberry Pi OS and a vault dump will not fit in it.
STAGING_ROOT="${DATA_PATH}/tmp"
mkdir -p "$STAGING_ROOT"
WORK_DIR="$(mktemp -d "${STAGING_ROOT}/homedrive-restore.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
  docker exec "$COUCH_CONTAINER" rm -f /tmp/homedrive-restore-batch.json >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

info "Extracting archive…"
tar -xzf "$ARCHIVE" -C "$WORK_DIR"

# Archives written by older versions of backup.sh wrapped everything in a single
# homedrive-backup-<timestamp>/ directory; current ones are flat. Handle both.
if [[ ! -d "$WORK_DIR/couchdb" ]]; then
  INNER="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [[ -n "$INNER" && -d "$INNER/couchdb" ]]; then
    info "Archive uses the legacy wrapper-directory layout."
    WORK_DIR="$INNER"
  else
    error "Archive does not contain a couchdb/ directory — is this a Home Drive backup?"
  fi
fi
info "Extracted to $WORK_DIR"

# ── CouchDB helper ────────────────────────────────────────────────────────────
# Credentials go to curl via a config file on stdin, never as `-u` on the
# command line, so they do not show up in the host's process list. That leaves
# stdin unavailable for the request body, so payloads are copied into the
# container as a file instead.
couch_curl() {
  local esc_user esc_pass
  esc_user="${COUCHDB_USER//\\/\\\\}"; esc_user="${esc_user//\"/\\\"}"
  esc_pass="${COUCHDB_PASSWORD//\\/\\\\}"; esc_pass="${esc_pass//\"/\\\"}"
  printf 'user = "%s:%s"\n' "$esc_user" "$esc_pass" \
    | docker exec -i "$COUCH_CONTAINER" curl -sS -f -K - "$@"
}

# ── 3. Restore CouchDB databases ──────────────────────────────────────────────
info "Restoring CouchDB databases…"

shopt -s nullglob
DUMPS=("$WORK_DIR"/couchdb/*.json)
shopt -u nullglob
[[ "${#DUMPS[@]}" -gt 0 ]] || warn "No CouchDB dumps found in the archive."

for JSON_FILE in "${DUMPS[@]}"; do
  DB="$(basename "$JSON_FILE" .json)"
  # System databases are recreated by CouchDB itself, and _users in particular
  # cannot be restored this way (its password hashes are instance-specific).
  [[ "$DB" == _* ]] && { info "  Skipping system database: $DB"; continue; }

  info "  Restoring database: $DB"

  if ! jq -e 'has("rows")' "$JSON_FILE" >/dev/null 2>&1; then
    warn "  $JSON_FILE is not a valid CouchDB dump — skipping."
    FAILED=$((FAILED + 1))
    continue
  fi

  # Create the database if it does not exist (412 = already there).
  couch_curl -o /dev/null -X PUT "${COUCH_URL}/${DB}" >/dev/null 2>&1 || true

  # Normalise the documents:
  #   - drop rows whose .doc is null (deleted docs still appear in _all_docs)
  #   - drop _rev so CouchDB assigns fresh revisions
  #   - reduce each attachment to {content_type, data}: the dump also carries
  #     revpos/digest/length, which _bulk_docs rejects alongside inline data
  CLEAN="$WORK_DIR/.clean-${DB}.json"
  jq '[ .rows[].doc
        | select(. != null)
        | del(._rev)
        | if has("_attachments") then
            ._attachments |= with_entries(
              .value |= {content_type: .content_type, data: .data}
            )
          else . end
      ]' "$JSON_FILE" > "$CLEAN"

  TOTAL="$(jq 'length' "$CLEAN")"
  info "    $TOTAL document(s) in $BATCH_SIZE-document batches"

  DB_FAILED=0
  for (( OFFSET=0; OFFSET<TOTAL; OFFSET+=BATCH_SIZE )); do
    BATCH="$WORK_DIR/.batch.json"
    jq -c --argjson o "$OFFSET" --argjson n "$BATCH_SIZE" \
      '{docs: .[$o:($o + $n)], new_edits: true}' "$CLEAN" > "$BATCH"

    docker cp "$BATCH" "${COUCH_CONTAINER}:/tmp/homedrive-restore-batch.json" >/dev/null

    if ! couch_curl -o /dev/null \
          -X POST \
          -H "Content-Type: application/json" \
          --data-binary @/tmp/homedrive-restore-batch.json \
          "${COUCH_URL}/${DB}/_bulk_docs"
    then
      warn "    Batch at offset $OFFSET failed."
      DB_FAILED=$((DB_FAILED + 1))
    fi
  done

  if [[ "$DB_FAILED" -gt 0 ]]; then
    warn "  $DB restored with $DB_FAILED failed batch(es) — check: docker compose logs couchdb"
    FAILED=$((FAILED + 1))
  else
    info "  $DB restored."
  fi

  rm -f "$CLEAN" "$WORK_DIR/.batch.json"
done

info "CouchDB restore complete."

# ── 4. Restore the FileBrowser database ───────────────────────────────────────
FB_BACKUP="$WORK_DIR/filebrowser/filebrowser.db"
FB_DEST="${DATA_PATH}/filebrowser/filebrowser.db"

if [[ -f "$FB_BACKUP" ]]; then
  info "Restoring the FileBrowser database…"

  # Stop FileBrowser while swapping the DB to avoid corrupting a live SQLite file.
  "${COMPOSE[@]}" stop filebrowser

  # Keep the current database around — if the archive turns out to be stale,
  # this is the only way back to the existing users and shares.
  if [[ -f "$FB_DEST" ]]; then
    FB_PREV="${FB_DEST}.pre-restore.$(date +%Y%m%d%H%M%S)"
    cp "$FB_DEST" "$FB_PREV"
    info "Previous database saved as $(basename "$FB_PREV")"
  fi

  cp "$FB_BACKUP" "$FB_DEST"
  # chown needs root unless we already own the file; do not fail the restore
  # over it, but say so loudly because FileBrowser runs as PUID:PGID.
  chown "${PUID}:${PGID}" "$FB_DEST" 2>/dev/null \
    || sudo chown "${PUID}:${PGID}" "$FB_DEST" 2>/dev/null \
    || warn "Could not chown $FB_DEST to ${PUID}:${PGID} — fix it manually or FileBrowser cannot write."

  "${COMPOSE[@]}" start filebrowser
  info "FileBrowser database restored and the service restarted."
else
  warn "No FileBrowser database found in the archive — skipping."
fi

# ── 5. Config files ───────────────────────────────────────────────────────────
if [[ -d "$WORK_DIR/config" ]]; then
  CONFIG_KEEP="${DATA_PATH}/restored-config-$(date +%Y%m%d%H%M%S)"
  cp -r "$WORK_DIR/config" "$CONFIG_KEEP"
  info "Config files from the archive kept at $CONFIG_KEEP for review."
  info "Diff them against $PROJECT_DIR/config before copying anything over."
fi

echo ""
if [[ "$FAILED" -gt 0 ]]; then
  warn "======== Restore finished with ${FAILED} problem(s) ========"
else
  info "======== Restore complete ========"
fi
echo ""
echo "  If you are restoring onto a fresh install:"
echo "  - .env is deliberately NOT in the archive. Recreate it with the original"
echo "    TS_AUTHKEY, COUCHDB_PASSWORD and FILEBROWSER_ADMIN_PASSWORD."
echo "  - Run scripts/install.sh to bring up the stack, then re-run this script."
echo "  - CouchDB users other than the admin are not restored; recreate them in"
echo "    Fauxton at https://<host>.<tailnet>.ts.net:8443/_utils/"
echo ""
[[ "$FAILED" -eq 0 ]] || exit 1
