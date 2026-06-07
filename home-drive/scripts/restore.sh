#!/usr/bin/env bash
# restore.sh — Restore a Home Drive backup archive.
#
# Usage:
#   bash scripts/restore.sh /mnt/data/backups/homedrive_20240101_023000.tar.gz
#
# What it does:
#   1. Extracts the archive to a temp directory.
#   2. Restores each CouchDB database from the JSON dump (PUT _bulk_docs).
#   3. Restores the FileBrowser SQLite database.
#   4. Prints instructions for restoring config files and .env manually.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found."; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "$(date '+%F %T') ${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "$(date '+%F %T') ${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "$(date '+%F %T') ${RED}[ERROR]${NC} $*" >&2; exit 1; }

ARCHIVE="${1:-}"
[[ -n "$ARCHIVE" ]] || error "Usage: $0 <path-to-archive.tar.gz>"
[[ -f "$ARCHIVE" ]] || error "Archive not found: $ARCHIVE"

WORK_DIR="/tmp/homedrive-restore-$$"
COUCH_URL="http://localhost:5984"
COUCH_AUTH="${COUCHDB_USER}:${COUCHDB_PASSWORD}"

info "======== Starting restore from $(basename "$ARCHIVE") ========"

warn "This will OVERWRITE existing CouchDB data and the FileBrowser database."
read -rp "Continue? [yes/N] " confirm
[[ "$confirm" == "yes" ]] || { info "Aborted."; exit 0; }

# ── 1. Extract archive ────────────────────────────────────────────────────────
info "Extracting archive…"
mkdir -p "$WORK_DIR"
tar -xzf "$ARCHIVE" -C "$WORK_DIR" --strip-components=1
info "Extracted to $WORK_DIR"

# ── 2. Check the stack is running ─────────────────────────────────────────────
docker compose -f "$PROJECT_DIR/docker-compose.yml" ps couchdb | grep -q "running" \
  || error "CouchDB container is not running. Start the stack first: docker compose up -d"

# ── 3. Restore CouchDB databases ──────────────────────────────────────────────
info "Restoring CouchDB databases…"

for JSON_FILE in "$WORK_DIR"/couchdb/*.json; do
  DB=$(basename "$JSON_FILE" .json)
  [[ "$DB" == "_replicator" ]] && continue  # skip, CouchDB creates this itself

  info "  Restoring database: $DB"

  # Create the database if it doesn't exist
  docker exec homedrive-couchdb \
    curl -sf -X PUT -u "$COUCH_AUTH" "${COUCH_URL}/${DB}" \
    -o /dev/null || true

  # Build a _bulk_docs payload from the all_docs export.
  # Strip _rev from each doc so CouchDB assigns new revisions.
  DOCS=$(jq '[.rows[].doc | del(._rev)]' "$JSON_FILE")
  PAYLOAD="{\"docs\": ${DOCS}, \"new_edits\": true}"

  echo "$PAYLOAD" | docker exec -i homedrive-couchdb \
    curl -sf -X POST -u "$COUCH_AUTH" \
    -H "Content-Type: application/json" \
    "${COUCH_URL}/${DB}/_bulk_docs" \
    --data-binary @- \
    -o /dev/null \
    || warn "  Failed to restore $DB — check CouchDB logs."
done

info "CouchDB restore complete."

# ── 4. Restore FileBrowser database ───────────────────────────────────────────
FB_BACKUP="$WORK_DIR/filebrowser/filebrowser.db"
FB_DEST="${DATA_PATH}/filebrowser/filebrowser.db"

if [[ -f "$FB_BACKUP" ]]; then
  info "Restoring FileBrowser database…"

  # Stop FileBrowser while swapping the DB to avoid corruption
  docker compose -f "$PROJECT_DIR/docker-compose.yml" stop filebrowser

  cp "$FB_BACKUP" "$FB_DEST"
  chown "${PUID}:${PGID}" "$FB_DEST"

  docker compose -f "$PROJECT_DIR/docker-compose.yml" start filebrowser
  info "FileBrowser database restored and service restarted."
else
  warn "No FileBrowser database found in archive — skipping."
fi

# ── 5. Config files ───────────────────────────────────────────────────────────
if [[ -d "$WORK_DIR/config" ]]; then
  info "Config files found in archive at $WORK_DIR/config"
  info "Review and copy them manually if needed:"
  ls -la "$WORK_DIR/config/"
fi

# ── 6. Cleanup ────────────────────────────────────────────────────────────────
rm -rf "$WORK_DIR"

echo ""
info "======== Restore complete ========"
echo ""
echo "  IMPORTANT: If you are restoring to a fresh install:"
echo "  - Re-create your .env file with the original secrets."
echo "  - Re-run scripts/install.sh to bring up the full stack."
echo "  - Re-run this script after the stack is up."
