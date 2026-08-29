#!/usr/bin/env bash
# common.sh — shared helpers for the Home Drive monitoring scripts.
#
# Sourced by health-monitor.sh and health-dashboard.sh. Never executed directly.
# Contains no collection logic: only environment loading, state-directory
# resolution, formatting and terminal/console handling.

[[ -n "${HD_COMMON_SOURCED:-}" ]] && return 0
HD_COMMON_SOURCED=1

# ── Paths ────────────────────────────────────────────────────────────────────
HD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HD_SCRIPT_DIR="$(dirname "$HD_LIB_DIR")"
HD_PROJECT_DIR="$(dirname "$HD_SCRIPT_DIR")"

# Load .env. The monitor has to keep working on a half-broken box, so a missing
# .env is fatal only when the caller says it is.
hd_load_env() {
  local required="${1:-required}"
  local env_file="$HD_PROJECT_DIR/.env"

  if [[ ! -f "$env_file" ]]; then
    if [[ "$required" == "required" ]]; then
      echo "ERROR: $env_file not found." >&2
      exit 1
    fi
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  DATA_PATH="${DATA_PATH:-/mnt/data}"
  BACKUP_DEST="${BACKUP_DEST:-${DATA_PATH}/backups}"
  return 0
}

# Where deltas, history and file manifests live.
#
# Deliberately NOT under $DATA_PATH by default: the whole point of several
# checks is to notice that the data drive fell off the USB bus, and a state
# directory that disappears with the drive would take the rate counters and the
# file manifest with it — exactly when they are most useful.
hd_state_dir() {
  if [[ -n "${HD_STATE_DIR:-}" ]]; then
    printf '%s' "$HD_STATE_DIR"
    return 0
  fi

  local candidates=(
    "${HEALTH_STATE_DIR:-}"
    "/var/lib/homedrive"
    "${XDG_STATE_HOME:-$HOME/.local/state}/homedrive"
    "${TMPDIR:-/tmp}/homedrive"
  )
  local dir
  for dir in "${candidates[@]}"; do
    [[ -z "$dir" ]] && continue
    if [[ -d "$dir" && -w "$dir" ]] || mkdir -p "$dir" 2>/dev/null; then
      HD_STATE_DIR="$dir"
      printf '%s' "$dir"
      return 0
    fi
  done

  HD_STATE_DIR="${TMPDIR:-/tmp}"
  printf '%s' "$HD_STATE_DIR"
}

# ── Colour and glyphs ────────────────────────────────────────────────────────
# HD_COLOR / HD_ASCII may be forced by the caller (--plain, --ascii) before this
# runs; hd_init_style only fills in what is still unset.
hd_init_style() {
  if [[ -z "${HD_COLOR:-}" ]]; then
    if [[ -n "${NO_COLOR:-}" ]]; then HD_COLOR=0
    elif [[ -t 1 ]]; then HD_COLOR=1
    else HD_COLOR=0
    fi
  fi

  if [[ -z "${HD_ASCII:-}" ]]; then
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
      *UTF-8*|*utf8*|*UTF8*) HD_ASCII=0 ;;
      *) HD_ASCII=1 ;;
    esac
  fi

  if [[ "$HD_COLOR" == "1" ]]; then
    C_RED=$'\033[0;31m';   C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m';  C_CYAN=$'\033[0;36m';  C_MAGENTA=$'\033[0;35m'
    C_DIM=$'\033[2m';      C_BOLD=$'\033[1m';     C_RESET=$'\033[0m'
  else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_MAGENTA=''
    C_DIM=''; C_BOLD=''; C_RESET=''
  fi

  if [[ "$HD_ASCII" == "1" ]]; then
    G_FULL='#'; G_EMPTY='.'; G_H='-'; G_V='|'
    G_TL='+'; G_TR='+'; G_BL='+'; G_BR='+'
    G_OK='ok'; G_WARN='!!'; G_CRIT='XX'; G_DOT='-'
    HD_SPARK_CHARS=(_ _ . . - - = =)
  else
    G_FULL='█'; G_EMPTY='░'; G_H='─'; G_V='│'
    G_TL='╭'; G_TR='╮'; G_BL='╰'; G_BR='╯'
    G_OK='●'; G_WARN='▲'; G_CRIT='✖'; G_DOT='·'
    HD_SPARK_CHARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  fi
}

hd_term_width() {
  local w="${HEALTH_WIDTH:-${COLUMNS:-}}"
  [[ -z "$w" ]] && w="$(tput cols 2>/dev/null || true)"
  [[ -z "$w" || ! "$w" =~ ^[0-9]+$ || "$w" -lt 60 ]] && w=80
  [[ "$w" -gt 120 ]] && w=120
  printf '%s' "$w"
}

# ── Severity ─────────────────────────────────────────────────────────────────
# hd_level VALUE WARN CRIT  → ok | warn | crit   (higher value is worse)
hd_level() {
  local v="${1:-}" warn="$2" crit="$3"
  [[ "$v" =~ ^-?[0-9]+$ ]] || { printf 'unknown'; return; }
  if   [[ "$v" -ge "$crit" ]]; then printf 'crit'
  elif [[ "$v" -ge "$warn" ]]; then printf 'warn'
  else printf 'ok'
  fi
}

hd_level_color() {
  case "${1:-}" in
    ok)   printf '%s' "$C_GREEN" ;;
    warn) printf '%s' "$C_YELLOW" ;;
    crit) printf '%s' "$C_RED" ;;
    *)    printf '%s' "$C_DIM" ;;
  esac
}

