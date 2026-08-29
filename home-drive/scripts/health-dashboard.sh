#!/usr/bin/env bash
# health-dashboard.sh — the Home Drive status screen, for humans.
#
# Everything health-monitor.sh checks, plus the numbers you actually want when
# you are looking at the box on purpose: what the disk is filled with, which
# files moved, how fast data is flowing right now, and how hot the Pi is.
#
# Run it from the repo whenever you want to know how the drive is doing:
#   bash scripts/health-dashboard.sh              # one full screen
#   bash scripts/health-dashboard.sh --watch      # live, refreshes every 5s
#   bash scripts/health-dashboard.sh --screen     # draw it on the attached TV
#   bash scripts/health-dashboard.sh --json       # feed it to something else
#
# Its unattended sibling is health-monitor.sh, which runs from a systemd timer,
# stays quiet unless something is wrong, and alerts. This one never alerts and
# never exits non-zero for a warning — it is a display, not a gate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=./lib/stats.sh
source "$SCRIPT_DIR/lib/stats.sh"
# shellcheck source=./lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"

WATCH=0
WATCH_INTERVAL="${HEALTH_WATCH_INTERVAL:-5}"
DURATION=""
SCREEN=0
FORCE_SCREEN=0
COMPACT=0
SCAN=0
JSON=0

usage() {
  cat <<'USAGE'
Usage: health-dashboard.sh [options]

  --watch [SECONDS]   Refresh continuously (default every 5s). Ctrl-C to leave.
  --duration SECONDS  Exit after this long. With --screen this is how long the
                      status stays on the display (default 5s in --screen mode).
  --screen            Draw onto the display physically attached to the Pi
                      (/dev/tty1), not this terminal.
  --force-screen      Draw on the console even if no display is detected.
  --compact           Small-screen layout: one screenful of essentials.
  --scan              Force a fresh file scan instead of using the cached one.
  --json              Print every metric as JSON and exit.
  --plain             No colour.
  --ascii             No box-drawing or block characters.
  -h, --help          This text.

Environment (also settable in .env):
  HEALTH_WATCH_INTERVAL   default --watch interval
  HEALTH_DISPLAY_SECONDS  default --screen duration
  HEALTH_DISPLAY_TTY      console device (default /dev/tty1)
  HEALTH_DISPLAY_FONT     console font to load while displaying (e.g. Uni2-Terminus32x16)
  HEALTH_SCAN_INTERVAL_MIN  how stale a cached file scan may be (default 15)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)
      WATCH=1
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then WATCH_INTERVAL="$2"; shift; fi
      ;;
    --duration)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "--duration needs a number of seconds" >&2; exit 2; }
      DURATION="$2"; shift ;;
    --screen)       SCREEN=1 ;;
    --force-screen) SCREEN=1; FORCE_SCREEN=1 ;;
    --compact)      COMPACT=1 ;;
    --scan|--deep)  SCAN=1 ;;
    --json)         JSON=1 ;;
    --plain|--no-color) HD_COLOR=0 ;;
    --ascii)        HD_ASCII=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

hd_load_env optional || true
hd_init_style

# Live one-second sampling: on a dashboard "download rate" has to mean right
# now, not "averaged since the last cron run an hour ago".
COLLECT_ARGS=(--live --container-stats)
[[ "$SCAN" == "1" ]] && COLLECT_ARGS+=(--scan)

collect() {
  HD=(); HD_ISSUES=(); HD_OVERALL="ok"
  hd_collect_all "${COLLECT_ARGS[@]}"
}

render() {
  if [[ "$COMPACT" == "1" || "${HD_SMALL_SCREEN:-0}" == "1" ]]; then
    hd_render_compact
  else
    hd_render_full
  fi
}

# ── JSON ─────────────────────────────────────────────────────────────────────
if [[ "$JSON" == "1" ]]; then
  collect
  hd_to_json
  exit 0
fi

# ── Attached screen ──────────────────────────────────────────────────────────
if [[ "$SCREEN" == "1" ]]; then
  if [[ "$FORCE_SCREEN" != "1" ]] && ! hd_screen_connected; then
    echo "No display is connected to this Pi (no DRM connector reports 'connected', no /dev/fb0)." >&2
    echo "Use --force-screen to draw on the console anyway." >&2
    exit 1
  fi

  CONSOLE="$(hd_console_target)" || {
    echo "Cannot write to the console. Add yourself to the 'tty' group or run with sudo." >&2
    exit 1
  }

  # The console is a real terminal even when this script's stdout is a pipe.
  HD_COLOR=1
  hd_init_style

  hd_console_show "$CONSOLE" "${DURATION:-${HEALTH_DISPLAY_SECONDS:-5}}" "$WATCH_INTERVAL" collect render
  exit 0
fi

# ── Terminal ─────────────────────────────────────────────────────────────────
if [[ "$WATCH" == "0" ]]; then
  collect
  render
  exit 0
fi

# Watch mode. The alternate screen buffer keeps the refresh out of the
# scrollback, so leaving the dashboard gives you your terminal back untouched.
# Watch samples go to their own buffer: mixing five-second samples into the
# monitor's hourly history would wreck the long-term sparklines.
HD_HISTORY_FILE="live.csv"
STARTED="$(date +%s)"

cleanup() {
  printf '\033[?25h\033[?1049l'
  exit 0
}
trap cleanup INT TERM EXIT

printf '\033[?1049h\033[?25l'
while true; do
  collect
  hd_history_append
  printf '\033[H\033[2J'
  render
  printf '%s  refreshing every %ss · Ctrl-C to exit%s\n' "$C_DIM" "$WATCH_INTERVAL" "$C_RESET"

  if [[ -n "$DURATION" ]]; then
    elapsed=$(( $(date +%s) - STARTED ))
    [[ "$elapsed" -ge "$DURATION" ]] && break
  fi
  sleep "$WATCH_INTERVAL"
done
