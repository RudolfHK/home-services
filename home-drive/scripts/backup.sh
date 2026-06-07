#!/usr/bin/env bash
# backup.sh — Nightly backup of FileBrowser data and CouchDB databases.
#
# What it does:
#   1. Dumps every CouchDB database to JSON using curl.
#   2. Tars FileBrowser data, the FileBrowser SQLite DB, and the config files.
#   3. Creates a timestamped archive in $BACKUP_DEST.
#   4. Rotates old backups (keeps the last $BACKUP_KEEP archives).
#   5. Optionally pushes to an rclone remote.
#
# Add to crontab (run `crontab -e`):
#   30 2 * * * /home/pi/homedrive-pi/scripts/backup.sh >> /var/log/homedrive-backup.log 2>&1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# ── Load .env ────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found."; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ── Configuration (can override via .env) ────────────────────────────────────
BACKUP_DEST="${BACKUP_DEST:-${DATA_PATH}/backups}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="/tmp/homedrive-backup-${TIMESTAMP}"
ARCHIVE_NAME="homedrive_${TIMESTAMP}.tar.gz"

# CouchDB connection (through localhost — the Tailscale network namespace)
COUCH_URL="http://localhost:5984"
COUCH_AUTH="${COUCHDB_USER}:${COUCHDB_PASSWORD}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "$(date '+%F %T') ${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "$(date '+%F %T') ${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "$(date '+%F %T') ${RED}[ERROR]${NC} $*" >&2; exit 1; }

info "======== Starting backup (${TIMESTAMP}) ========"

# ── 1. Preparation ────────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR/couchdb" "$WORK_DIR/filebrowser" "$BACKUP_DEST"

# ── 2. Dump CouchDB databases ─────────────────────────────────────────────────
info "Dumping CouchDB databases…"

# Get list of all databases (excluding system DBs that start with _)
DBS=$(docker exec homedrive-couchdb \
  curl -sf -u "$COUCH_AUTH" "$COUCH_URL/_all_dbs" \
  | tr -d '[]"' | tr ',' '\n' | grep -v '^_') || {
    warn "Could not list CouchDB databases — is the container running?"
    DBS=""
  }

for DB in $DBS; do
  info "  Dumping database: $DB"
  # Export all documents as a JSON dump (includes attachments as base64)
  docker exec homedrive-couchdb \
    curl -sf -u "$COUCH_AUTH" \
    "${COUCH_URL}/${DB}/_all_docs?include_docs=true&attachments=true" \
    > "$WORK_DIR/couchdb/${DB}.json" || warn "  Failed to dump $DB — skipping."
done

# Also dump the replication state
docker exec homedrive-couchdb \
  curl -sf -u "$COUCH_AUTH" "${COUCH_URL}/_replicator/_all_docs?include_docs=true" \
  > "$WORK_DIR/couchdb/_replicator.json" 2>/dev/null || true

info "CouchDB dump complete."

# ── 3. Backup FileBrowser SQLite DB ───────────────────────────────────────────
info "Backing up FileBrowser database…"
FB_DB="${DATA_PATH}/filebrowser/filebrowser.db"
if [[ -f "$FB_DB" ]]; then
  # Use SQLite's .backup command for a consistent hot backup
  sqlite3 "$FB_DB" ".backup '$WORK_DIR/filebrowser/filebrowser.db'" 2>/dev/null \
    || cp "$FB_DB" "$WORK_DIR/filebrowser/filebrowser.db"
  info "FileBrowser DB backed up."
else
  warn "FileBrowser DB not found at $FB_DB — skipping."
fi

# ── 4. Backup FileBrowser files (optional — large, comment out if not needed) ─
# info "Backing up FileBrowser files… (may take a while for large drives)"
# rsync -a --no-compress "${DATA_PATH}/files/" "$WORK_DIR/files/"

# ── 5. Backup config files ────────────────────────────────────────────────────
info "Backing up config files…"
cp -r "$PROJECT_DIR/config" "$WORK_DIR/config"
# Do NOT copy .env (contains secrets) — document how to restore manually

# ── 6. Create compressed archive ──────────────────────────────────────────────
info "Creating archive ${BACKUP_DEST}/${ARCHIVE_NAME}…"
tar -czf "${BACKUP_DEST}/${ARCHIVE_NAME}" -C "$(dirname "$WORK_DIR")" "$(basename "$WORK_DIR")"
info "Archive size: $(du -sh "${BACKUP_DEST}/${ARCHIVE_NAME}" | cut -f1)"

# ── 7. Rotate old backups ─────────────────────────────────────────────────────
info "Rotating backups (keeping last ${BACKUP_KEEP})…"
# List archives sorted by modification time (oldest first), delete excess
ls -1t "${BACKUP_DEST}"/homedrive_*.tar.gz 2>/dev/null \
  | tail -n +"$((BACKUP_KEEP + 1))" \
  | xargs -r rm --
info "Rotation complete."

# ── 8. Optional: push to rclone remote ───────────────────────────────────────
if [[ -n "${RCLONE_REMOTE:-}" ]]; then
  info "Pushing to rclone remote '${RCLONE_REMOTE}'…"
  rclone copy "${BACKUP_DEST}/${ARCHIVE_NAME}" "${RCLONE_REMOTE}:homedrive-backups/" \
    --log-level INFO || warn "rclone push failed — archive still saved locally."
fi

# ── 9. Cleanup temp directory ─────────────────────────────────────────────────
rm -rf "$WORK_DIR"

info "======== Backup complete: ${BACKUP_DEST}/${ARCHIVE_NAME} ========"
