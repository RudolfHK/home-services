#!/usr/bin/env bash
# backup.sh — Nightly backup of Nextcloud.
#
# What it does:
#   1. Dumps the PostgreSQL database.
#   2. Archives Nextcloud's config/ directory (config.php, the instance id,
#      the password-reset secret).
#   3. Optionally includes the Nextcloud user files (BACKUP_INCLUDE_NEXTCLOUD_DATA=true).
#   4. Archives this project's own config/ directory.
#   5. Creates a timestamped archive in $BACKUP_DEST.
#   6. Rotates old backups (keeps the last $BACKUP_KEEP archives).
#   7. Optionally pushes to an rclone remote.
#
# Exits non-zero if anything failed to back up, so cron mail actually tells
# you the backup is not trustworthy.
#
# Add to crontab (run `crontab -e`):
#   30 2 * * * /home/pi/home-services/home-drive/scripts/backup.sh >> /var/log/homedrive-backup.log 2>&1
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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "$(date '+%F %T') ${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "$(date '+%F %T') ${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "$(date '+%F %T') ${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Configuration (can override via .env) ────────────────────────────────────
DATA_PATH="${DATA_PATH:?DATA_PATH is not set in .env}"
BACKUP_DEST="${BACKUP_DEST:-${DATA_PATH}/backups}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_NAME="homedrive_${TIMESTAMP}.tar.gz"
NC_APP="homedrive-nextcloud-app"
NC_DB="homedrive-nextcloud-db"
NC_MAINTENANCE_ON=false
BACKUP_INCLUDE_NEXTCLOUD_DATA="${BACKUP_INCLUDE_NEXTCLOUD_DATA:-false}"

# Staging goes on the data drive, NOT /tmp. On Raspberry Pi OS /tmp is often a
# tmpfs sized from RAM, and a full-data dump can be larger than that; the
# backup would OOM the box rather than fail politely.
STAGING_ROOT="${DATA_PATH}/tmp"
FAILED=0

info "======== Starting backup (${TIMESTAMP}) ========"

# ── 1. Preflight ──────────────────────────────────────────────────────────────
for cmd in docker tar; do
  command -v "$cmd" &>/dev/null || error "Required command not found on the host: $cmd"
done

nc_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}
nc_occ() {
  docker exec -u www-data "$NC_APP" php /var/www/html/occ "$@"
}

nc_running "$NC_APP" && nc_running "$NC_DB" \
  || error "Nextcloud is not running. Start the stack first: docker compose up -d"

mkdir -p "$STAGING_ROOT" "$BACKUP_DEST"
chmod 700 "$BACKUP_DEST" 2>/dev/null || true

