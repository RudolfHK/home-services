#!/usr/bin/env bash
# First-time setup wizard: checks the basics, asks for your media path,
# creates the folder layout, writes .env, pulls images, and brings the
# whole stack (core + pitune + jellyfin) up.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== PiHub setup =="
echo

# ── 1. Sanity checks (warn, don't block — useful when testing off-Pi) ──
if ! grep -qi "raspberry pi 5" /proc/device-tree/model 2>/dev/null; then
  echo "WARNING: this doesn't look like a Raspberry Pi 5 (checked /proc/device-tree/model)."
  echo "         Jellyfin's V4L2 hardware acceleration in docker-compose.yml assumes Pi 5"
  echo "         device paths and may need adjusting. Continuing anyway."
  echo
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed. Install it first:" >&2
  echo "  curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker \"\$USER\"" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: the Docker Compose v2 plugin is missing." >&2
  echo "  sudo apt-get install -y docker-compose-plugin" >&2
  exit 1
fi

# ── 2. Ask for the media storage path ───────────────────────────────────
default_media_root="/media/storage"
read -rp "Media storage path [$default_media_root]: " media_root
media_root="${media_root:-$default_media_root}"

if [ ! -d "$media_root" ]; then
  echo "ERROR: $media_root does not exist. Mount your media drive there first" >&2
  echo "       (and add it to /etc/fstab with the 'nofail' option, so the Pi" >&2
  echo "       still boots if the drive is ever disconnected)." >&2
  exit 1
fi

# ── 3. Create the folder structure ──────────────────────────────────────
echo "Creating folder structure under $media_root ..."
mkdir -p \
  "$media_root"/music \
  "$media_root"/videos \
  "$media_root"/movies \
  "$media_root"/shows \
  "$media_root"/photos \
  "$media_root"/downloads \
  "$media_root"/backups
mkdir -p ./navidrome/data ./jellyfin/config

# ── 4. Write .env ────────────────────────────────────────────────────────
if [ -f .env ]; then
  echo ".env already exists — leaving it alone. Delete it first to regenerate."
else
  cp .env.example .env
  # Portable in-place sed (GNU and BSD both accept this two-arg -i form).
  sed -i.bak "s|^MEDIA_ROOT=.*|MEDIA_ROOT=$media_root|" .env && rm -f .env.bak
  echo "Wrote .env (MEDIA_ROOT=$media_root). Review it — PUID/PGID default to 1000/1000,"
  echo "run 'id -u' / 'id -g' if that isn't you."
fi

# ── 5. Pull images ──────────────────────────────────────────────────────
echo
echo "Pulling images (this can take a while on a Pi's network/SD card)..."
docker compose pull

# ── 6. Start everything ─────────────────────────────────────────────────
echo "Starting core services + PiTune + Jellyfin..."
docker compose up -d

# ── 7. Print the URL ─────────────────────────────────────────────────────
port="$(grep -E '^PIHUB_PORT=' .env | cut -d= -f2 || true)"
port="${port:-80}"
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
ip="${ip:-<this-pi>}"

echo
echo "== Done =="
echo "Dashboard: http://$ip:$port/dashboard/"
echo
echo "One-time manual steps still needed:"
echo "  1. Open http://$ip:\${NAVIDROME_PORT:-4533}/ and create your first Navidrome user."
echo "  2. Open http://$ip:\${JELLYFIN_PORT:-8096}/ and run Jellyfin's setup wizard, then set"
echo "     Dashboard → Networking → Base URL to '/jellyfin' and restart the jellyfin service."
echo "  See README.md for details."