hd_level_glyph() {
  case "${1:-}" in
    ok)   printf '%s' "$G_OK" ;;
    warn) printf '%s' "$G_WARN" ;;
    crit) printf '%s' "$G_CRIT" ;;
    *)    printf '%s' "$G_DOT" ;;
  esac
}

hd_level_rank() {
  case "${1:-}" in
    crit) printf 3 ;; warn) printf 2 ;; ok) printf 1 ;; *) printf 0 ;;
  esac
}

# Worst of two levels.
hd_level_max() {
  local ra rb
  ra="$(hd_level_rank "${1:-}")"
  rb="$(hd_level_rank "${2:-}")"
  if [[ "$ra" -ge "$rb" ]]; then printf '%s' "${1:-unknown}"; else printf '%s' "${2:-unknown}"; fi
}

# ── Formatting ───────────────────────────────────────────────────────────────
# Bytes → human readable. awk rather than numfmt: one less thing to depend on,
# and numfmt's output width varies in ways that break column alignment.
hd_bytes() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || { printf '%s' '-'; return; }
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB PB", u, " ");
    i = 1;
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1)       printf "%d %s", b, u[i];
    else if (b < 10)  printf "%.2f %s", b, u[i];
    else if (b < 100) printf "%.1f %s", b, u[i];
    else              printf "%.0f %s", b, u[i];
  }'
}

# Bytes per second → "12.4 MB/s"
hd_rate() {
  printf '%s/s' "$(hd_bytes "${1:-0}")"
}

# Seconds → "3d 4h" / "12m"
hd_duration() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf '%s' '-'; return; }
  local d=$(( s / 86400 )) h=$(( (s % 86400) / 3600 )) m=$(( (s % 3600) / 60 ))
  if   [[ "$d" -gt 0 ]]; then printf '%dd %dh' "$d" "$h"
  elif [[ "$h" -gt 0 ]]; then printf '%dh %dm' "$h" "$m"
  elif [[ "$m" -gt 0 ]]; then printf '%dm' "$m"
  else printf '%ds' "$s"
  fi
}

# Epoch → "4m ago"
hd_ago() {
  local t="${1:-}"
  [[ "$t" =~ ^[0-9]+$ ]] || { printf 'never'; return; }
  local now delta
  now="$(date +%s)"
  delta=$(( now - t ))
  [[ "$delta" -lt 0 ]] && delta=0
  printf '%s ago' "$(hd_duration "$delta")"
}

# hd_bar PERCENT WIDTH [LEVEL] → coloured block gauge
hd_bar() {
  local pct="${1:-0}" width="${2:-20}" level="${3:-}"
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [[ "$pct" -gt 100 ]] && pct=100
  [[ "$pct" -lt 0 ]] && pct=0
  [[ -z "$level" ]] && level="$(hd_level "$pct" 75 90)"

  local filled=$(( pct * width / 100 ))
  [[ "$filled" -gt "$width" ]] && filled="$width"
  local empty=$(( width - filled ))

  local on='' off='' i
  for (( i = 0; i < filled; i++ )); do on+="$G_FULL"; done
  for (( i = 0; i < empty; i++ )); do off+="$G_EMPTY"; done

  printf '%s%s%s%s%s' "$(hd_level_color "$level")" "$on" "$C_DIM" "$off" "$C_RESET"
}

