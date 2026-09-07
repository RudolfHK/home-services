#!/usr/bin/env bash
# mount-drive.sh — Identify, optionally format, and persistently mount
#                  the external data drive for the Home Drive stack.
#
# Run once during initial setup (before install.sh):
#   sudo bash scripts/mount-drive.sh
#
# The script will:
#   1. List available block devices so you can pick the right one.
#   2. Refuse anything that is part of the OS drive.
#   3. Optionally format the chosen device as ext4.
#   4. Create the mount point (DATA_PATH from .env, or /mnt/data).
#   5. Add an fstab entry by UUID, with the real filesystem type and `nofail`,
#      then verify it before rebooting is ever a risk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# ── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || error "Run this script as root: sudo bash $0"

for cmd in lsblk blkid findmnt mkfs.ext4; do
  command -v "$cmd" &>/dev/null || error "Required command not found: $cmd"
done

# Pick up DATA_PATH / PUID / PGID from .env if it already exists, so the mount
# point and ownership match what docker-compose.yml will actually use.
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
MOUNT_POINT="${DATA_PATH:-/mnt/data}"
OWNER_UID="${PUID:-1000}"
OWNER_GID="${PGID:-1000}"

echo "========================================================"
echo "  Home Drive — mount-drive.sh"
echo "  Mount point: $MOUNT_POINT  (owner ${OWNER_UID}:${OWNER_GID})"
echo "========================================================"

# ── 1. Show available disks ───────────────────────────────────────────────────
echo ""
info "Available block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID
echo ""

# ── 2. Ask the user to choose a device ───────────────────────────────────────
read -rp "Enter the device to use as the data drive (e.g. /dev/sda or /dev/sda1): " DEVICE

[[ -b "$DEVICE" ]] || error "$DEVICE is not a block device."

# Refuse anything that belongs to the OS drive. Check both the chosen device and
# its parent disk against every device currently backing a system mount — a
# `mkfs` on the wrong one destroys the Pi's boot media outright, so this is a
# hard refusal rather than a prompt.
DEVICE_BASE="$(basename "$(readlink -f "$DEVICE")")"
DEVICE_DISK="$(lsblk -no PKNAME "$DEVICE" 2>/dev/null || true)"
[[ -n "$DEVICE_DISK" ]] || DEVICE_DISK="$DEVICE_BASE"

for SYS_MNT in / /boot /boot/firmware; do
  SYS_SRC="$(findmnt -n -o SOURCE --target "$SYS_MNT" 2>/dev/null || true)"
  [[ -n "$SYS_SRC" ]] || continue
  SYS_SRC="${SYS_SRC%%\[*}"                        # strip btrfs [/subvol] suffix
  [[ -b "$SYS_SRC" ]] || continue
  SYS_BASE="$(basename "$(readlink -f "$SYS_SRC")")"
  SYS_DISK="$(lsblk -no PKNAME "$SYS_SRC" 2>/dev/null || true)"
  [[ -n "$SYS_DISK" ]] || SYS_DISK="$SYS_BASE"

  if [[ "$DEVICE_BASE" == "$SYS_BASE" || "$DEVICE_DISK" == "$SYS_DISK" ]]; then
    error "$DEVICE is part of the OS drive (/dev/$SYS_DISK backs $SYS_MNT). Refusing. Pick the external drive."
  fi
done

# Refuse a device that is currently mounted somewhere else.
CURRENT_MNT="$(lsblk -no MOUNTPOINT "$DEVICE" | grep -v '^$' | head -n1 || true)"
if [[ -n "$CURRENT_MNT" && "$CURRENT_MNT" != "$MOUNT_POINT" ]]; then
  error "$DEVICE is already mounted at $CURRENT_MNT. Unmount it first: umount $CURRENT_MNT"
fi

# Warn if the user picked a whole disk that still has partitions on it —
# formatting it wipes the partition table.
if [[ "$(lsblk -no TYPE "$DEVICE" | head -n1)" == "disk" ]] \
   && [[ "$(lsblk -no NAME "$DEVICE" | wc -l)" -gt 1 ]]; then
  warn "$DEVICE is a whole disk that already contains partitions."
  warn "Formatting it will destroy the partition table and everything on it."
fi

# ── 3. Format (optional) ─────────────────────────────────────────────────────
echo ""
read -rp "Format $DEVICE as ext4? This will ERASE all existing data. [yes/N] " FORMAT

if [[ "$FORMAT" == "yes" ]]; then
  info "Formatting $DEVICE as ext4…"
  mkfs.ext4 -L homedrive "$DEVICE"
  info "Format complete."
else
  info "Skipping format — using the existing filesystem."
fi

# ── 4. Identify UUID and filesystem type ─────────────────────────────────────
# Read the type from the device rather than assuming ext4: writing `ext4` into
# fstab for an exfat/ntfs/btrfs drive makes the mount fail at boot.
UUID="$(blkid -s UUID -o value "$DEVICE" || true)"
FSTYPE="$(blkid -s TYPE -o value "$DEVICE" || true)"

[[ -n "$UUID" ]]   || error "Could not read a UUID from $DEVICE. Is there a filesystem on it? (re-run and choose to format)"
[[ -n "$FSTYPE" ]] || error "Could not determine the filesystem type of $DEVICE."

info "UUID:   $UUID"
info "FSTYPE: $FSTYPE"

