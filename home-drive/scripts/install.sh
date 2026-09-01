#!/usr/bin/env bash
# install.sh — Bootstrap Home Drive (Nextcloud) on a Raspberry Pi 5
#
# Usage:
#   bash scripts/install.sh              # interactive
#   bash scripts/install.sh --yes        # never prompt (for unattended re-runs)
#   bash scripts/install.sh --skip-pull  # use images already on disk
#   bash scripts/install.sh --no-autostart   # do not enable the boot unit
#
# Safe to re-run: every step is idempotent. Re-run it after editing
# config/nextcloud/zz-homedrive.config.php to apply the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE")

# Everything except nextcloud-web, brought up first and separately — see
# step 7's comment for why.
NC_SERVICES_CORE=(nextcloud-db nextcloud-redis nextcloud-app nextcloud-cron)
NC_APP="homedrive-nextcloud-app"

ASSUME_YES="${HOMEDRIVE_ASSUME_YES:-false}"
SKIP_PULL="${HOMEDRIVE_SKIP_PULL:-false}"
AUTOSTART=true
for arg in "$@"; do
  case "$arg" in
    -y|--yes)       ASSUME_YES=true ;;
    --skip-pull)    SKIP_PULL=true ;;
    --no-autostart) AUTOSTART=false ;;
    -h|--help)      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; echo "Usage: $0 [--yes] [--skip-pull] [--no-autostart]" >&2; exit 2 ;;
  esac
done

# ── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

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

# Must not run as root — the containers run as their image defaults / fixed
# uids, and a root-run install would leave root-owned data directories behind.
[[ "$EUID" -ne 0 ]] || error "Do not run this script as root. Run as a normal user with sudo access."

command -v sudo &>/dev/null || error "sudo is required but not installed."

if ! command -v docker &>/dev/null; then
  warn "Docker not found. Installing via get.docker.com…"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  info "Docker installed. Log out and back in (or run 'newgrp docker') so the"
  info "docker group takes effect, then re-run this script."
  exit 0
fi

if ! docker info &>/dev/null; then
  error "Cannot talk to the Docker daemon as '$USER'. Is dockerd running, and are you in the 'docker' group? (newgrp docker)"
fi

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
  error ".env created at $ENV_FILE — fill in the values, then re-run."
fi

# .env holds admin passwords and, if you use it, a tailnet auth key; keep it
# off other users.
if [[ "$(stat -c '%a' "$ENV_FILE")" != "600" ]]; then
  warn "Tightening permissions on .env to 0600 (it contains secrets)."
  chmod 600 "$ENV_FILE"
fi

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

for v in DATA_PATH PUID PGID TZ NEXTCLOUD_LAN_HOSTNAME \
         NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD \
         NEXTCLOUD_DB_PASSWORD NEXTCLOUD_REDIS_PASSWORD; do
  require_var "$v"
done
reject_placeholder NEXTCLOUD_ADMIN_PASSWORD
reject_placeholder NEXTCLOUD_DB_PASSWORD
reject_placeholder NEXTCLOUD_REDIS_PASSWORD

