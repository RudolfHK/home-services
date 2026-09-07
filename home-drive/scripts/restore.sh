#!/usr/bin/env bash
# restore.sh — Restore a Home Drive backup archive.
#
# Usage:
#   bash scripts/restore.sh /mnt/data/backups/homedrive_20240101_023000.tar.gz
#
# What it does:
#   1. Extracts the archive to a staging directory on the data drive.
#   2. Restores the PostgreSQL database (with Nextcloud in maintenance mode).
#   3. Points you at the archived config/ directories for manual review.
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
NC_APP="homedrive-nextcloud-app"
NC_DB="homedrive-nextcloud-db"
FAILED=0

for cmd in docker tar; do
  command -v "$cmd" &>/dev/null || error "Required command not found on the host: $cmd"
done

info "======== Starting restore from $(basename "$ARCHIVE") ========"

warn "This will OVERWRITE the Nextcloud database with the contents of the archive."
if [[ -t 0 ]]; then
  read -rp "Continue? [yes/N] " confirm
  [[ "$confirm" == "yes" ]] || { info "Aborted."; exit 0; }
else
  [[ "${HOMEDRIVE_ASSUME_YES:-false}" == "true" ]] \
    || error "No TTY to confirm on. Set HOMEDRIVE_ASSUME_YES=true to run unattended."
fi

nc_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}
nc_occ() {
  docker exec -u www-data "$NC_APP" php /var/www/html/occ "$@"
}

# ── 1. Check the stack is running ─────────────────────────────────────────────
# Done before extracting, so a stopped stack fails in a second rather than after
# unpacking gigabytes.
nc_running "$NC_APP" && nc_running "$NC_DB" \
  || error "Nextcloud is not running. Start the stack first: docker compose up -d"

# ── 2. Extract the archive ────────────────────────────────────────────────────
# Staged on the data drive, not /tmp: /tmp is commonly a RAM-backed tmpfs on
# Raspberry Pi OS and a database dump with the data files included will not
# fit in it.
STAGING_ROOT="${DATA_PATH}/tmp"
mkdir -p "$STAGING_ROOT"
WORK_DIR="$(mktemp -d "${STAGING_ROOT}/homedrive-restore.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

info "Extracting archive…"
tar -xzf "$ARCHIVE" -C "$WORK_DIR"

if [[ ! -d "$WORK_DIR/nextcloud" ]]; then
  error "Archive does not contain a nextcloud/ directory: is this a Home Drive backup?"
fi
info "Extracted to $WORK_DIR"

# ── 3. Restore the PostgreSQL database ────────────────────────────────────────
NC_DUMP="$WORK_DIR/nextcloud/nextcloud-db.sql"
NC_MAINTENANCE_ON=false

if [[ -f "$NC_DUMP" ]]; then
  info "Restoring the PostgreSQL database…"

  if nc_occ maintenance:mode --on >/dev/null 2>&1; then
    NC_MAINTENANCE_ON=true
    info "  Nextcloud is in maintenance mode."
  else
    warn "  Could not enable maintenance mode, restoring onto a live database."
  fi

  # The password is written to the container's stdin rather than passed as
  # `-e PGPASSWORD=…`: every argument of a docker exec is visible in the host's
  # process list.
  if printf '%s' "${NEXTCLOUD_DB_PASSWORD:-}" \
       | docker exec -i "$NC_DB" sh -c \
           'PGPASSWORD="$(cat)" exec psql -h 127.0.0.1 -U "$1" -d "$2" -v ON_ERROR_STOP=1' \
           _ "${NEXTCLOUD_DB_USER:-nextcloud}" "${NEXTCLOUD_DB_NAME:-nextcloud}" \
       < "$NC_DUMP" >/dev/null
  then
    info "  Database restored."
  else
    warn "  psql restore failed."
    FAILED=$((FAILED + 1))
  fi

  if [[ "$NC_MAINTENANCE_ON" == "true" ]]; then
    if nc_occ maintenance:mode --off >/dev/null 2>&1; then
      info "  Nextcloud is back online."
    else
      warn "  Could not leave maintenance mode. Do it by hand:
    docker exec -u www-data $NC_APP php occ maintenance:mode --off"
    fi
  fi
else
  warn "No nextcloud-db.sql found in the archive, skipping the database restore."
fi

# ── 4. Config files ───────────────────────────────────────────────────────────
for dir in "$WORK_DIR/nextcloud" "$WORK_DIR/config"; do
  [[ -f "$dir/config.tar" ]] && info "Nextcloud config.php is archived at $dir/config.tar (extract and diff by hand; it is not applied automatically)."
done
if [[ -d "$WORK_DIR/config" ]]; then
  CONFIG_KEEP="${DATA_PATH}/restored-config-$(date +%Y%m%d%H%M%S)"
  cp -r "$WORK_DIR/config" "$CONFIG_KEEP"
  info "This project's config files from the archive are kept at $CONFIG_KEEP for review."
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
echo "    NEXTCLOUD_ADMIN_PASSWORD, NEXTCLOUD_DB_PASSWORD and NEXTCLOUD_REDIS_PASSWORD."
echo "  - Run scripts/install.sh to bring up the stack, then re-run this script."
echo ""
[[ "$FAILED" -eq 0 ]] || exit 1