case "$FSTYPE" in
  ext4|ext3|ext2|xfs|btrfs)
    MOUNT_OPTS="defaults,noatime,nofail,x-systemd.device-timeout=10"
    ;;
  exfat|vfat|ntfs|ntfs3)
    # These have no POSIX ownership, so uid/gid are set at mount time and the
    # later chown is a no-op. PostgreSQL in particular will not work reliably here.
    warn "$FSTYPE has no POSIX permissions. Nextcloud's database expects a Linux filesystem."
    warn "Strongly consider reformatting as ext4."
    MOUNT_OPTS="defaults,noatime,nofail,x-systemd.device-timeout=10,uid=${OWNER_UID},gid=${OWNER_GID}"
    ;;
  *)
    MOUNT_OPTS="defaults,noatime,nofail,x-systemd.device-timeout=10"
    ;;
esac

# ── 5. Create mount point ─────────────────────────────────────────────────────
info "Creating mount point at $MOUNT_POINT…"
mkdir -p "$MOUNT_POINT"

# ── 6. Add fstab entry ────────────────────────────────────────────────────────
# `nofail` + a short device timeout is the important part: without it, a Pi that
# boots with the USB drive unplugged (or slow to enumerate) drops into an
# emergency shell with no network and no SSH — i.e. a headless brick.
# fsck pass 0 for the same reason: a dirty external drive must not block boot.
FSTAB_LINE="UUID=$UUID  $MOUNT_POINT  $FSTYPE  $MOUNT_OPTS  0  0"

if grep -q "UUID=$UUID" /etc/fstab; then
  info "UUID $UUID already present in /etc/fstab — leaving it alone."
  info "Existing entry: $(grep "UUID=$UUID" /etc/fstab)"
else
  # A stale entry for this exact mountpoint, from a DIFFERENT UUID, is not
  # harmless leftovers — it is invalid the moment a second one exists, since
  # only one device can ever back one mountpoint. This is exactly what
  # reformatting the same drive a second time produces: mkfs assigns a fresh
  # UUID every run, so an entry from an earlier format of this very drive
  # becomes unreachable rather than simply redundant. Catch it now, rather
  # than adding a second line alongside it and finding out from `findmnt
  # --verify` a few lines down.
  STALE_LINE="$(awk -v mp="$MOUNT_POINT" '$2 == mp' /etc/fstab || true)"
  if [[ -n "$STALE_LINE" ]]; then
    warn "/etc/fstab already has an entry for $MOUNT_POINT, for a different device:"
    warn "  $STALE_LINE"
    warn "Only one device can back a given mountpoint. If this drive has been"
    warn "formatted before, that old UUID no longer exists — mkfs assigns a new"
    warn "one every time, even to the same disk — so the line above is stale,"
    warn "not a second valid drive."
    read -rp "Remove that entry before adding the new one? [y/N] " REMOVE_STALE
    if [[ "$REMOVE_STALE" =~ ^[Yy]$ ]]; then
      STALE_BAK="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
      cp /etc/fstab "$STALE_BAK"
      awk -v mp="$MOUNT_POINT" '$2 != mp' /etc/fstab > /etc/fstab.new
      mv /etc/fstab.new /etc/fstab
      info "Removed. Previous file backed up to $STALE_BAK."
    else
      error "Leaving it. Remove the stale $MOUNT_POINT entry from /etc/fstab yourself, then re-run."
    fi
  fi

  FSTAB_BAK="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  info "Backing up /etc/fstab to $FSTAB_BAK…"
  cp /etc/fstab "$FSTAB_BAK"

  info "Adding entry to /etc/fstab…"
  echo "$FSTAB_LINE" >> /etc/fstab
  info "Entry added: $FSTAB_LINE"

  # Verify before anything can reboot into a broken fstab.
  if ! findmnt --verify --verbose >/dev/null 2>&1; then
    warn "findmnt reported problems with the new /etc/fstab:"
    findmnt --verify --verbose || true
    warn "Rolling back to $FSTAB_BAK."
    cp "$FSTAB_BAK" /etc/fstab
    error "fstab entry rejected — nothing was changed. Check the device and filesystem type."
  fi
  info "fstab verified."
fi

# systemd generates .mount units from fstab at boot; reload so the new entry is
# picked up now instead of only after the next reboot.
if command -v systemctl &>/dev/null; then
  systemctl daemon-reload || warn "systemctl daemon-reload failed — the entry still applies on reboot."
fi

# ── 7. Mount ──────────────────────────────────────────────────────────────────
if mountpoint -q "$MOUNT_POINT"; then
  info "$MOUNT_POINT is already mounted."
else
  info "Mounting $DEVICE at $MOUNT_POINT…"
  mount "$MOUNT_POINT" || error "Mount failed. Check: journalctl -xe | grep -i mount"
fi
mountpoint -q "$MOUNT_POINT" || error "$MOUNT_POINT is still not a mount point."

# ── 8. Create data subdirectories ────────────────────────────────────────────
# The nextcloud/{data,config,db,redis} tree itself is created by install.sh,
# which chowns each subdirectory to the actual uid the matching container
# image runs as (Nextcloud, PostgreSQL and Redis all differ). Only the
# directories install.sh does not own are created here.
info "Creating data subdirectories…"
mkdir -p \
  "$MOUNT_POINT/backups" \
  "$MOUNT_POINT/tmp"

# Scoped to the directories we created rather than -R over the whole drive:
# a recursive chown across a multi-terabyte drive is slow and pointlessly
# rewrites metadata for files that are already correct.
chown "${OWNER_UID}:${OWNER_GID}" \
  "$MOUNT_POINT" \
  "$MOUNT_POINT/backups" \
  "$MOUNT_POINT/tmp"
chmod 700 "$MOUNT_POINT/backups"   # backups contain database dumps and secrets

echo ""
info "Done!  $DEVICE is mounted at $MOUNT_POINT"
echo ""
df -h "$MOUNT_POINT"
echo ""
info "Set DATA_PATH=$MOUNT_POINT in your .env file, then run: bash scripts/install.sh"
