#!/usr/bin/env bash
# install.sh — Bootstrap the Home Drive stack on a Raspberry Pi 5
#
# Usage:
#   bash scripts/install.sh          # interactive
#   bash scripts/install.sh --yes    # never prompt (for unattended re-runs)
#
# Safe to re-run: every step is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE")

ASSUME_YES="${HOMEDRIVE_ASSUME_YES:-false}"
SKIP_PULL="${HOMEDRIVE_SKIP_PULL:-false}"
for arg in "$@"; do
  case "$arg" in
    -y|--yes)    ASSUME_YES=true ;;
    --skip-pull) SKIP_PULL=true ;;
    *) echo "Unknown argument: $arg" >&2
       echo "Usage: $0 [--yes] [--skip-pull]" >&2
       exit 2 ;;
  esac
done

# ── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Prompt that respects --yes and non-interactive shells (cron, ssh -T).
confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" == "true" ]]; then
    info "$prompt → assuming yes (--yes)"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    error "$prompt — no TTY to ask on. Re-run with --yes if that is what you want."
  fi
  local reply
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

echo "========================================================"
echo "  Home Drive — install.sh"
echo "========================================================"

# ── 1. Sanity checks ─────────────────────────────────────────────────────────
info "Checking prerequisites…"

# Must not run as root — the containers are meant to run as PUID/PGID, and a
# root-run install would leave root-owned data directories behind.
[[ "$EUID" -ne 0 ]] || error "Do not run this script as root. Run as a normal user with sudo access."

command -v sudo &>/dev/null || error "sudo is required but not installed."

# Docker daemon
if ! command -v docker &>/dev/null; then
  warn "Docker not found. Installing via get.docker.com…"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  info "Docker installed. Log out and back in (or run 'newgrp docker') so the"
  info "docker group takes effect, then re-run this script."
  exit 0
fi

# Docker reachable without sudo (i.e. the group membership actually applied)
if ! docker info &>/dev/null; then
  error "Cannot talk to the Docker daemon as '$USER'. Is dockerd running, and are you in the 'docker' group? (newgrp docker)"
fi

# Docker Compose plugin (v2)
if ! docker compose version &>/dev/null; then
  error "Docker Compose plugin not found. Install it with: sudo apt-get install -y docker-compose-plugin"
fi

info "Docker $(docker --version) OK"
info "Docker Compose $(docker compose version --short) OK"

# ── 2. Environment file ──────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  warn ".env not found. Copying .env.example…"
  cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  error ".env created at $ENV_FILE — fill in TS_AUTHKEY and the passwords, then re-run."
fi

# .env holds a tailnet auth key and two admin passwords; keep it off other users.
if [[ "$(stat -c '%a' "$ENV_FILE")" != "600" ]]; then
  warn "Tightening permissions on .env to 0600 (it contains secrets)."
  chmod 600 "$ENV_FILE"
fi

# Source the env file to read variables for validation
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || error "$name is not set in .env"
}
reject_placeholder() {
  local name="$1"
  [[ "${!name}" != "change_me_strong_password" ]] \
    || error "Change $name in .env before continuing — it is still the example placeholder."
}

for v in TS_AUTHKEY TS_HOSTNAME TS_TAILNET COUCHDB_USER COUCHDB_PASSWORD \
         FILEBROWSER_ADMIN_USER FILEBROWSER_ADMIN_PASSWORD DATA_PATH PUID PGID TZ; do
  require_var "$v"
done
reject_placeholder COUCHDB_PASSWORD
reject_placeholder FILEBROWSER_ADMIN_PASSWORD

