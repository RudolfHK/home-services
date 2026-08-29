#!/usr/bin/env bash
# install-monitoring.sh — make the health check run by itself, from anywhere.
#
#   bash scripts/install-monitoring.sh              # timer + system-wide commands
#   bash scripts/install-monitoring.sh --screen     # also: permanent display on tty1
#   bash scripts/install-monitoring.sh --cron       # cron instead of a systemd timer
#   bash scripts/install-monitoring.sh --uninstall  # remove everything it installed
#
# Safe to re-run: every step is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
UNIT_SRC="$PROJECT_DIR/config/systemd"
UNIT_DEST="/etc/systemd/system"
STATE_DIR="/var/lib/homedrive"
LOG_FILE="/var/log/homedrive-health.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

WITH_SCREEN=0
USE_CRON=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --screen)    WITH_SCREEN=1 ;;
    --cron)      USE_CRON=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) error "Unknown argument: $arg" ;;
  esac
done

[[ "$EUID" -ne 0 ]] || error "Do not run this as root — it installs units that run as YOUR user."
command -v sudo >/dev/null 2>&1 || error "sudo is required."

RUN_USER="$(id -un)"

# ── Uninstall ────────────────────────────────────────────────────────────────
if [[ "$UNINSTALL" == "1" ]]; then
  info "Removing timers, units and commands…"
  sudo systemctl disable --now homedrive-health.timer 2>/dev/null || true
  sudo systemctl disable --now homedrive-screen.service 2>/dev/null || true
  sudo rm -f "$UNIT_DEST/homedrive-health.service" \
             "$UNIT_DEST/homedrive-health.timer" \
             "$UNIT_DEST/homedrive-screen.service"
  sudo systemctl daemon-reload
  sudo rm -f /usr/local/bin/homedrive-health /usr/local/bin/homedrive-status
  sudo rm -f /etc/logrotate.d/homedrive
  crontab -l 2>/dev/null | grep -v 'health-monitor.sh' | crontab - 2>/dev/null || true
  info "Done. $STATE_DIR was left in place (it holds your history and file manifest)."
  exit 0
fi

# ── Prerequisites ────────────────────────────────────────────────────────────
[[ -f "$PROJECT_DIR/.env" ]] || error "$PROJECT_DIR/.env not found. Run scripts/install.sh first."
[[ -x "$SCRIPT_DIR/health-monitor.sh" ]] || chmod +x "$SCRIPT_DIR/health-monitor.sh"
[[ -x "$SCRIPT_DIR/health-dashboard.sh" ]] || chmod +x "$SCRIPT_DIR/health-dashboard.sh"

# ── State directory ──────────────────────────────────────────────────────────
# Under /var/lib, not the data drive: the monitor has to keep working — and keep
# its history — precisely when the external drive has gone missing.
info "Creating $STATE_DIR…"
sudo install -d -o "$RUN_USER" -g "$(id -gn)" -m 0755 "$STATE_DIR"

# ── System-wide commands ─────────────────────────────────────────────────────
# So the check "can always be done", from any directory, without remembering
# where the repo lives.
info "Installing homedrive-health and homedrive-status into /usr/local/bin…"
sudo ln -sf "$SCRIPT_DIR/health-monitor.sh"   /usr/local/bin/homedrive-health
sudo ln -sf "$SCRIPT_DIR/health-dashboard.sh" /usr/local/bin/homedrive-status

# ── Console access for the screen flash ──────────────────────────────────────
if ! id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx tty; then
  info "Adding $RUN_USER to the 'tty' group so the status can be drawn on /dev/tty1…"
  sudo usermod -aG tty "$RUN_USER"
  warn "Log out and back in for the tty group to take effect (the timer already has it)."
fi

# ── Scheduling ───────────────────────────────────────────────────────────────
if [[ "$USE_CRON" == "1" ]] || ! command -v systemctl >/dev/null 2>&1; then
  info "Installing an hourly cron entry…"
  sudo touch "$LOG_FILE"
  sudo chown "$RUN_USER" "$LOG_FILE"
  CRON_LINE="0 * * * * $SCRIPT_DIR/health-monitor.sh >> $LOG_FILE 2>&1"
  ( crontab -l 2>/dev/null | grep -v 'health-monitor.sh' || true; echo "$CRON_LINE" ) | crontab -
  info "cron entry installed: $CRON_LINE"
else
  info "Installing systemd units…"
  for unit in homedrive-health.service homedrive-health.timer; do
    sed -e "s|@PROJECT@|$PROJECT_DIR|g" -e "s|@USER@|$RUN_USER|g" "$UNIT_SRC/$unit" \
      | sudo tee "$UNIT_DEST/$unit" >/dev/null
  done

  if [[ "$WITH_SCREEN" == "1" ]]; then
    sed -e "s|@PROJECT@|$PROJECT_DIR|g" -e "s|@USER@|$RUN_USER|g" "$UNIT_SRC/homedrive-screen.service" \
      | sudo tee "$UNIT_DEST/homedrive-screen.service" >/dev/null
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable --now homedrive-health.timer
  info "Timer enabled — the check now runs every 15 minutes."

  if [[ "$WITH_SCREEN" == "1" ]]; then
    warn "The permanent display takes over tty1 and will fight the login prompt."
    warn "Disable that getty first, then start the display:"
    warn "  sudo systemctl disable --now getty@tty1"
    warn "  sudo systemctl enable --now homedrive-screen"
  fi
fi

# ── Log rotation ─────────────────────────────────────────────────────────────
# Only relevant for the cron path; journald handles the systemd one.
if [[ "$USE_CRON" == "1" ]] && [[ ! -f /etc/logrotate.d/homedrive ]]; then
  info "Installing /etc/logrotate.d/homedrive…"
  sudo tee /etc/logrotate.d/homedrive >/dev/null <<'ROTATE'
/var/log/homedrive-*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
ROTATE
fi

# ── First run ────────────────────────────────────────────────────────────────
echo ""
info "Running the first check now (it also seeds the file manifest)…"
echo ""
"$SCRIPT_DIR/health-monitor.sh" --verbose --no-screen || true

echo ""
echo "========================================================"
echo "  Monitoring installed"
echo "========================================================"
echo ""
echo "  homedrive-status            the dashboard, from anywhere"
echo "  homedrive-status --watch    live view"
echo "  homedrive-status --screen   draw it on the attached screen"
echo "  homedrive-health --verbose  run the unattended check by hand"
echo "  homedrive-health --status   what the last scheduled run found"
echo ""
if [[ "$USE_CRON" == "0" ]] && command -v systemctl >/dev/null 2>&1; then
  echo "  systemctl list-timers homedrive-health.timer"
  echo "  journalctl -u homedrive-health -n 50"
  echo ""
fi
echo "  Settings live in .env (HEALTH_*). See docs/MONITORING.md."
echo ""
