#!/usr/bin/env bash
# First-time setup wizard: checks the basics, asks for your media path,
# creates the folder layout, writes .env, pulls images, and brings the
# whole stack (core + homepage + pitune + jellyfin) up.
set -euo pipefail
cd "$(dirname "$0")/.."

# Reads one KEY=value out of .env, tolerating both a missing file and a
# missing key. Without the `|| true`, `set -o pipefail` turns an ordinary
# grep miss into a fatal exit with no message at all — the script simply
# stops mid-run — which is a miserable thing to debug. Every read of .env in
# this script goes through here for that reason.
env_value() {
  [ -f .env ] || return 0
  grep -E "^$1=" .env | tail -n1 | cut -d= -f2- || true
}

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
default_media_root="/mnt/data/pihub"
read -rp "Media storage path [$default_media_root]: " media_root
media_root="${media_root:-$default_media_root}"

# .env is the single source of truth for what docker-compose.yml actually
# binds. If one already exists from an earlier run, the answer above is only
# a proposal — creating the folder tree at the new path while compose keeps
# binding the old one is exactly how you get "bind source path does not
# exist" at `up` time (the binds set create_host_path: false on purpose).
env_media_root="$(env_value MEDIA_ROOT)"

if [ -n "$env_media_root" ] && [ "$env_media_root" != "$media_root" ]; then
  echo
  echo "NOTE: the existing .env says MEDIA_ROOT=$env_media_root, not $media_root."
  echo "      docker-compose.yml binds whatever .env says, so the two must agree."
  read -rp "      Update .env to $media_root? [y/N]: " reply
  case "$reply" in
    [yY]*)
      sed -i.bak "s|^MEDIA_ROOT=.*|MEDIA_ROOT=$media_root|" .env && rm -f .env.bak
      echo "      Updated .env to MEDIA_ROOT=$media_root."
      env_media_root="$media_root"
      ;;
    *)
      media_root="$env_media_root"
      echo "      Keeping MEDIA_ROOT=$media_root — continuing with that path."
      ;;
  esac
  echo
fi

if [ ! -d "$media_root" ]; then
  echo "ERROR: $media_root does not exist. Mount your media drive there first" >&2
  echo "       (and add it to /etc/fstab with the 'nofail' option, so the Pi" >&2
  echo "       still boots if the drive is ever disconnected)." >&2
  exit 1
fi

# ── 3. Create the folder structure ──────────────────────────────────────
# This wizard only ever sets up the plain-MEDIA_ROOT layout. If you want
# music/videos/movies/shows to live inside home-drive's Nextcloud instead
# (so Nextcloud itself manages adding/moving/deleting them), let this run
# as-is first, then edit .env afterward and set MEDIA_LIBRARY_ROOT. See
# README.md's "Mounting a Nextcloud folder as your media library". Create
# those four subfolders through Nextcloud's own UI/sync client at that
# point, not by hand here, so Nextcloud's index knows about them from the
# start.
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

# If .env redirects the streamable library elsewhere, jellyfin's and
# navidrome's binds point there instead — and those four folders are
# Nextcloud's to create, not ours (creating them behind its back leaves them
# outside its index). Check and stop, rather than mkdir.
if [ -f .env ]; then
  media_library_root="$(env_value MEDIA_LIBRARY_ROOT)"
  if [ -n "${media_library_root:-}" ]; then
    missing=""
    for sub in music videos movies shows; do
      [ -d "$media_library_root/$sub" ] || missing="$missing $sub"
    done
    if [ -n "$missing" ]; then
      echo "ERROR: .env sets MEDIA_LIBRARY_ROOT=$media_library_root, but it is missing:$missing" >&2
      echo "       Create those through Nextcloud's own UI or sync client — not mkdir — so" >&2
      echo "       its index knows about them, then re-run. See README.md's \"Mounting a" >&2
      echo "       Nextcloud folder as your media library\"." >&2
      exit 1
    fi
  fi
fi