WORK_DIR="$(mktemp -d "${STAGING_ROOT}/homedrive-backup-${TIMESTAMP}.XXXXXX")"
# Always clean up the staging directory, including on failure or Ctrl-C,
# otherwise a failed nightly run silently fills the data drive.
cleanup() {
  # Leaving Nextcloud in maintenance mode would take the drive offline until
  # somebody noticed by hand, so this runs on failure and on Ctrl-C too.
  if [[ "${NC_MAINTENANCE_ON:-false}" == "true" ]]; then
    nc_occ maintenance:mode --off >/dev/null 2>&1 \
      || warn "Could not take Nextcloud out of maintenance mode. Do it by hand:
    docker exec -u www-data $NC_APP php occ maintenance:mode --off"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK_DIR/nextcloud"

# ── 2. Backup Nextcloud ───────────────────────────────────────────────────────
# The database is not optional even when the files are excluded: without it the
# files are a directory tree with no accounts, shares, versions or locks
# attached, and Nextcloud will not adopt them.
info "Backing up Nextcloud…"

# Maintenance mode blocks writes for the duration, so the dump is a coherent
# snapshot rather than a moving target. With the data files excluded (the
# default) this is a matter of seconds.
if nc_occ maintenance:mode --on >/dev/null 2>&1; then
  NC_MAINTENANCE_ON=true
  info "  Nextcloud is in maintenance mode."
else
  warn "  Could not enable maintenance mode, dumping a live database."
fi

# The password is written to the container's stdin rather than passed as
# `-e PGPASSWORD=…`: every argument of a docker exec is visible in the host's
# process list, and this runs nightly from cron.
info "  Dumping the PostgreSQL database…"
NC_DUMP="$WORK_DIR/nextcloud/nextcloud-db.sql"
if printf '%s' "${NEXTCLOUD_DB_PASSWORD:-}" \
     | docker exec -i "$NC_DB" sh -c \
         'PGPASSWORD="$(cat)" exec pg_dump -h 127.0.0.1 -U "$1" -d "$2" --clean --if-exists' \
         _ "${NEXTCLOUD_DB_USER:-nextcloud}" "${NEXTCLOUD_DB_NAME:-nextcloud}" \
     > "$NC_DUMP" 2>/dev/null
then
  # A shell redirect creates the file even when pg_dump dies mid-stream, so an
  # archived dump that is silently truncated is a real possibility. pg_dump
  # writes this marker as its very last line.
  if tail -n 5 "$NC_DUMP" | grep -q 'PostgreSQL database dump complete'; then
    info "  Database dumped: $(du -h "$NC_DUMP" | cut -f1)"
  else
    warn "  The database dump is truncated, discarding it."
    rm -f "$NC_DUMP"
    FAILED=$((FAILED + 1))
  fi
else
  warn "  pg_dump failed."
  rm -f "$NC_DUMP"
  FAILED=$((FAILED + 1))
fi

# config/ holds config.php with the database password, the instance id and the
# secret used for password resets; a restore without it is not a restore.
# Read out through the container: on the host the directory is owned by the
# web user and mode 750, which the backup user cannot read.
info "  Archiving config/…"
if docker exec "$NC_APP" tar -cf - -C /var/www/html config \
     > "$WORK_DIR/nextcloud/config.tar" 2>/dev/null; then
  info "  config/ archived."
else
  warn "  Could not archive the Nextcloud config directory."
  FAILED=$((FAILED + 1))
fi

if [[ "$BACKUP_INCLUDE_NEXTCLOUD_DATA" == "true" ]]; then
  warn "  Archiving every user file (BACKUP_INCLUDE_NEXTCLOUD_DATA=true)."
  warn "  The drive stays OFFLINE until this finishes."
  if docker exec "$NC_APP" tar -cf - -C /var/www/html data \
       > "$WORK_DIR/nextcloud/data.tar" 2>/dev/null; then
    info "  User files archived: $(du -h "$WORK_DIR/nextcloud/data.tar" | cut -f1)"
  else
    warn "  Could not archive the Nextcloud data directory."
    FAILED=$((FAILED + 1))
  fi
else
  info "  Skipping user files (BACKUP_INCLUDE_NEXTCLOUD_DATA=false); use rclone/rsync instead."
fi

if [[ "$NC_MAINTENANCE_ON" == "true" ]]; then
  if nc_occ maintenance:mode --off >/dev/null 2>&1; then
    NC_MAINTENANCE_ON=false
    info "  Nextcloud is back online."
  else
    warn "  Could not leave maintenance mode, the EXIT trap will retry."
  fi
fi

# ── 3. Backup config files ────────────────────────────────────────────────────
info "Backing up config files…"
cp -r "$PROJECT_DIR/config" "$WORK_DIR/config"
# Deliberately NOT copying .env: it holds the admin, database and Redis
# passwords, and this archive may be pushed to third-party storage via rclone.
# README.md explains how to reconstruct it.

# ── 4. Create the compressed archive ──────────────────────────────────────────
info "Creating archive ${BACKUP_DEST}/${ARCHIVE_NAME}…"
tar -czf "${BACKUP_DEST}/${ARCHIVE_NAME}" -C "$WORK_DIR" .
# The archive contains database and config secrets, owner-only.
chmod 600 "${BACKUP_DEST}/${ARCHIVE_NAME}"
info "Archive size: $(du -sh "${BACKUP_DEST}/${ARCHIVE_NAME}" | cut -f1)"

# ── 5. Rotate old backups ─────────────────────────────────────────────────────
info "Rotating backups (keeping the last ${BACKUP_KEEP})…"
# `|| true` on the pipeline: with `set -o pipefail`, a glob that matches nothing
# makes ls exit non-zero and would abort the whole script at the very last step.
ls -1t "${BACKUP_DEST}"/homedrive_*.tar.gz 2>/dev/null \
  | tail -n +"$((BACKUP_KEEP + 1))" \
  | xargs -r rm -f -- || true
info "Rotation complete. $(ls -1 "${BACKUP_DEST}"/homedrive_*.tar.gz 2>/dev/null | wc -l) archive(s) retained."

# ── 6. Optional: push to an rclone remote ────────────────────────────────────
if [[ -n "${RCLONE_REMOTE:-}" ]]; then
  info "Pushing to rclone remote '${RCLONE_REMOTE}'…"
  if command -v rclone &>/dev/null; then
    rclone copy "${BACKUP_DEST}/${ARCHIVE_NAME}" "${RCLONE_REMOTE}:homedrive-backups/" \
      --log-level INFO \
      || { warn "rclone push failed, the archive is still saved locally."; FAILED=$((FAILED + 1)); }
  else
    warn "RCLONE_REMOTE is set but rclone is not installed, skipping the off-Pi copy."
    FAILED=$((FAILED + 1))
  fi
fi

# ── 7. Result ─────────────────────────────────────────────────────────────────
if [[ "$FAILED" -gt 0 ]]; then
  warn "======== Backup finished with ${FAILED} problem(s): ${BACKUP_DEST}/${ARCHIVE_NAME} ========"
  exit 1
fi

info "======== Backup complete: ${BACKUP_DEST}/${ARCHIVE_NAME} ========"
