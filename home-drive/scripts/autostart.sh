#!/usr/bin/env bash
# autostart.sh — control whether the stack comes up at boot.
#
#   bash scripts/autostart.sh status      # is autostart on? is it running?
#   bash scripts/autostart.sh on          # enable and start it now
#   bash scripts/autostart.sh off         # disable and stop it now
#   bash scripts/autostart.sh install     # write + enable the systemd unit
#   bash scripts/autostart.sh uninstall   # remove the unit, leave it running
#
# `start` and `stop` are what the systemd unit calls. You do not normally run
# them by hand — use `on` / `off`, which also flip the boot setting.
#
# See README.md's "Enable or disable at boot" section.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
UNIT_NAME="homedrive.service"
UNIT_SRC="$PROJECT_DIR/config/systemd/$UNIT_NAME"
UNIT_DEST="/etc/systemd/system/$UNIT_NAME"

NC_SERVICES=(nextcloud-db nextcloud-redis nextcloud-app nextcloud-web nextcloud-cron)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Help before anything that can fail: someone reaching for --help is usually
# trying to work out why the rest of it did not run.
case "${1:-}" in
  -h|--help|help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

[[ -f "$ENV_FILE" ]] || error ".env not found. Run scripts/install.sh first."
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

DATA_PATH="${DATA_PATH:-/mnt/data}"
COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE")

# ── Helpers ──────────────────────────────────────────────────────────────────
have_systemd() { command -v systemctl >/dev/null 2>&1; }
unit_installed() { [[ -f "$UNIT_DEST" ]]; }

running_count() {
  local svc n=0 state
  for svc in "${NC_SERVICES[@]}"; do
    state="$(docker inspect -f '{{.State.Running}}' "homedrive-${svc}" 2>/dev/null)" || true
    # An `if`, not `[[ … ]] && …`: the AND-list form returns non-zero when the
    # test fails, and under `set -e` that aborts the script the moment one
    # container is down — exactly when this count matters most.
    if [[ "$state" == "true" ]]; then n=$(( n + 1 )); fi
  done
  printf '%s' "$n"
}

# The bind mounts use create_host_path:false, so these directories existing is
# the real precondition — and it is a better test than `mountpoint`, which would
# never succeed on a deployment that deliberately keeps DATA_PATH on the OS disk.
mounts_ready() {
  local d
  for d in data config db redis; do
    [[ -d "${DATA_PATH}/nextcloud/${d}" ]] || return 1
  done
  return 0
}

# ── Subcommands ──────────────────────────────────────────────────────────────
cmd_start() {
  local waited=0 max="${DRIVE_MOUNT_WAIT:-180}" step=5

  if ! mounts_ready; then
    info "Waiting for ${DATA_PATH}/nextcloud to appear (external drive still mounting?)…"
    while ! mounts_ready; do
      if [[ "$waited" -ge "$max" ]]; then
        error "${DATA_PATH}/nextcloud is still missing after ${max}s.
       Every container binds a path under it with create_host_path:false,
       so starting now would only produce five failed containers.
       Check the drive is mounted:  mount | grep ${DATA_PATH}"
      fi
      sleep "$step"
      waited=$(( waited + step ))
    done
    info "Directories appeared after ${waited}s."
  fi

  info "Starting the stack…"
  "${COMPOSE[@]}" up -d "${NC_SERVICES[@]}"
  info "Started ($(running_count)/${#NC_SERVICES[@]} containers running)."
}

cmd_stop() {
  info "Stopping the stack…"
  # `stop`, never `down`: down removes the containers, and a stop/start cycle
  # would then have to recreate them — losing the crash-recovery restart policy
  # in between and taking far longer.
  "${COMPOSE[@]}" stop "${NC_SERVICES[@]}" || true
  info "Stopped."
}