# ── 4. Write .env ────────────────────────────────────────────────────────
if [ -f .env ]; then
  echo ".env already exists — keeping it (MEDIA_ROOT reconciled above). Delete it"
  echo "first if you want every other value regenerated from .env.example too."
else
  cp .env.example .env
  # Portable in-place sed (GNU and BSD both accept this two-arg -i form).
  sed -i.bak "s|^MEDIA_ROOT=.*|MEDIA_ROOT=$media_root|" .env && rm -f .env.bak

  # Without this, the homepage dashboard's start/stop/restart/logs and
  # PiTune's /api/save (if DOWNLOAD_ENABLED) run with no auth at all — see
  # README.md's Security model. Generated fresh every install; if you ever
  # need to rotate it, edit .env and restart homepage + pitune-backend.
  api_token="$(openssl rand -hex 32)"
  sed -i.bak "s|^API_TOKEN=.*|API_TOKEN=$api_token|" .env && rm -f .env.bak

  echo "Wrote .env (MEDIA_ROOT=$media_root). Review it — PUID/PGID default to 1000/1000,"
  echo "run 'id -u' / 'id -g' if that isn't you."
fi

# ── 4b. Probe this board for Jellyfin's V4L2 decode devices ─────────────
# Docker treats a device listed in docker-compose.yml but missing on the
# host as a fatal error, aborting the whole `up` — so these are variables in
# the compose file, and we sync them to whatever this board actually has.
# Purely hardware-derived, so this just happens rather than asking.
echo
found=0
for n in 10 11 12; do
  key="JELLYFIN_V4L2_DEV$n"
  if [ -c "/dev/video$n" ]; then
    value="/dev/video$n:/dev/video$n"
    found=$((found + 1))
  else
    value="/dev/null:/dev/null"
  fi
  if grep -qE "^$key=" .env; then
    sed -i.bak "s|^$key=.*|$key=$value|" .env && rm -f .env.bak
  else
    printf '%s=%s
' "$key" "$value" >> .env
  fi
done

case "$found" in
  3) echo "Jellyfin hardware decode: /dev/video10-12 present — passing them through." ;;
  0) echo "Jellyfin hardware decode: /dev/video10-12 not present on this board — disabled."
     echo "  Jellyfin will use software decoding. Direct play is unaffected, and is what"
     echo "  you want on a Pi regardless — see README.md's Raspberry Pi considerations."
     echo "  If your board exposes the decoder under different numbers, check with"
     echo "  'ls -l /dev/video*' and set JELLYFIN_V4L2_DEV* in .env by hand." ;;
  *) echo "Jellyfin hardware decode: only $found of /dev/video10-12 present — passing"
     echo "  through the ones that exist. Check 'ls -l /dev/video*' if that's a surprise." ;;
esac

# ── 5. Pull images ──────────────────────────────────────────────────────
echo
echo "Pulling images (this can take a while on a Pi's network/SD card)..."
docker compose pull

# ── 6. Start everything ─────────────────────────────────────────────────
echo "Starting core services + homepage + PiTune + Jellyfin..."
docker compose up -d

# ── 7. Print the URL ─────────────────────────────────────────────────────
port="$(env_value PIHUB_PORT)"; port="${port:-80}"
navidrome_port="$(env_value NAVIDROME_PORT)"; navidrome_port="${navidrome_port:-4533}"
jellyfin_port="$(env_value JELLYFIN_PORT)"; jellyfin_port="${jellyfin_port:-8096}"
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
ip="${ip:-<this-pi>}"

echo
echo "== Done =="
echo "Dashboard: http://$ip:$port/"
echo
echo "One-time manual steps still needed:"
echo "  1. Open http://$ip:$navidrome_port/ and create your first Navidrome user."
echo "  2. Open http://$ip:$jellyfin_port/ and run Jellyfin's setup wizard, then set"
echo "     Dashboard → Networking → Base URL to '/jellyfin' and restart the jellyfin service."
echo "  See README.md for details."