# TS_HOSTNAME becomes a DNS label; dots would silently produce a different
# MagicDNS name than the docs and .env assume.
[[ "$TS_HOSTNAME" != *.* ]] || error "TS_HOSTNAME must be a bare hostname with no dots (got '$TS_HOSTNAME')."
[[ "$DATA_PATH" = /* ]]     || error "DATA_PATH must be an absolute path (got '$DATA_PATH')."

info "Environment file OK"

# ── 3. Validate external drive mount ─────────────────────────────────────────
info "Checking external data drive at ${DATA_PATH}…"
[[ -d "$DATA_PATH" ]] || error "$DATA_PATH does not exist. Run: sudo bash scripts/mount-drive.sh"

# The compose file uses create_host_path: false, so a missing mount now fails
# the stack outright instead of silently filling the OS drive. Still warn early,
# because the failure message from Docker is much less obvious than this one.
if ! mountpoint -q "$DATA_PATH"; then
  warn "$DATA_PATH exists but is NOT a separate mount point."
  warn "If the external drive is simply unplugged, stop and fix that first —"
  warn "continuing will store all data on the OS drive."
  confirm "Continue anyway? (only if DATA_PATH is intentionally on the OS/NVMe drive)" \
    || exit 1
fi

# ── 4. Data directory layout and ownership ───────────────────────────────────
# All three paths are bind mounts with create_host_path: false — they must
# exist before `up`, or the stack will not start.
info "Creating data subdirectories under ${DATA_PATH}…"
sudo mkdir -p \
  "${DATA_PATH}/files" \
  "${DATA_PATH}/filebrowser" \
  "${DATA_PATH}/couchdb" \
  "${DATA_PATH}/backups" \
  "${DATA_PATH}/tmp"

# FileBrowser runs as PUID:PGID and needs to write into files/ and filebrowser/.
info "Setting ownership to ${PUID}:${PGID}…"
sudo chown "${PUID}:${PGID}" \
  "${DATA_PATH}" \
  "${DATA_PATH}/files" \
  "${DATA_PATH}/filebrowser" \
  "${DATA_PATH}/backups" \
  "${DATA_PATH}/tmp"
# Backups contain a full copy of your notes — keep them owner-only.
sudo chmod 700 "${DATA_PATH}/backups"

# The official couchdb image runs the database as uid/gid 5984, and its
# entrypoint is *supposed* to chown its own data directory on start. Doing it
# explicitly costs nothing and removes the most common cause of a CouchDB
# container that restarts forever: a bind-mounted data directory it cannot
# write to. Do NOT use PUID/PGID here — 5984 is baked into the image.
info "Setting CouchDB data ownership to 5984:5984…"
sudo chown -R 5984:5984 "${DATA_PATH}/couchdb"

# CouchDB reads every *.ini in /opt/couchdb/etc/local.d/, but our config cannot
# be mounted straight out of the git repo. The image entrypoint runs, under
# `set -e`:
#     find /opt/couchdb \! \( -user couchdb -group couchdb \) \
#          -exec chown -f couchdb:couchdb {} +
# A repo file is owned by you, not by uid 5984, so find matches it and tries to
# chown it — on a read-only bind mount that fails. `chown -f` suppresses the
# message but not the exit status, find propagates it, and the entrypoint aborts
# before CouchDB ever starts. The symptom is a container that exits instantly
# with completely empty logs.
#
# Staging a copy that is ALREADY owned by 5984:5984 means find never matches it,
# so there is nothing to chown and nothing to fail. The copy is refreshed on
# every run, so editing config/couchdb/zz-homedrive.ini still works normally.
info "Staging the CouchDB config for uid 5984…"
sudo mkdir -p "${DATA_PATH}/couchdb-etc"
sudo cp "$PROJECT_DIR/config/couchdb/zz-homedrive.ini" \
        "${DATA_PATH}/couchdb-etc/zz-homedrive.ini"
sudo chown -R 5984:5984 "${DATA_PATH}/couchdb-etc"
sudo chmod 644 "${DATA_PATH}/couchdb-etc/zz-homedrive.ini"

# A previous version of this stack bind-mounted filebrowser.db as a FILE. If the
# path does not exist, Docker creates a DIRECTORY there and FileBrowser cannot
# open its database. The mount is now the parent directory, but clean up the
# leftover so an upgraded install does not trip over it.
if [[ -d "${DATA_PATH}/filebrowser/filebrowser.db" ]]; then
  if [[ -z "$(ls -A "${DATA_PATH}/filebrowser/filebrowser.db")" ]]; then
    warn "Removing stray filebrowser.db DIRECTORY left by an older Docker file bind mount."
    sudo rmdir "${DATA_PATH}/filebrowser/filebrowser.db"
  else
    error "${DATA_PATH}/filebrowser/filebrowser.db is a non-empty directory. Inspect and remove it manually."
  fi
fi

info "Data directories ready"

# ── 5. TUN device check ───────────────────────────────────────────────────────
# TS_USERSPACE=false means tailscaled uses the kernel datapath, which requires
# /dev/net/tun. Without it the container starts and never authenticates.
info "Checking /dev/net/tun (required by Tailscale)…"
if [[ ! -e /dev/net/tun ]]; then
  warn "/dev/net/tun not found. Loading the tun kernel module…"
  sudo modprobe tun || error "Could not load the 'tun' module. Check your kernel."
  echo "tun" | sudo tee /etc/modules-load.d/tun.conf >/dev/null
  info "tun module loaded and persisted across reboots."
fi
ls -la /dev/net/tun

# ── 6. Validate the compose file against .env ────────────────────────────────
info "Validating docker-compose.yml…"
"${COMPOSE[@]}" config --quiet || error "docker-compose.yml did not validate against .env."

# ── 7. Pull images ────────────────────────────────────────────────────────────
# This is the one step that depends on the outside world. A flaky link must not
# block a deploy when the images are already sitting on disk, so: retry a few
# times, then fall back to whatever is local rather than aborting.
images_present() {
  local img
  for img in "tailscale/tailscale:${TAILSCALE_TAG:-latest}" \
             "filebrowser/filebrowser:${FILEBROWSER_TAG:-latest}" \
             "couchdb:${COUCHDB_TAG:-3}"; do
    docker image inspect "$img" >/dev/null 2>&1 || return 1
  done
  return 0
}

if [[ "$SKIP_PULL" == "true" ]]; then
  info "Skipping the image pull (--skip-pull)."
  images_present \
    || error "Not every image is present locally. Re-run without --skip-pull once the network is healthy."
else
  info "Pulling images (may take a few minutes on first run)…"
  PULL_OK=false
  for attempt in 1 2 3; do
    if "${COMPOSE[@]}" pull; then
      PULL_OK=true
      break
    fi
    warn "Pull attempt ${attempt}/3 failed."
    if [[ "$attempt" -lt 3 ]]; then
      sleep $(( attempt * 10 ))
    fi
  done

  if [[ "$PULL_OK" != "true" ]]; then
    if images_present; then
      warn "Could not reach the registry, but every image is already present locally."
      warn "Continuing with the images on disk. They will NOT be updated this run."
      warn "Re-run install.sh once the network is healthy to pick up new versions."
    else
      error "Image pull failed and not every image is available locally. Fix the network first."
    fi
  fi
fi

# ── 8. Bring up the stack ─────────────────────────────────────────────────────
info "Starting services…"
"${COMPOSE[@]}" up -d

# ── 9. Wait for Tailscale to authenticate ─────────────────────────────────────
# `tailscale status --json` is PRETTY-PRINTED (json.MarshalIndent), so the raw
# text reads `"BackendState": "Running",` WITH a space after the colon. Strip
# whitespace before matching, or this never fires.
info "Waiting for Tailscale to authenticate (up to 120 s)…"
TS_UP=false
for _ in $(seq 1 24); do
  if docker exec homedrive-tailscale tailscale status --json 2>/dev/null \
       | tr -d '[:space:]' | grep -q '"BackendState":"Running"'; then
    TS_UP=true
    break
  fi
  sleep 5
  echo -n "."
done
echo ""

if [[ "$TS_UP" == "true" ]]; then
  info "Tailscale is authenticated and running."
else
  warn "Tailscale did not reach BackendState=Running in time."
  warn "The other services depend on its healthcheck and may still be waiting."
  warn "Check: docker compose logs tailscale"
  warn "Common causes: expired/single-use TS_AUTHKEY, or device approval pending."
fi

# ── 10. Reset the FileBrowser admin account ──────────────────────────
# FileBrowser seeds its own admin user on first start with a default password.
# Leaving that in place on a file server reachable by everyone on the tailnet is
# not acceptable, so force the credentials from .env on every install run.
#
# This CANNOT be done with `docker exec` into the running container: FileBrowser
# holds an exclusive lock on its bbolt database for as long as it is running, and
# the CLI just reports "Error: timeout". The service has to be stopped, the CLI
# run from a throwaway container against the same volume, and the service
# started again.
if [[ "$TS_UP" == "true" ]]; then
  info "Applying FileBrowser admin credentials from .env…"

  # Give FileBrowser a moment to create its database on a first run.
  for _ in $(seq 1 12); do
    [[ -f "${DATA_PATH}/filebrowser/filebrowser.db" ]] && break
    sleep 5
  done

  if [[ -f "${DATA_PATH}/filebrowser/filebrowser.db" ]]; then
    info "Stopping filebrowser to release its database lock…"
    "${COMPOSE[@]}" stop filebrowser >/dev/null 2>&1 || true

    # The password is fed over stdin rather than passed as an argument so it
    # does not appear in the host's process list or shell history.
    #
    # The binary has moved between image generations: older tags ship it at
    # /filebrowser, current ones at /bin/filebrowser with `tini -- /init.sh` as
    # the entrypoint. Resolve it via PATH and fall back, rather than hardcoding
    # a path that breaks on the next image rebuild.
    #
    # Note the two CLI shapes: `users add` takes the password positionally,
    # `users update` takes it as a --password flag.
    fb_set_password() {
      local verb="$1" script
      local resolve='FB=$(command -v filebrowser || echo /filebrowser);'
      case "$verb" in
        update) script="read -r pw; $resolve"' exec "$FB" -d /database/filebrowser.db users update "$0" --password "$pw" --perm.admin' ;;
        add)    script="read -r pw; $resolve"' exec "$FB" -d /database/filebrowser.db users add "$0" "$pw" --perm.admin' ;;
      esac
      printf '%s\n' "$FILEBROWSER_ADMIN_PASSWORD" \
        | docker run --rm -i \
            --user "${PUID}:${PGID}" \
            -v "${DATA_PATH}/filebrowser:/database" \
            --entrypoint sh \
            "filebrowser/filebrowser:${FILEBROWSER_TAG:-latest}" \
            -c "$script" "$FILEBROWSER_ADMIN_USER"
    }

    # Capture output rather than discarding it: swallowing stderr here turns a
    # one-line CLI error ("unknown flag", "Error: timeout") into an unexplained
    # warning, and this step is the difference between a private file server and
    # one carrying a default password.
    FB_ERR_UPDATE=""; FB_ERR_ADD=""
    if FB_ERR_UPDATE="$(fb_set_password update 2>&1)"; then
      info "FileBrowser admin password updated for user '$FILEBROWSER_ADMIN_USER'."
    elif FB_ERR_ADD="$(fb_set_password add 2>&1)"; then
      info "FileBrowser admin user '$FILEBROWSER_ADMIN_USER' created."
    else
      warn "Could not set the FileBrowser admin password automatically."
      warn "  'users update' said: ${FB_ERR_UPDATE:-<no output>}"
      warn "  'users add' said:    ${FB_ERR_ADD:-<no output>}"
      warn "Do it manually. The service must be STOPPED for the CLI to open the database:"
      warn "  docker compose stop filebrowser"
      warn "  docker run --rm -it --user ${PUID}:${PGID} -v ${DATA_PATH}/filebrowser:/database --entrypoint filebrowser filebrowser/filebrowser -d /database/filebrowser.db users update $FILEBROWSER_ADMIN_USER --password '<password>'"
      warn "  docker compose start filebrowser"
    fi

    info "Restarting filebrowser…"
    "${COMPOSE[@]}" start filebrowser >/dev/null
  else
    warn "FileBrowser database was not created. Skipping the admin password reset."
    warn "Re-run this script once 'docker compose ps' shows filebrowser healthy."
  fi
fi

# ── 11. Print summary ─────────────────────────────────────────────────────────
BASE="https://${TS_HOSTNAME}.${TS_TAILNET}"
echo ""
echo "========================================================"
echo -e "${GREEN}  Stack is up!${NC}"
echo "========================================================"
echo ""
echo "  FileBrowser   : ${BASE}/"
echo "  CouchDB API   : ${BASE}/couchdb/          ← use this URI in Obsidian LiveSync"
echo "  CouchDB admin : ${BASE}:8443/_utils/      ← Fauxton needs the root path"
echo ""
echo "  Next steps:"
echo "  1. https://login.tailscale.com/admin/machines"
echo "     → find '${TS_HOSTNAME}' and approve it (if your tailnet requires approval)"
echo "  2. Admin console → DNS → enable MagicDNS"
echo "  3. Machines → '${TS_HOSTNAME}' → enable HTTPS"
echo "  4. Install the Tailscale app on your phone and sign in."
echo "  5. See docs/OBSIDIAN.md to configure Obsidian LiveSync."
echo "  6. bash scripts/install-monitoring.sh"
echo "     → health check every 15 min, alerts, and the 'homedrive-status' screen"
echo ""
echo "  Verify:  bash scripts/health-dashboard.sh"
echo ""
