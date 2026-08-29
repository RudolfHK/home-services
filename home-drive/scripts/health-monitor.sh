#!/usr/bin/env bash
# health-monitor.sh — the unattended half of Home Drive monitoring.
#
# Runs from a systemd timer (or cron), says nothing when everything is fine,
# alerts once when it is not, and records every sample so the dashboard has
# history to draw. Its interactive sibling is health-dashboard.sh.
#
# Install it with scripts/install-monitoring.sh, or by hand:
#   0 * * * * /home/pi/home-services/home-drive/scripts/health-monitor.sh >> /var/log/homedrive-health.log 2>&1
#
# Exit status:
#   0  everything passed
#   1  warnings only
#   2  at least one failure
# Non-zero means cron mails you even when NTFY_URL is not configured.
#
# NOTE: deliberately no `set -e`. This script's job is to run every check and
# report all of them; aborting on the first failure would hide the rest.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=./lib/stats.sh
source "$SCRIPT_DIR/lib/stats.sh"
# shellcheck source=./lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"

VERBOSE=0
QUIET=0
JSON=0
NOTIFY=1
SCREEN="${HEALTH_DISPLAY:-auto}"   # auto | off | force
SHOW_STATUS=0

usage() {
  cat <<'USAGE'
Usage: health-monitor.sh [options]

  -v, --verbose   Print every check, not just the problems.
  -q, --quiet     Print nothing; communicate through the exit status alone.
      --json      Write the full metric set as JSON to stdout.
      --status    Print the result of the last run and exit without checking.
      --no-notify Skip the ntfy notification.
      --screen    Always flash the result onto the attached display.
      --no-screen Never flash it.
  -h, --help      This text.

Exit status: 0 = ok, 1 = warnings, 2 = failures.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1 ;;
    -q|--quiet)   QUIET=1 ;;
    --json)       JSON=1 ;;
    --status)     SHOW_STATUS=1 ;;
    --no-notify)  NOTIFY=0 ;;
    --screen)     SCREEN="force" ;;
    --no-screen)  SCREEN="off" ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

hd_load_env required
hd_init_style
STATE="$(hd_state_dir)"

# ── --status: report what the last run found, without re-running it ──────────
if [[ "$SHOW_STATUS" == "1" ]]; then
  if [[ -r "$STATE/status.txt" ]]; then
    cat "$STATE/status.txt"
    exit 0
  fi
  echo "No recorded status yet — run $0 first."
  exit 1
fi

# ── Run the checks ───────────────────────────────────────────────────────────
# No --live: sampling for a second in a timer job is a second of nothing. The
# rates come from diffing this run's counters against the previous run's, which
# also makes them averages over the whole interval rather than a random second.
hd_collect_all
hd_history_append

case "$HD_OVERALL" in
  ok)   EXIT_CODE=0 ;;
  warn) EXIT_CODE=1 ;;
  *)    EXIT_CODE=2 ;;
esac

SUMMARY="$(hd_summary_line)"

# ── Record for the dashboard, /var/log and anything else that asks ───────────
hd_to_json > "$STATE/status.json" 2>/dev/null || true
{
  printf '%s %s: %s\n' "${HD[time]}" "${HD_OVERALL^^}" "$SUMMARY"
} > "$STATE/status.txt" 2>/dev/null || true

# ── Output ───────────────────────────────────────────────────────────────────
if [[ "$JSON" == "1" ]]; then
  hd_to_json