[[ "$DATA_PATH" = /* ]] || error "DATA_PATH must be an absolute path (got '$DATA_PATH')."

info "Environment file OK"

# ── 3. Validate external drive mount ─────────────────────────────────────────
info "Checking external data drive at ${DATA_PATH}…"
[[ -d "$DATA_PATH" ]] || error "$DATA_PATH does not exist. Run: sudo bash scripts/mount-drive.sh"

if ! mountpoint -q "$DATA_PATH"; then
  warn "$DATA_PATH exists but is NOT a separate mount point."
  warn "If the external drive is simply unplugged, stop and fix that first —"
  warn "continuing will store all data on the OS drive."
  confirm "Continue anyway? (only if DATA_PATH is intentionally on the OS/NVMe drive)" \
    || exit 1
fi

# ── 4. Work out the uids the images actually use ─────────────────────────────
# Hardcoding these is the classic way to end up with a container that cannot
# write its own data directory: www-data is uid 33 on the Debian-based image
# but 82 on the Alpine one, and postgres is 999 on Debian and 70 on Alpine.
# Ask the image instead of guessing, and fall back only if that fails.
image_uid() {
  local image="$1" user="$2" fallback="$3" uid
  uid="$(docker run --rm --entrypoint id "$image" -u "$user" 2>/dev/null | tr -d '[:space:]')" || true
  if [[ "$uid" =~ ^[0-9]+$ ]]; then printf '%s' "$uid"; else printf '%s' "$fallback"; fi
}

if [[ "$SKIP_PULL" == "true" ]]; then
  info "Skipping the image pull (--skip-pull)."
else
  info "Pulling images (first run downloads several hundred MB)…"
  PULL_OK=false
  for attempt in 1 2 3; do
    if "${COMPOSE[@]}" pull; then
      PULL_OK=true
      break
    fi
    warn "Pull attempt ${attempt}/3 failed."
    [[ "$attempt" -lt 3 ]] && sleep $(( attempt * 10 ))
  done
  [[ "$PULL_OK" == "true" ]] || warn "Could not reach the registry. Continuing with whatever is on disk."
fi

info "Reading the uids the images run as…"
NC_UID="$(image_uid "nextcloud:${NEXTCLOUD_TAG:-stable-fpm}" www-data 33)"
PG_UID="$(image_uid "postgres:${POSTGRES_TAG:-16-alpine}" postgres 999)"
REDIS_UID="$(image_uid "redis:${REDIS_TAG:-7-alpine}" redis 999)"
info "  nextcloud=${NC_UID}  postgres=${PG_UID}  redis=${REDIS_UID}"

# ── 5. Data directories ──────────────────────────────────────────────────────
# All bind mounts use create_host_path: false — they must exist and be
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

# Everyone's files live in data/. Nothing outside the container has any
# business reading them by default (see README.md if you want PiHub's media
# streaming to read from inside here), and Nextcloud's own setup check warns
# if this is world-readable.
sudo chmod 750 "${DATA_PATH}/nextcloud/data" "${DATA_PATH}/nextcloud/config"
sudo chmod 700 "${DATA_PATH}/nextcloud/db" "${DATA_PATH}/nextcloud/redis"

# ── 6. The config overlay — staged later, in step 9 ──────────────────────────
# Copied in already owned by the web user rather than bind-mounted from the
# repo: Nextcloud writes to its own config directory (during upgrades and app
# installs), and a read-only mount owned by the wrong user turns those into
# hard failures.
#
# Deliberately NOT copied in before the first `up`. The image populates
# /var/www/html/config from itself only while that directory is still EMPTY:
#
#     for dir in config data custom_apps themes; do
#       if [ ! -d "/var/www/html/$dir" ] || directory_empty "/var/www/html/$dir"; then
#         rsync ... /usr/src/nextcloud/ /var/www/html/
#       fi
#     done                                — the image's docker-entrypoint.sh
#
# One pre-staged file is enough to make that test false, and then
# apps.config.php, redis.config.php, reverse-proxy.config.php and the rest
# never arrive. Nextcloud boots without them and answers HTTP 500 to every
# request, including the status.php that both the healthcheck and step 8 poll.
# Stage it once the installer has finished instead.
stage_overlay() {
  local src="$PROJECT_DIR/config/nextcloud/zz-homedrive.config.php"
  local dst="${DATA_PATH}/nextcloud/config/zz-homedrive.config.php"
  if sudo cmp -s "$src" "$dst"; then
    info "zz-homedrive.config.php is already up to date."
    return 1
  fi
  info "Staging zz-homedrive.config.php…"
  sudo cp "$src" "$dst"
  sudo chown "${NC_UID}:${NC_UID}" "$dst"
  sudo chmod 640 "$dst"
  return 0
}

# ── 7. Validate and start ────────────────────────────────────────────────────
info "Validating docker-compose.yml…"
"${COMPOSE[@]}" config --quiet || error "docker-compose.yml did not validate against .env."

# nextcloud-web is deliberately NOT started here. It depends_on nextcloud-app
# with condition: service_healthy, and `docker compose up` enforces that
# itself with its own timeout on the whole `up` command — a timeout that has
# nothing to do with, and is considerably less patient than, step 8's wait
# loop below. A first install slow enough to still be unpacking/installing
# when compose's own patience runs out fails the WHOLE `up -d` outright (and
# aborts this script, under set -e) before step 8's loop, which is the thing
# actually built to tolerate exactly that, ever gets to run. Starting
# everything nextcloud-app itself needs first, waiting for step 8 to confirm
# it the slow way, and only then starting nextcloud-web — which by that
# point finds nextcloud-app already healthy and returns immediately — avoids
# the false failure entirely.
info "Starting services…"
"${COMPOSE[@]}" up -d "${NC_SERVICES_CORE[@]}"

# ── 8. Wait for the first-run install ────────────────────────────────────────
# On a Pi the first start unpacks the whole application into a fresh volume and
# then runs the installer. Several minutes is normal; failing fast here would
# be wrong.
occ()    { docker exec -u www-data "$NC_APP" php /var/www/html/occ "$@"; }
in_app() { docker exec "$NC_APP" "$@" >/dev/null 2>&1; }

# Detect the one first-run failure the installer cannot recover from.
#
# The image runs its installer only while /var/www/html/version.php is absent,
# and it writes version.php in the same pass that populates the config
# directory — config first, then version.php. So version.php present WITHOUT
# the image's own apps.config.php means the config directory was already
# non-empty at first start: the populate step was skipped, and version.php now
# stops the entrypoint ever retrying. Nextcloud comes up uninstalled and 500s
# on every request, forever. Waiting the full ten minutes for that is pointless
# — nothing is coming.
never_installs() {
  in_app test -f /var/www/html/version.php \
    && ! in_app test -f /var/www/html/config/apps.config.php
}

# The other first-run failure the installer cannot recover from on its own.
#
# Nextcloud's automatic install runs exactly once, at container start, and
# does not retry itself later — a container that has been up for a while
# with no config.php just means that one attempt already failed. The
# specific way this happens: nextcloud-db's healthcheck can report healthy
# a moment before the real server is actually listening on TCP (see its own
# healthcheck comment in docker-compose.yml for the postgres-internal race
# behind that), nextcloud-app starts right then, its one-shot install hits
# "connection refused", and it gives up for good. occ then fails this exact
# way forever after, even once the database is completely fine, because
# nothing ever retries the install that would have written config.php.
db_connection_failed() {
  # Captured separately from the grep, not piped directly into it: occ
  # itself always exits non-zero here (it's throwing), and with pipefail
  # (already set at the top of this script) a direct `occ ... | grep -q`
  # would report THAT exit code rather than grep's, regardless of whether
  # grep actually matched — silently never firing this check at all.
  local out
  out="$(occ status 2>&1)" || true
  printf '%s' "$out" | grep -q 'Failed to connect to the database'
}

info "Waiting for Nextcloud to finish installing (this can take several minutes)…"
INSTALLED=false
RETRIED_DB_INSTALL=false
for _ in $(seq 1 120); do
  if occ status 2>/dev/null | grep -q 'installed: true'; then
    INSTALLED=true
    break
  fi
  if never_installs; then
    HTML_VOL="$(docker volume ls -q --filter name=nextcloud-html | head -1)"
    error "This Nextcloud can never finish installing.

  /var/www/html/version.php exists, but the image's own config files were never
  unpacked, so its entrypoint now skips both the setup and the installer on
  every start. It will keep answering HTTP 500.

  An earlier install.sh staged zz-homedrive.config.php into
  ${DATA_PATH}/nextcloud/config before the very first start, which is what
  caused this. This script no longer does that (see step 6), but the volume it
  left behind has to go before a clean install can happen. There is no user
  data at this point — Nextcloud never came up:

    cd $PROJECT_DIR
    docker compose down
    sudo find ${DATA_PATH}/nextcloud/config -maxdepth 1 -name '*.php' -delete
    sudo rm -rf ${DATA_PATH}/nextcloud/db/pgdata
    docker volume rm ${HTML_VOL:-<project>_nextcloud-html}
    bash scripts/install.sh

  Use 'find -delete', not 'rm -f .../*.php': that glob is expanded by YOUR
  shell before sudo ever runs, and this directory is mode 750 owned by the
  web user, so an ordinary user's shell can't even list it to match the
  glob — bash then passes the literal, unmatched string through, and rm -f
  silently deletes nothing at all while reporting no error whatsoever."
  fi
  if db_connection_failed; then
    # A config.php that already exists is a different, unfixable-by-retry
    # cause: it means SOME install already finished (possibly a different,
    # older one entirely — see below), so this container never attempts a
    # fresh one, and keeps using whatever is in that file, forever, no
    # matter how many times it restarts.
    if in_app test -f /var/www/html/config/config.php; then
      HTML_VOL="$(docker volume ls -q --filter name=nextcloud-html | head -1)"
      error "Nextcloud's automatic install can't reach the database, and
  /var/www/html/config/config.php already exists.

  That means this is not the startup race this script's automatic retry
  (below, for when config.php does NOT already exist) is meant for — a
  container that already has a config.php doesn't attempt a fresh install
  at all, so restarting it changes nothing. Check what's actually in it:

    sudo cat ${DATA_PATH}/nextcloud/config/config.php | grep -E 'dbhost|dbname|dbuser|installed'

  If dbhost is anything other than 'nextcloud-db' (127.0.0.1, localhost, a
  different container name…), this file is left over from a DIFFERENT
  Nextcloud install entirely — nothing this stack's own install.sh ever
  wrote. There is no user data at this point on THIS stack; that config.php
  already claiming 'installed' => true is exactly why Nextcloud never got
  the chance to create any:

    docker compose down
    sudo find ${DATA_PATH}/nextcloud/config -maxdepth 1 -name '*.php' -delete
    sudo rm -rf ${DATA_PATH}/nextcloud/db/pgdata
    docker volume rm ${HTML_VOL:-<project>_nextcloud-html}
    bash scripts/install.sh

  Use 'find -delete', not 'rm -f .../*.php': that glob is expanded by YOUR
  shell before sudo ever runs, and this directory is mode 750 owned by the
  web user, so an ordinary user's shell can't even list it to match the
  glob — bash then passes the literal, unmatched string through, and rm -f
  silently deletes nothing at all while reporting no error whatsoever."
    fi
    if [[ "$RETRIED_DB_INSTALL" == "true" ]]; then
      error "Nextcloud's automatic install still cannot reach the database after a retry.

  This isn't the startup race the retry above was for — that only ever needed
  one retry, since it means the database was briefly slow to come up, not
  actually broken. Something else is wrong. Check the database directly:

    docker compose logs --tail 50 nextcloud-db
    docker exec homedrive-nextcloud-app env | grep -i postgres
    docker exec homedrive-nextcloud-db psql -U ${NEXTCLOUD_DB_USER:-nextcloud} -d ${NEXTCLOUD_DB_NAME:-nextcloud} -c 'select 1;'

  and re-run this script once that last command actually succeeds."
    fi
    warn "Nextcloud's one-shot automatic install could not reach the database — a"
    warn "known startup race, not a real problem with the database itself (see"
    warn "docker-compose.yml's nextcloud-db healthcheck comment). Restarting"
    warn "nextcloud-app now that the database has had time to settle…"
    "${COMPOSE[@]}" restart nextcloud-app nextcloud-cron >/dev/null
    RETRIED_DB_INSTALL=true
    sleep 10
    continue
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

# Only now: nextcloud-app is already confirmed healthy, so nextcloud-web's
# own depends_on condition is satisfied immediately. See step 7's comment.
info "Starting nextcloud-web…"
"${COMPOSE[@]}" up -d nextcloud-web

# ── 9. Configure ─────────────────────────────────────────────────────────────
# Only now — with the image's own config files unpacked and config.php written
# by the installer — is it safe to drop the overlay on top. See step 6.
# php-fpm re-reads it per request, but opcache can serve the previous copy for
# up to a minute, so restart the two containers that execute Nextcloud code
# whenever the file actually changed.
if stage_overlay; then
  info "Restarting nextcloud-app and nextcloud-cron to pick it up…"
  "${COMPOSE[@]}" restart nextcloud-app nextcloud-cron >/dev/null \
    || warn "Could not restart the containers; the overlay applies within a minute anyway."
  for _ in $(seq 1 60); do
    if occ status 2>/dev/null | grep -q 'installed: true'; then break; fi
    sleep 5
  done
fi

# Tell Nextcloud that cron is driven externally (by nextcloud-cron). Left on
# "AJAX" the background jobs only run when somebody has a browser tab open,
# and expired file locks are one of the things those jobs release.
info "Setting the background job mode to cron…"
occ background:cron >/dev/null || warn "Could not set the background job mode."

# The file locking that the whole design rests on. `files_lock` is a
# first-party app but it ships from the app store, so this step needs
# internet access.
if occ app:list 2>/dev/null | grep -q 'files_lock'; then
  info "files_lock is already installed."
else
  info "Installing the files_lock app (exclusive file locking)…"
  if occ app:install files_lock >/dev/null 2>&1; then
    info "files_lock installed."
  else
    warn "Could not install files_lock automatically (no app store access?)."
    warn "Install it from the web UI: Apps → search 'Temporary files lock' → Download and enable."
    warn "Transactional locking via Redis is already active either way — see README.md."
  fi
fi
occ app:enable files_lock >/dev/null 2>&1 || true

# Nextcloud ships schema improvements that are applied on demand rather than
# automatically. Skipping them leaves permanent warnings in the admin
# overview and, on a Pi, noticeably slower file listings.
info "Applying database indices and columns…"
occ db:add-missing-indices      >/dev/null 2>&1 || warn "db:add-missing-indices failed."
occ db:add-missing-columns      >/dev/null 2>&1 || true
occ db:add-missing-primary-keys >/dev/null 2>&1 || true

# One less click for every new user.
occ app:disable firstrunwizard >/dev/null 2>&1 || true

info "Current configuration:"
occ config:system:get trusted_domains 2>/dev/null | sed 's/^/    trusted_domain = /' || true

# ── 10. Start at boot ─────────────────────────────────────────────────────────
# `restart: unless-stopped` alone is not enough: it cannot restore containers
# that no longer exist after a `docker compose down`, and it cannot wait for
# the external drive to mount before Docker tries to bind paths on it.
if [[ "$AUTOSTART" == "true" ]]; then
  info "Enabling autostart at boot…"
  bash "$SCRIPT_DIR/autostart.sh" install || warn "Could not install the boot unit. Run: bash scripts/autostart.sh on"
else
  warn "Skipping autostart (--no-autostart). Enable it later with:"
  warn "  bash scripts/autostart.sh on"
fi

# ── 11. Summary ───────────────────────────────────────────────────────────────
LAN_URL="http://${NEXTCLOUD_LAN_HOSTNAME}:${NEXTCLOUD_PORT:-80}"
echo ""
echo "========================================================"
echo -e "${GREEN}  Home Drive is up${NC}"
echo "========================================================"
echo ""
echo "  Web (LAN)     : ${LAN_URL}/"
echo "  WebDAV        : ${LAN_URL}/remote.php/dav/files/${NEXTCLOUD_ADMIN_USER}/"
echo "  Sign in as    : ${NEXTCLOUD_ADMIN_USER}"
echo ""
echo "  Desktop and mobile clients: https://nextcloud.com/install/#install-clients"
echo ""
echo "  Next:"
echo "  1. Add accounts:  ${LAN_URL}/settings/users"
echo "  2. Create an app password per device rather than reusing your login:"
echo "     Personal settings → Security → Devices & sessions"
echo "  3. Read README.md for how the locking works, what it doesn't cover, and"
echo "     how to enable remote access over Tailscale."
echo ""
echo "  Check it:  docker compose ps"
echo ""
if [[ "$AUTOSTART" == "true" ]]; then
  echo "  Autostart : ON — Home Drive comes up on every boot."
else
  echo "  Autostart : OFF (--no-autostart)."
fi
echo "              bash scripts/autostart.sh status | on | off"
echo ""
