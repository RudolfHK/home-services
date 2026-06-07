#!/usr/bin/env bash
# install.sh — Bootstrap the Home Drive stack on a Raspberry Pi 5
# Usage: bash scripts/install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# ── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

echo "========================================================"
echo "  Home Drive — install.sh"
echo "========================================================"

# ── 1. Sanity checks ─────────────────────────────────────────────────────────
info "Checking prerequisites…"

# Must not run as root (but needs sudo access for Docker group check)
[[ "$EUID" -ne 0 ]] || error "Do not run this script as root. Run as a normal user with sudo access."

# Docker daemon
if ! command -v docker &>/dev/null; then
  warn "Docker not found. Installing via get.docker.com…"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  info "Docker installed. You may need to log out and back in for the docker group to take effect."
  info "Re-run this script after re-logging in."
  exit 0
fi

# Docker Compose plugin (v2)
if ! docker compose version &>/dev/null; then
  error "Docker Compose plugin not found. Install it with: sudo apt-get install docker-compose-plugin"
fi

info "Docker $(docker --version) OK"
info "Docker Compose $(docker compose version --short) OK"

# ── 2. Environment file ──────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  warn ".env not found. Copying .env.example…"
  cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
  error ".env created at $ENV_FILE — fill in TS_AUTHKEY and passwords, then re-run."
fi

# Source the env file to read variables for validation
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Validate the most critical variables
[[ -n "${TS_AUTHKEY:-}" ]]       || error "TS_AUTHKEY is not set in .env"
[[ -n "${TS_HOSTNAME:-}" ]]      || error "TS_HOSTNAME is not set in .env"
[[ -n "${TS_TAILNET:-}" ]]       || error "TS_TAILNET is not set in .env"
[[ -n "${COUCHDB_PASSWORD:-}" ]] || error "COUCHDB_PASSWORD is not set in .env"
[[ "${COUCHDB_PASSWORD}" != "change_me_strong_password" ]] \
  || error "Change COUCHDB_PASSWORD in .env before continuing."
[[ -n "${DATA_PATH:-}" ]]        || error "DATA_PATH is not set in .env"

info "Environment file OK"

# ── 3. Validate external drive mount ─────────────────────────────────────────
info "Checking external data drive at ${DATA_PATH}…"
if [[ ! -d "$DATA_PATH" ]]; then
  error "$DATA_PATH does not exist. Run scripts/mount-drive.sh first."
fi

# Verify it is actually a separate mount (not just a directory on the root FS)
if ! mountpoint -q "$DATA_PATH"; then
  warn "$DATA_PATH exists but is not a mount point."
  warn "If this is intentional (e.g. NVMe OS drive), continue — but data will live on the root filesystem."
  read -rp "Continue anyway? [y/N] " cont
  [[ "$cont" =~ ^[Yy]$ ]] || exit 1
fi

# Create the data subdirectories if they don't already exist
info "Creating data subdirectories under ${DATA_PATH}…"
mkdir -p \
  "${DATA_PATH}/files" \
  "${DATA_PATH}/filebrowser" \
  "${DATA_PATH}/couchdb"

info "Data directories ready"

# ── 4. TUN device check ───────────────────────────────────────────────────────
info "Checking /dev/net/tun (required by Tailscale)…"
if [[ ! -e /dev/net/tun ]]; then
  warn "/dev/net/tun not found. Attempting to load the tun kernel module…"
  sudo modprobe tun
  echo "tun" | sudo tee /etc/modules-load.d/tun.conf >/dev/null
  info "tun module loaded and persisted."
fi
ls -la /dev/net/tun

# ── 5. Pull images ────────────────────────────────────────────────────────────
info "Pulling latest images (may take a few minutes on first run)…"
docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE" pull

# ── 6. Bring up the stack ─────────────────────────────────────────────────────
info "Starting services…"
docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d

# ── 7. Wait for Tailscale to authenticate ─────────────────────────────────────
info "Waiting for Tailscale to authenticate (up to 60 s)…"
for i in $(seq 1 12); do
  if docker exec homedrive-tailscale tailscale status --json 2>/dev/null \
       | grep -q '"BackendState":"Running"'; then
    info "Tailscale is authenticated and running."
    break
  fi
  sleep 5
  echo -n "."
done
echo ""

# ── 8. Print summary ──────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo -e "${GREEN}  Stack is up!${NC}"
echo "========================================================"
echo ""
echo "  FileBrowser : https://${TS_HOSTNAME}.${TS_TAILNET}/"
echo "  CouchDB     : https://${TS_HOSTNAME}.${TS_TAILNET}/couchdb/"
echo "  CouchDB UI  : https://${TS_HOSTNAME}.${TS_TAILNET}/couchdb/_utils/"
echo ""
echo "  Next steps:"
echo "  1. Open https://login.tailscale.com/admin/machines"
echo "     → find '${TS_HOSTNAME}' and approve it (if using pre-auth with approval)"
echo "  2. In the admin console → DNS → enable MagicDNS"
echo "  3. In Machines → click '${TS_HOSTNAME}' → enable HTTPS"
echo "  4. Install the Tailscale app on your phone and sign in."
echo "  5. See docs/OBSIDIAN.md to configure Obsidian LiveSync."
echo ""