# hd_spark "v1 v2 v3 …" [POINTS] → sparkline scaled to the sample range.
# Scaling to the range rather than to 0-100 is deliberate: a temperature that
# only ever moves between 48 °C and 54 °C would otherwise render as a flat line
# and show nothing at all.
hd_spark() {
  local values="${1:-}" max_pts="${2:-24}"
  [[ -z "${values// /}" ]] && { printf '%s' "${C_DIM}no history yet${C_RESET}"; return; }

  local line
  line="$(awk -v vals="$values" -v n="$max_pts" -v chars="${HD_SPARK_CHARS[*]}" 'BEGIN{
    cn = split(chars, c, " ");
    m  = split(vals, v, " ");
    start = (m > n) ? m - n + 1 : 1;
    lo = 1e18; hi = -1e18;
    for (i = start; i <= m; i++) {
      if (v[i] !~ /^-?[0-9.]+$/) continue;
      if (v[i] + 0 < lo) lo = v[i] + 0;
      if (v[i] + 0 > hi) hi = v[i] + 0;
    }
    if (lo > hi) { print ""; exit }
    span = hi - lo;
    out = "";
    for (i = start; i <= m; i++) {
      if (v[i] !~ /^-?[0-9.]+$/) continue;
      idx = (span == 0) ? 1 : int((v[i] + 0 - lo) / span * (cn - 1)) + 1;
      if (idx < 1) idx = 1;
      if (idx > cn) idx = cn;
      out = out c[idx];
    }
    print out;
  }')"

  [[ -z "$line" ]] && line="$G_DOT"
  printf '%s' "$line"
}

# Pad or truncate to an exact display width (assumes single-column glyphs).
hd_fit() {
  local s="${1:-}" w="${2:-10}"
  local len=${#s}
  if [[ "$len" -gt "$w" ]]; then
    if [[ "$w" -gt 3 ]]; then printf '%s...' "${s:0:$((w-3))}"
    else printf '%s' "${s:0:$w}"; fi
  else
    printf '%s%*s' "$s" "$(( w - len ))" ''
  fi
}

# Truncate from the right without padding — for prose, where the start matters.
hd_trunc() {
  local s="${1:-}" w="${2:-40}"
  [[ "$w" -lt 4 ]] && w=4
  if [[ "${#s}" -gt "$w" ]]; then printf '%s...' "${s:0:$((w-3))}"
  else printf '%s' "$s"; fi
}

# Shorten a long path from the left: /mnt/data/files/a/b/c.md → …/a/b/c.md
hd_shortpath() {
  local p="${1:-}" w="${2:-48}"
  local len=${#p}
  [[ "$len" -le "$w" ]] && { printf '%s' "$p"; return; }
  if [[ "$HD_ASCII" == "1" ]]; then printf '...%s' "${p:$(( len - w + 3 ))}"
  else printf '…%s' "${p:$(( len - w + 1 ))}"; fi
}

hd_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ── Physical console ─────────────────────────────────────────────────────────
# "Is a screen actually plugged in?" — a headless Pi still has /dev/tty1, so the
# presence of a console proves nothing. The DRM connector state does: any
# card*-HDMI-A-1/status reading "connected" means a display is attached and
# powered. /dev/fb0 covers the SPI/DSI panels (small LCD HATs) that expose no
# DRM connector.
hd_screen_connected() {
  local status
  for status in /sys/class/drm/card*-*/status; do
    [[ -r "$status" ]] || continue
    [[ "$(cat "$status" 2>/dev/null)" == "connected" ]] && return 0
  done
  [[ -e /dev/fb0 ]] && return 0
  return 1
}

# Which device to draw on. Writing to /dev/tty1 needs the tty group or root, so
# writability is part of the test — no point selecting a console we cannot use.
hd_console_target() {
  local candidates=("${HEALTH_DISPLAY_TTY:-}" /dev/tty1 /dev/tty0)
  local dev
  for dev in "${candidates[@]}"; do
    [[ -z "$dev" ]] && continue
    [[ -c "$dev" && -w "$dev" ]] && { printf '%s' "$dev"; return 0; }
  done
  return 1
}