cmd_install() {
  have_systemd || error "systemd not found. Without it, Docker's 'unless-stopped' policy is the only autostart — see README.md."
  [[ "$EUID" -ne 0 ]] || error "Do not run this as root — the unit must run as the user in the docker group."
  [[ -f "$UNIT_SRC" ]] || error "$UNIT_SRC not found."

  # Belt and braces: the unit names this file in ExecStart. A checkout that lost
  # the exec bit — git with core.fileMode=false is the usual way — would fail
  # with systemd's bare 203/EXEC and nothing to explain it. (The unit also
  # invokes it through /bin/bash, so this is the second line of defence.)
  chmod +x "$SCRIPT_DIR/autostart.sh" 2>/dev/null || true

  info "Installing $UNIT_NAME…"
  sed -e "s|@PROJECT@|$PROJECT_DIR|g" \
      -e "s|@USER@|$(id -un)|g" \
      -e "s|@DATA_PATH@|$DATA_PATH|g" \
      "$UNIT_SRC" | sudo tee "$UNIT_DEST" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable "$UNIT_NAME" >/dev/null
  info "Autostart enabled — the stack will come up on every boot."
}

cmd_uninstall() {
  have_systemd || return 0
  info "Removing $UNIT_NAME…"
  # `disable` without --now: leave a running stack running. Removing the boot
  # setting should not take the service down under someone who is using it.
  sudo systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
  sudo rm -f "$UNIT_DEST"
  sudo systemctl daemon-reload
  info "Unit removed. The stack is untouched; Docker's restart policy still applies."
}

cmd_on() {
  unit_installed || cmd_install
  have_systemd || error "systemd not found."
  sudo systemctl enable --now "$UNIT_NAME"
  info "Autostart is ON."
}

cmd_off() {
  have_systemd || error "systemd not found."
  if unit_installed; then
    # --now runs ExecStop, which stops the containers. That second part is not
    # cosmetic: `restart: unless-stopped` restores any container that is still
    # in the running state when the daemon starts, so leaving them up would make
    # the stack come back at the next boot and the switch look broken.
    sudo systemctl disable --now "$UNIT_NAME"
  else
    warn "The unit is not installed; stopping the containers directly."
    cmd_stop
  fi
  info "Autostart is OFF — the stack will stay down until you start it again."
}

cmd_status() {
  local enabled="not installed" active="-" mounted="no"

  if unit_installed && have_systemd; then
    # Both of these print a status word AND exit non-zero for anything that is
    # not active/enabled, so `cmd || echo fallback` printed BOTH — which is why
    # a failed unit rendered as "failed" on one line and "inactive" on the next.
    # Take the output, and fall back only when there is none.
    enabled="$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null)" || true
    active="$(systemctl is-active "$UNIT_NAME" 2>/dev/null)" || true
    [[ -n "$enabled" ]] || enabled="unknown"
    [[ -n "$active" ]] || active="inactive"
  fi
  mountpoint -q "$DATA_PATH" 2>/dev/null && mounted="yes"

  local running total="${#NC_SERVICES[@]}"
  running="$(running_count)"

  echo "Autostart  : $enabled"
  echo "Unit       : $active   ($UNIT_NAME)"
  echo "Containers : ${running}/${total} running"
  echo "Data path  : $DATA_PATH (separate mount: $mounted)"
  echo "Bind dirs  : $(mounts_ready && echo present || echo MISSING)"
  echo ""

  if [[ "$enabled" == "enabled" ]]; then
    echo "The stack will start on boot."
  elif [[ "$enabled" == "not installed" ]]; then
    echo "No boot unit installed. The stack comes back after a reboot only if its"
    echo "containers still exist and were left running — and not at all if the"
    echo "external drive mounts after Docker starts."
    echo "Fix that with:  bash scripts/autostart.sh on"
  else
    echo "Autostart is off. Turn it on with:  bash scripts/autostart.sh on"
  fi

  [[ "$running" -ne "$total" && "$running" -ne 0 ]] && \
    warn "Only ${running} of ${total} containers are running — check: docker compose ps"
  return 0
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-status}" in
  start)            cmd_start ;;
  stop)             cmd_stop ;;
  on|enable)        cmd_on ;;
  off|disable)      cmd_off ;;
  install)          cmd_install ;;
  uninstall|remove) cmd_uninstall ;;
  status)           cmd_status ;;
  *) error "Unknown command: $1 (try: status | on | off | install | uninstall)" ;;
esac
