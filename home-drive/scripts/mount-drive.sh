#!/usr/bin/env bash
# mount-drive.sh — Identify, optionally format, and persistently mount
#                  the external data drive for the Home Drive stack.
#
# Run once during initial setup (before install.sh):
#   sudo bash scripts/mount-drive.sh
#
# The script will:
#   1. List available block devices so you can pick the right one.
#   2. Optionally format the chosen device as ext4.
#   3. Create the mount point.
#   4. Add an fstab entry (by UUID) so it remounts automatically on reboot.
set -euo pipefail

# ── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || error "Run this script as root: sudo bash $0"

echo "========================================================"
echo "  Home Drive — mount-drive.sh"
echo "========================================================"

# ── 1. Show available disks ───────────────────────────────────────────────────
echo ""
info "Available block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID
echo ""

# ── 2. Ask the user to choose a device ───────────────────────────────────────
read -rp "Enter the device to use as the data drive (e.g. /dev/sda or /dev/sda1): " DEVICE

[[ -b "$DEVICE" ]] || error "$DEVICE is not a block device."

# Guard against accidentally picking the OS drive
ROOTDEV=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
if [[ -n "$ROOTDEV" && "$DEVICE" == *"$ROOTDEV"* ]]; then
  warn "WARNING: $DEVICE looks like it might be the OS drive (root is on /dev/${ROOTDEV})."
  read -rp "Are you sure you want to use $DEVICE? This will ERASE all data on it. [yes/N] " confirm
  [[ "$confirm" == "yes" ]] || { info "Aborted."; exit 0; }
fi

# ── 3. Format (optional) ─────────────────────────────────────────────────────
echo ""
read -rp "Format $DEVICE as ext4? This will ERASE all existing data. [yes/N] " FORMAT

if [[ "$FORMAT" == "yes" ]]; then
  info "Formatting $DEVICE as ext4…"
  mkfs.ext4 -L homedrive "$DEVICE"
  info "Format complete."
else
  info "Skipping format — using existing filesystem."
fi

# ── 4. Create mount point ─────────────────────────────────────────────────────
MOUNT_POINT="/mnt/data"
info "Creating mount point at $MOUNT_POINT…"
mkdir -p "$MOUNT_POINT"

# ── 5. Get UUID of the chosen device ─────────────────────────────────────────
UUID=$(blkid -s UUID -o value "$DEVICE")
[[ -n "$UUID" ]] || error "Could not determine UUID for $DEVICE. Was the format successful?"
info "UUID: $UUID"

# ── 6. Add fstab entry ────────────────────────────────────────────────────────
FSTAB_LINE="UUID=$UUID  $MOUNT_POINT  ext4  defaults,noatime  0  2"

if grep -q "$UUID" /etc/fstab; then
  info "UUID $UUID already present in /etc/fstab — skipping."
else
  info "Adding entry to /etc/fstab…"
  # Backup fstab first
  cp /etc/fstab /etc/fstab.bak."$(date +%Y%m%d%H%M%S)"
  echo "$FSTAB_LINE" >> /etc/fstab
  info "Entry added: $FSTAB_LINE"
fi

# ── 7. Mount ──────────────────────────────────────────────────────────────────
info "Mounting $DEVICE at $MOUNT_POINT…"
mount "$MOUNT_POINT"

# ── 8. Create data subdirectories ────────────────────────────────────────────
info "Creating data subdirectories…"
mkdir -p \
  "$MOUNT_POINT/files" \
  "$MOUNT_POINT/filebrowser" \
  "$MOUNT_POINT/couchdb"

# Give ownership to the default pi user (UID/GID 1000)
chown -R 1000:1000 "$MOUNT_POINT"

echo ""
info "Done!  $DEVICE is mounted at $MOUNT_POINT"
echo ""
df -h "$MOUNT_POINT"
echo ""
info "Update DATA_PATH=$MOUNT_POINT in your .env file, then run scripts/install.sh"