elif [[ "$QUIET" == "0" ]]; then
  if [[ "$VERBOSE" == "1" ]]; then
    printf '======= Home Drive health %s =======\n' "${HD[time]}"
    hd_render_log
  fi
  if [[ "$EXIT_CODE" == "0" ]]; then
    [[ "$VERBOSE" == "1" ]] && printf '%s %s[OK]%s   all checks passed\n' "${HD[time]}" "$C_GREEN" "$C_RESET"
  else
    # Without --verbose nothing has been printed yet, so print the problems —
    # this is what lands in the log and in cron's mail. With --verbose they are
    # already in the per-check output above; repeating them adds noise.
    if [[ "$VERBOSE" == "0" ]]; then
      for issue in "${HD_ISSUES[@]}"; do
        IFS='|' read -r lvl comp msg <<< "$issue"
        case "$lvl" in
          crit) tag="${C_RED}[FAIL]${C_RESET}" ;;
          *)    tag="${C_YELLOW}[WARN]${C_RESET}" ;;
        esac
        printf '%s %s %s: %s\n' "${HD[time]}" "$tag" "$comp" "$msg"
      done
    fi
    printf '%s [SUMMARY] %s\n' "${HD[time]}" "$SUMMARY"
  fi
fi

# ── Notify ───────────────────────────────────────────────────────────────────
# Repeat-suppression matters more than it looks: an hourly check with a drive
# that has been full since Tuesday would otherwise send 168 identical push
# notifications a week, and you would mute the topic — right before the one
# alert that mattered.
notify() {
  local title="$1" priority="$2" tags="$3" body="$4"
  [[ "$NOTIFY" == "1" && -n "${NTFY_URL:-}" ]] || return 0
  curl -sf \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$body" \
    "$NTFY_URL" -o /dev/null \
    || printf '%s [WARN] ntfy notification failed\n' "${HD[time]}"
}

ALERT_STATE="$STATE/alert.env"
PREV_HASH=""; PREV_TIME=0
if [[ -r "$ALERT_STATE" ]]; then
  # shellcheck disable=SC1090
  source "$ALERT_STATE" 2>/dev/null || true
  PREV_HASH="${ALERT_HASH:-}"
  PREV_TIME="${ALERT_TIME:-0}"
fi

if [[ "$EXIT_CODE" != "0" ]]; then
  CURRENT_HASH="$(printf '%s' "$SUMMARY" | cksum | awk '{print $1}')"
  REPEAT_H="${HEALTH_ALERT_REPEAT_HOURS:-6}"
  AGE_H=$(( ( ${HD[now]} - PREV_TIME ) / 3600 ))

  if [[ "$CURRENT_HASH" != "$PREV_HASH" || "$AGE_H" -ge "$REPEAT_H" ]]; then
    PRIORITY="high"; TAGS="warning"
    [[ "$HD_OVERALL" == "warn" ]] && { PRIORITY="default"; TAGS="warning"; }
    notify "Home Drive: $(hd_verdict_text)" "$PRIORITY" "$TAGS" \
      "${TS_HOSTNAME:-${HD[host]}}: $SUMMARY"
    printf 'ALERT_HASH=%s\nALERT_TIME=%s\n' "$CURRENT_HASH" "${HD[now]}" > "$ALERT_STATE" 2>/dev/null || true
  fi
elif [[ -n "$PREV_HASH" ]]; then
  # Recovered since the last run — say so once, then forget.
  notify "Home Drive: recovered" "default" "white_check_mark" \
    "${TS_HOSTNAME:-${HD[host]}}: all checks passing again"
  rm -f "$ALERT_STATE" 2>/dev/null || true
fi

# ── Flash the result onto a screen attached to the Pi ────────────────────────
# Skipped silently when the Pi is headless, which is the normal case.
if [[ "$SCREEN" != "off" ]]; then
  if [[ "$SCREEN" == "force" ]] || hd_screen_connected; then
    if CONSOLE="$(hd_console_target)"; then
      HD_COLOR=1
      hd_init_style
      DISPLAY_SECONDS="${HEALTH_DISPLAY_SECONDS:-5}"
      # Nothing to re-collect during a five-second flash — reuse this run's
      # numbers by handing the console loop a collector that does nothing.
      hd_console_show "$CONSOLE" "$DISPLAY_SECONDS" "$DISPLAY_SECONDS" : hd_render_compact
    fi
  fi
fi

exit "$EXIT_CODE"
