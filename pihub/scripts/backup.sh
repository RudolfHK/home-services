#!/usr/bin/env bash
# Backs up PER-SERVICE CONFIG ONLY — Navidrome's database and Jellyfin's
# config/metadata. Deliberately does NOT touch MEDIA_ROOT: your actual music
# and video files are assumed to already exist elsewhere (that's the whole
# point of pointing this stack at an existing library) and would turn a
# few-MB config backup into a multi-terabyte one.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
[ -f .env ] && set -a && source .env && set +a

MEDIA_ROOT="${MEDIA_ROOT:-/mnt/data/pihub}"
NAVIDROME_DATA_PATH="${NAVIDROME_DATA_PATH:-./navidrome/data}"
JELLYFIN_CONFIG_PATH="${JELLYFIN_CONFIG_PATH:-./jellyfin/config}"
BACKUP_DEST="${BACKUP_DEST:-$MEDIA_ROOT/backups}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"

mkdir -p "$BACKUP_DEST"

stamp="$(date +%Y%m%d-%H%M%S)"
archive="$BACKUP_DEST/pihub-config-$stamp.tar.gz"

echo "Backing up config to $archive"
tar -czf "$archive" \
  --exclude='*.log' \
  -C "$(dirname "$NAVIDROME_DATA_PATH")" "$(basename "$NAVIDROME_DATA_PATH")" \
  -C "$(dirname "$JELLYFIN_CONFIG_PATH")" "$(basename "$JELLYFIN_CONFIG_PATH")"

chmod 600 "$archive"

echo "Rotating: keeping the newest $BACKUP_KEEP archive(s)"
# shellcheck disable=SC2012
ls -1t "$BACKUP_DEST"/pihub-config-*.tar.gz 2>/dev/null | tail -n "+$((BACKUP_KEEP + 1))" | while read -r old; do
  echo "  removing $old"
  rm -f "$old"
done

echo "Done: $archive"
