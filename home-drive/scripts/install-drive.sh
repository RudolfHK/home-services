#!/usr/bin/env bash
# install-drive.sh — bring up the Nextcloud drive and configure it for this Pi.
#
#   bash scripts/install-drive.sh              # interactive
#   bash scripts/install-drive.sh --yes        # never prompt
#   bash scripts/install-drive.sh --skip-pull  # use images already on disk
#
# Safe to re-run: every step is idempotent. Re-run it after editing
# config/nextcloud/zz-homedrive.config.php to apply the change.
#
# Run scripts/install.sh first — this assumes the stack (and Tailscale) is up.
# See docs/DRIVE.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE" --profile drive)

NC_SERVICES=(nextcloud-db nextcloud-redis nextcloud-app nextcloud-web nextcloud-cron)
NC_APP="homedrive-nextcloud-app"

ASSUME_YES="${HOMEDRIVE_ASSUME_YES:-false}"
SKIP_PULL="${HOMEDRIVE_SKIP_PULL:-false}"
for arg in "$@"; do
  case "$arg" in
    -y|--yes)    ASSUME_YES=true ;;
    --skip-pull) SKIP_PULL=true ;;
    -h|--help)   sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

confirm() {
  local prompt="$1"
  [[ "$ASSUME_YES" == "true" ]] && { info "$prompt → assuming yes (--yes)"; return 0; }
  [[ -t 0 ]] || error "$prompt — no TTY to ask on. Re-run with --yes."
  local reply
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

echo "========================================================"
echo "  Home Drive — install-drive.sh (Nextcloud)"
echo "========================================================"

# ── 1. Preflight ─────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] || error "Do not run this as root."
[[ -f "$ENV_FILE" ]] || error ".env not found. Run scripts/install.sh first."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for v in TS_HOSTNAME TS_TAILNET DATA_PATH TZ \
         NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD \
         NEXTCLOUD_DB_PASSWORD NEXTCLOUD_REDIS_PASSWORD; do
  [[ -n "${!v:-}" ]] || error "$v is not set in .env. Copy the Nextcloud block from .env.example."
done

for v in NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD NEXTCLOUD_REDIS_PASSWORD; do
  [[ "${!v}" != "change_me_strong_password" ]] \
    || error "Change $v in .env — it is still the example placeholder. Try: openssl rand -base64 32"
done

docker info >/dev/null 2>&1 || error "Cannot talk to the Docker daemon."
[[ -d "$DATA_PATH" ]] || error "$DATA_PATH does not exist. Run scripts/mount-drive.sh."

if ! mountpoint -q "$DATA_PATH"; then
  warn "$DATA_PATH is not a separate mount point — the drive's files would live on the OS disk."
  confirm "Continue anyway?" || exit 1
fi

NEXTCLOUD_PORT="${NEXTCLOUD_PORT:-9443}"
BASE_URL="https://${TS_HOSTNAME}.${TS_TAILNET}:${NEXTCLOUD_PORT}"

# The port has to be open in serve.json as well; that file is static JSON and
# cannot read .env, so a mismatch here produces a drive that is up but
# unreachable — with no error anywhere to explain why.
if ! grep -q "\"${NEXTCLOUD_PORT}\"" "$PROJECT_DIR/config/tailscale/serve.json"; then
  error "NEXTCLOUD_PORT=${NEXTCLOUD_PORT} is not present in config/tailscale/serve.json.
       Add a TCP listener and a Web handler for it, or set NEXTCLOUD_PORT=9443."
fi

info "Preflight OK — the drive will be served at ${BASE_URL}/"

# ── 2. Work out the uids the images actually use ─────────────────────────────
# Hardcoding these is the classic way to end up with a container that cannot
# write its own data directory: www-data is uid 33 on the Debian-based image but
# 82 on the Alpine one, and postgres is 999 on Debian and 70 on Alpine. Ask the
# image instead of guessing, and fall back only if that fails.
image_uid() {
  local image="$1" user="$2" fallback="$3" uid
  uid="$(docker run --rm --entrypoint id "$image" -u "$user" 2>/dev/null | tr -d '[:space:]')" || true
  if [[ "$uid" =~ ^[0-9]+$ ]]; then printf '%s' "$uid"; else printf '%s' "$fallback"; fi
}

if [[ "$SKIP_PULL" != "true" ]]; then
  info "Pulling images (first run downloads ~500 MB)…"
  "${COMPOSE[@]}" pull "${NC_SERVICES[@]}" || warn "Pull failed — falling back to whatever is on disk."
fi

info "Reading the uids the images run as…"
NC_UID="$(image_uid "nextcloud:${NEXTCLOUD_TAG:-stable-fpm}" www-data 33)"
PG_UID="$(image_uid "postgres:${POSTGRES_TAG:-16-alpine}" postgres 999)"
REDIS_UID="$(image_uid "redis:${REDIS_TAG:-7-alpine}" redis 999)"
info "  nextcloud=${NC_UID}  postgres=${PG_UID}  redis=${REDIS_UID}"

# ── 3. Data directories ──────────────────────────────────────────────────────
# All four are bind mounts with create_host_path: false — they must exist and be
# writable by the right uid before `up`, or the containers refuse to start.
info "Creating directories under ${DATA_PATH}/nextcloud…"
sudo mkdir -p \
  "${DATA_PATH}/nextcloud/data" \
  "${DATA_PATH}/nextcloud/config" \
  "${DATA_PATH}/nextcloud/db" \
  "${DATA_PATH}/nextcloud/redis"

sudo chown -R "${NC_UID}:${NC_UID}" "${DATA_PATH}/nextcloud/data" "${DATA_PATH}/nextcloud/config"
sudo chown -R "${PG_UID}:${PG_UID}" "${DATA_PATH}/nextcloud/db"
sudo chown -R "${REDIS_UID}:${REDIS_UID}" "${DATA_PATH}/nextcloud/redis"

# Everyone's files live in data/. Nothing outside the container has any business
# reading them, and Nextcloud's own setup check warns if this is world-readable.
sudo chmod 750 "${DATA_PATH}/nextcloud/data" "${DATA_PATH}/nextcloud/config"
sudo chmod 700 "${DATA_PATH}/nextcloud/db" "${DATA_PATH}/nextcloud/redis"

# ── 4. Stage the config overlay ──────────────────────────────────────────────
# Copied in already owned by the web user rather than bind-mounted from the repo:
# Nextcloud writes to its config directory (during upgrades and app installs),
# and a read-only mount owned by the wrong user turns those into hard failures.
info "Staging zz-homedrive.config.php…"
sudo cp "$PROJECT_DIR/config/nextcloud/zz-homedrive.config.php" \
        "${DATA_PATH}/nextcloud/config/zz-homedrive.config.php"
sudo chown "${NC_UID}:${NC_UID}" "${DATA_PATH}/nextcloud/config/zz-homedrive.config.php"
sudo chmod 640 "${DATA_PATH}/nextcloud/config/zz-homedrive.config.php"

# ── 5. Start ─────────────────────────────────────────────────────────────────
info "Validating docker-compose.yml…"
"${COMPOSE[@]}" config --quiet || error "docker-compose.yml did not validate against .env."

info "Starting the drive services…"
"${COMPOSE[@]}" up -d "${NC_SERVICES[@]}"

# Tailscale only reads serve.json at startup, so a freshly added port stays shut
# until it is restarted. Skipped when the port is already being served.
if ! docker exec homedrive-tailscale tailscale serve status 2>/dev/null | grep -q ":${NEXTCLOUD_PORT}"; then
  info "Restarting Tailscale so it picks up port ${NEXTCLOUD_PORT} from serve.json…"
  "${COMPOSE[@]}" restart tailscale >/dev/null
fi

# ── 6. Wait for the first-run install ────────────────────────────────────────
# On a Pi the first start unpacks the whole application into a fresh volume and
# then runs the installer. Several minutes is normal; failing fast here would be
# wrong.
occ() { docker exec -u www-data "$NC_APP" php /var/www/html/occ "$@"; }

info "Waiting for Nextcloud to finish installing (this can take several minutes)…"
INSTALLED=false
for _ in $(seq 1 120); do
  if occ status 2>/dev/null | grep -q 'installed: true'; then
    INSTALLED=true
    break
  fi
  sleep 5
done

if [[ "$INSTALLED" != "true" ]]; then
  warn "Nextcloud did not report 'installed: true' within 10 minutes."
  warn "Check the logs:  docker compose logs --tail 100 nextcloud-app"
  warn "Then re-run this script — it will pick up where it left off."
  exit 1
fi
info "Nextcloud is installed."

# ── 7. Configure ─────────────────────────────────────────────────────────────
# Tell Nextcloud that cron is driven externally (by nextcloud-cron). Left on
# "AJAX" the background jobs only run when somebody has a browser tab open, and
# expired file locks are one of the things those jobs release.
info "Setting the background job mode to cron…"
occ background:cron >/dev/null || warn "Could not set the background job mode."

# The file locking that the whole design rests on. `files_lock` is a first-party
# app but it ships from the app store, so this step needs internet access.
if occ app:list 2>/dev/null | grep -q 'files_lock'; then
  info "files_lock is already installed."
else
  info "Installing the files_lock app (exclusive file locking)…"
  if occ app:install files_lock >/dev/null 2>&1; then
    info "files_lock installed."
  else
    warn "Could not install files_lock automatically (no app store access?)."
    warn "Install it from the web UI: Apps → search 'Temporary files lock' → Download and enable."
    warn "Transactional locking via Redis is already active either way — see docs/DRIVE.md."
  fi
fi
occ app:enable files_lock >/dev/null 2>&1 || true

# Nextcloud ships schema improvements that are applied on demand rather than
# automatically. Skipping them leaves permanent warnings in the admin overview
# and, on a Pi, noticeably slower file listings.
info "Applying database indices and columns…"
occ db:add-missing-indices     >/dev/null 2>&1 || warn "db:add-missing-indices failed."
occ db:add-missing-columns     >/dev/null 2>&1 || true
occ db:add-missing-primary-keys >/dev/null 2>&1 || true

# One less click for every new user.
occ app:disable firstrunwizard >/dev/null 2>&1 || true

info "Current configuration:"
occ config:system:get overwrite.cli.url 2>/dev/null | sed 's/^/    overwrite.cli.url = /' || true
occ config:system:get trusted_domains  2>/dev/null | sed 's/^/    trusted_domain    = /' || true

# ── 8. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo -e "${GREEN}  The drive is up${NC}"
echo "========================================================"
echo ""
echo "  Web           : ${BASE_URL}/"
echo "  WebDAV        : ${BASE_URL}/remote.php/dav/files/${NEXTCLOUD_ADMIN_USER}/"
echo "  Sign in as    : ${NEXTCLOUD_ADMIN_USER}"
echo ""
echo "  Desktop and mobile clients: https://nextcloud.com/install/#install-clients"
echo "  Point them at ${BASE_URL} — the device must be on your tailnet."
echo ""
echo "  Next:"
echo "  1. Add accounts:  ${BASE_URL}/settings/users"
echo "  2. Create an app password per device rather than reusing your login:"
echo "     Personal settings → Security → Devices & sessions"
echo "  3. Read docs/DRIVE.md for how the locking works and what it does not cover."
echo ""
echo "  Check it:  bash scripts/health-dashboard.sh"
echo ""
