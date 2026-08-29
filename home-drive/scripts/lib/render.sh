#!/usr/bin/env bash
# render.sh — turns the HD metric array into something a human reads at a glance.
#
# Used by health-dashboard.sh (terminal) and by health-monitor.sh when it flashes
# the result onto a screen attached to the Pi. Both call the same renderer, so
# what you see on the TV is exactly what you see over SSH.
#
# No side borders anywhere: a right-hand border requires knowing the display
# width of every line, and ANSI colour codes make that arithmetic wrong in ways
# that only show up on someone else's terminal. Section rules and indentation
# carry the structure instead.

[[ -n "${HD_RENDER_SOURCED:-}" ]] && return 0
HD_RENDER_SOURCED=1

# ── Primitives ───────────────────────────────────────────────────────────────
hd_repeat() {
  local char="$1" count="$2" out='' i
  [[ "$count" -lt 0 ]] && count=0
  for (( i = 0; i < count; i++ )); do out+="$char"; done
  printf '%s' "$out"
}

hd_rule() {
  local title="${1:-}" w="${HD_W:-80}"
  if [[ -z "$title" ]]; then
    printf '%s%s%s\n' "$C_DIM" "$(hd_repeat "$G_H" "$w")" "$C_RESET"
    return 0
  fi
  # One rule glyph, a space, the title, a space, then fill to the full width.
  local fill=$(( w - 3 - ${#title} ))
  [[ "$fill" -lt 0 ]] && fill=0
  printf '%s%s%s %s%s%s %s%s%s\n' \
    "$C_DIM" "$G_H" "$C_RESET" \
    "$C_BOLD" "$title" "$C_RESET" \
    "$C_DIM" "$(hd_repeat "$G_H" "$fill")" "$C_RESET"
}

hd_heavy_rule() {
  local w="${HD_W:-80}" ch='='
  [[ "$HD_ASCII" == "1" ]] || ch='═'
  printf '%s%s%s\n' "$C_DIM" "$(hd_repeat "$ch" "$w")" "$C_RESET"
}

# Thousands separators where the locale supports them, plain digits where not.
hd_num() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || { printf '%s' '-'; return; }
  printf "%'d" "$n" 2>/dev/null || printf '%s' "$n"
}

hd_verdict_text() {
  case "$HD_OVERALL" in
    ok)   printf 'ALL SYSTEMS NOMINAL' ;;
    warn) printf 'NEEDS ATTENTION' ;;
    crit) printf 'ACTION REQUIRED' ;;
    *)    printf 'UNKNOWN' ;;
  esac
}

# ── Sections ─────────────────────────────────────────────────────────────────
hd_render_header() {
  local color glyph
  color="$(hd_level_color "$HD_OVERALL")"
  glyph="$(hd_level_glyph "$HD_OVERALL")"

  hd_heavy_rule
  printf ' %s%s%s %sHOME DRIVE%s  %s%s%s   %s%s%s\n' \
    "$color" "$glyph" "$C_RESET" "$C_BOLD" "$C_RESET" \
    "$C_CYAN" "${HD[host]:-?}" "$C_RESET" \
    "$color$C_BOLD" "$(hd_verdict_text)" "$C_RESET"
  printf ' %s%s · up %s · %s%s\n' \
    "$C_DIM" "${HD[model]:-?}" "$(hd_duration "${HD[uptime_s]:-0}")" "${HD[time]:-}" "$C_RESET"
  hd_heavy_rule
}

hd_render_services() {
  hd_rule "SERVICES"

  local svc level color glyph line
  for svc in "${HD_SERVICES[@]}"; do
    level="${HD["dk_${svc}_level"]:-unknown}"
    color="$(hd_level_color "$level")"
    glyph="$(hd_level_glyph "$level")"
    line="$(printf '  %s%s%s %s %s %s' \
      "$color" "$glyph" "$C_RESET" \
      "$(hd_fit "$svc" 16)" \
      "$(hd_fit "${HD["dk_${svc}_status"]:-?}" 9)" \
      "$(hd_fit "${HD["dk_${svc}_health"]:-}" 9)")"
    # Uptime is meaningless for a container that is not running — showing the
    # last start time next to "exited" reads as though it were still up.
    if [[ "${HD["dk_${svc}_status"]:-}" == "running" ]]; then
      line+="$(hd_fit "up $(hd_duration "${HD["dk_${svc}_uptime"]:-0}")" 12)"
    else
      line+="$(hd_fit "" 12)"
    fi
    if [[ -n "${HD["dk_${svc}_cpu"]:-}" ]]; then
      line+="$(printf '%scpu %s  mem %s%s' "$C_DIM" "${HD["dk_${svc}_cpu"]}" "${HD["dk_${svc}_mem"]:-?}" "$C_RESET")"
    elif [[ "${HD["dk_${svc}_restarts"]:-0}" != "0" ]]; then
      line+="$(printf '%s%s restarts%s' "$C_DIM" "${HD["dk_${svc}_restarts"]}" "$C_RESET")"
    fi
    printf '%s\n' "$line"
  done

  # Tailnet
  local ts_level="crit"
  [[ "${HD[ts_state]:-}" == "Running" ]] && ts_level="ok"
  printf '  %s%s%s %s %s%s%s' \
    "$(hd_level_color "$ts_level")" "$(hd_level_glyph "$ts_level")" "$C_RESET" \
    "$(hd_fit "tailnet" 16)" "$C_CYAN" "$(hd_fit "${HD[ts_ip]:-no address}" 18)" "$C_RESET"
  if [[ -n "${HD[ts_peers]:-}" ]]; then
    printf '%s%s/%s peers online%s' "$C_DIM" "${HD[ts_peers_online]:-0}" "${HD[ts_peers]}" "$C_RESET"
  fi
  printf '\n'

  # CouchDB / Obsidian sync
  local couch_level="crit" detail
  if [[ "${HD[couch_up]:-0}" != "1" ]]; then
    detail="CouchDB is not answering on :5984"
  elif [[ "${HD[couch_auth]:-0}" != "1" ]]; then
    detail="admin credentials rejected — check COUCHDB_PASSWORD in .env"
  else
    couch_level="ok"
    detail="${HD[couch_db]:-couchdb}: auth ok"
    if [[ -n "${HD[couch_doc_count]:-}" ]]; then
      detail="${HD[couch_db]:-couchdb} · $(hd_num "${HD[couch_doc_count]}") docs · $(hd_bytes "${HD[couch_size]:-0}")"
      # The update sequence moving is the honest sign that a device synced.
      if [[ -n "${HD[couch_seq_delta]:-}" ]]; then
        if [[ "${HD[couch_seq_delta]}" -gt 0 ]]; then
          detail+=" · ${C_GREEN}+${HD[couch_seq_delta]} synced${C_RESET}"
        else
          detail+=" · ${C_DIM}no sync activity${C_RESET}"
        fi
      fi
    fi
  fi
  printf '  %s%s%s %s %s\n' \
    "$(hd_level_color "$couch_level")" "$(hd_level_glyph "$couch_level")" "$C_RESET" \
    "$(hd_fit "sync" 16)" "$detail"

  # FileBrowser HTTP
  local fb_level="crit" fb_text="not responding on :8080"
  if [[ "${HD[fb_up]:-0}" == "1" ]]; then fb_level="ok"; fb_text="responding on :8080"; fi
  printf '  %s%s%s %s %s\n' \
    "$(hd_level_color "$fb_level")" "$(hd_level_glyph "$fb_level")" "$C_RESET" \
    "$(hd_fit "web ui" 16)" "$fb_text"

  # Nextcloud, only when the drive is installed.
  if [[ "${HD[drive_present]:-0}" == "1" ]]; then
    local nc_level="crit" nc_text="not responding"
    if [[ "${HD[nc_up]:-0}" == "1" ]]; then
      if [[ "${HD[nc_maintenance]:-}" == "true" ]]; then
        nc_level="warn"; nc_text="MAINTENANCE MODE — offline for everyone"
      elif [[ "${HD[nc_needs_upgrade]:-}" == "true" ]]; then
        nc_level="crit"; nc_text="database upgrade pending — run occ upgrade"
      elif [[ "${HD[nc_installed]:-}" != "true" ]]; then
        nc_level="crit"; nc_text="not installed — run scripts/install-drive.sh"
      else
        nc_level="ok"; nc_text="${HD[nc_version]:-} · locking active"
      fi
    fi
    printf '  %s%s%s %s %s\n' \
      "$(hd_level_color "$nc_level")" "$(hd_level_glyph "$nc_level")" "$C_RESET" \
      "$(hd_fit "drive" 16)" "$nc_text"
  fi
  printf '\n'
}

hd_render_storage() {
  hd_rule "STORAGE"

  local bar_w=$(( HD_W / 4 ))
  [[ "$bar_w" -gt 24 ]] && bar_w=24

  if [[ "${HD[data_mounted]:-0}" == "1" && -n "${HD[data_pct]:-}" ]]; then
    printf '  %s %s %s%3s%%%s  %s free of %s  %s%s%s\n' \
      "$(hd_fit "data" 6)" \
      "$(hd_bar "${HD[data_pct]}" "$bar_w" "${HD[data_level]:-}")" \
      "$(hd_level_color "${HD[data_level]:-}")" "${HD[data_pct]}" "$C_RESET" \
      "$(hd_bytes "${HD[data_avail]:-0}")" "$(hd_bytes "${HD[data_size]:-0}")" \
      "$C_DIM" "${HD[data_fstype]:-} ${HD[data_dev]:-}" "$C_RESET"

    # Where the space actually went.
    local breakdown="" sub key
    for sub in files nextcloud couchdb filebrowser backups; do
      key="dir_${sub}_bytes"
      [[ -n "${HD[$key]:-}" ]] || continue
      [[ -n "$breakdown" ]] && breakdown+=" · "
      breakdown+="$sub $(hd_bytes "${HD[$key]}")"
    done
    [[ -n "$breakdown" ]] && printf '         %s%s%s\n' "$C_DIM" "$breakdown" "$C_RESET"

    local extra=""
    [[ -n "${HD[data_inode_pct]:-}" ]] && extra="inodes ${HD[data_inode_pct]}%"
    if [[ -n "${HD[smart_health]:-}" ]]; then
      extra+=" · SMART ${HD[smart_health]}"
      [[ -n "${HD[smart_temp]:-}" ]] && extra+=" · drive ${HD[smart_temp]} C"
      [[ -n "${HD[smart_hours]:-}" ]] && extra+=" · $(hd_num "${HD[smart_hours]}") h powered on"
      [[ "${HD[smart_realloc]:-0}" != "0" ]] && extra+=" · ${HD[smart_realloc]} reallocated"
    fi
    [[ -n "$extra" ]] && printf '         %s%s%s\n' "$C_DIM" "$extra" "$C_RESET"
  else
    printf '  %s %s%s NOT MOUNTED%s  %s%s%s\n' \
      "$(hd_fit "data" 6)" "$C_RED" "$G_CRIT" "$C_RESET" \
      "$C_DIM" "${HD[data_path]:-?} — the external drive is missing" "$C_RESET"
  fi

  if [[ -n "${HD[root_pct]:-}" ]]; then
    printf '  %s %s %s%3s%%%s  %s free of %s\n' \
      "$(hd_fit "root" 6)" \
      "$(hd_bar "${HD[root_pct]}" "$bar_w" "${HD[root_level]:-}")" \
      "$(hd_level_color "${HD[root_level]:-}")" "${HD[root_pct]}" "$C_RESET" \
      "$(hd_bytes "${HD[root_avail]:-0}")" "$(hd_bytes "${HD[root_size]:-0}")"
  fi
  printf '\n'
}

hd_render_pi() {
  hd_rule "RASPBERRY PI"

  local bar_w=16 spark_w=24

  # Temperature
  local temp_pct=0
  [[ "${HD[temp_c]:-}" =~ ^[0-9]+$ ]] && temp_pct=$(( HD[temp_c] * 100 / 85 ))
  printf '  %s %s%4s C%s  %s  %s' \
    "$(hd_fit "temp" 6)" \
    "$(hd_level_color "${HD[temp_level]:-}")" "${HD[temp_c]:-?}" "$C_RESET" \
    "$(hd_bar "$temp_pct" "$bar_w" "${HD[temp_level]:-}")" \
    "$(hd_spark "$(hd_history_column 3 "$spark_w")" "$spark_w")"
  [[ -n "${HD[fan_rpm]:-}" ]] && printf '  %sfan %s rpm%s' "$C_DIM" "${HD[fan_rpm]}" "$C_RESET"
  printf '\n'

  # CPU + load
  printf '  %s %s%4s %%%s  %s  %s  %sload %s / %s cores%s\n' \
    "$(hd_fit "cpu" 6)" \
    "$(hd_level_color "${HD[cpu_level]:-}")" "${HD[cpu_pct]:-?}" "$C_RESET" \
    "$(hd_bar "${HD[cpu_pct]:-0}" "$bar_w" "${HD[cpu_level]:-}")" \
    "$(hd_spark "$(hd_history_column 2 "$spark_w")" "$spark_w")" \
    "$C_DIM" "${HD[load1]:-?}" "${HD[cores]:-?}" "$C_RESET"

  # Memory
  printf '  %s %s%4s %%%s  %s  %s%s of %s' \
    "$(hd_fit "ram" 6)" \
    "$(hd_level_color "${HD[mem_level]:-}")" "${HD[mem_pct]:-?}" "$C_RESET" \
    "$(hd_bar "${HD[mem_pct]:-0}" "$bar_w" "${HD[mem_level]:-}")" \
    "$C_DIM" "$(hd_bytes "${HD[mem_used]:-0}")" "$(hd_bytes "${HD[mem_total]:-0}")"
  [[ "${HD[swap_pct]:-0}" != "0" ]] && printf ' · swap %s%%' "${HD[swap_pct]}"
  printf '%s\n' "$C_RESET"

  # Power / throttling — the flags that explain a mysteriously slow Pi
  if [[ -n "${HD[throttled_hex]:-}" ]]; then
    local pw_level="ok" pw_text="no under-voltage or throttling since boot"
    if [[ "${HD[undervolt_now]}" == "1" ]]; then
      pw_level="crit"; pw_text="UNDER-VOLTAGE NOW — check the PSU and USB load"
    elif [[ "${HD[throttle_now]}" == "1" ]]; then
      pw_level="warn"; pw_text="thermally throttled right now"
    elif [[ "${HD[undervolt_ever]}" == "1" || "${HD[throttle_ever]}" == "1" ]]; then
      pw_level="warn"; pw_text="under-voltage or throttling has occurred since boot"
    fi
    printf '  %s %s%s %s%s\n' \
      "$(hd_fit "power" 6)" "$(hd_level_color "$pw_level")" "$(hd_level_glyph "$pw_level")" "$pw_text" "$C_RESET"
  fi
  printf '\n'
}

hd_render_transfer() {
  hd_rule "TRANSFER (${HD[rate_window]:-?})"

  local spark_w=24
  printf '  %s %s%10s%s  %s  %stotal %s%s\n' \
    "$(hd_fit "down" 6)" "$C_GREEN" "$(hd_rate "${HD[net_rx_rate]:-0}")" "$C_RESET" \
    "$(hd_spark "$(hd_history_column 6 "$spark_w")" "$spark_w")" \
    "$C_DIM" "$(hd_bytes "${HD[net_rx_total]:-0}")" "$C_RESET"
  printf '  %s %s%10s%s  %s  %stotal %s%s\n' \
    "$(hd_fit "up" 6)" "$C_BLUE" "$(hd_rate "${HD[net_tx_rate]:-0}")" "$C_RESET" \
    "$(hd_spark "$(hd_history_column 7 "$spark_w")" "$spark_w")" \
    "$C_DIM" "$(hd_bytes "${HD[net_tx_total]:-0}")" "$C_RESET"
  printf '  %s %sread %s · write %s%s\n' \
    "$(hd_fit "disk" 6)" "$C_DIM" \
    "$(hd_rate "${HD[disk_read_rate]:-0}")" "$(hd_rate "${HD[disk_write_rate]:-0}")" "$C_RESET"
  printf '  %s %s%s%s\n' \
    "$(hd_fit "links" 6)" "$C_DIM" "${HD[net_ifaces]:-none}" "$C_RESET"
  printf '\n'
}

# hd_render_activity PREFIX SLUG TITLE
#
# Renders one file tree's activity. PREFIX namespaces the metrics (act / dact),
# SLUG the state files (files / drive) — see _hd_scan_tree.
hd_render_activity() {
  local prefix="${1:-act}" slug="${2:-files}" title="${3:-FILE ACTIVITY}"
  local state; state="$(hd_state_dir)"

  local since=""
  [[ -n "${HD["${prefix}_since"]:-}" ]] && since=" since $(hd_ago "${HD["${prefix}_since"]}")"
  hd_rule "${title}${since}"

  case "${HD["${prefix}_status"]:-}" in
    absent)
      printf '  %sthe drive is not installed — see docs/DRIVE.md%s\n\n' "$C_DIM" "$C_RESET"
      return 0 ;;
    unavailable)
      printf '  %s%s is not readable%s\n\n' "$C_DIM" "${HD["${prefix}_root"]:-?}" "$C_RESET"
      return 0 ;;
  esac

  printf '  %s files · %s' \
    "$(hd_num "${HD["${prefix}_count"]:-0}")" "$(hd_bytes "${HD["${prefix}_bytes"]:-0}")"
  case "${HD["${prefix}_diff"]:-}" in
    ok)
      printf '   %s+%s new%s  %s~%s changed%s  %s-%s deleted%s' \
        "$C_GREEN" "${HD["${prefix}_added"]:-0}" "$C_RESET" \
        "$C_CYAN" "${HD["${prefix}_modified"]:-0}" "$C_RESET" \
        "$C_YELLOW" "${HD["${prefix}_deleted"]:-0}" "$C_RESET"
      ;;
    baseline) printf '   %s(first scan — change tracking starts now)%s' "$C_DIM" "$C_RESET" ;;
    skipped)  printf '   %s(too many files for change tracking)%s' "$C_DIM" "$C_RESET" ;;
  esac
  [[ "${HD["${prefix}_status"]:-}" == "cached" ]] && printf '   %s[cached]%s' "$C_DIM" "$C_RESET"
  printf '\n'

  # Most recently written files: what was last edited or uploaded.
  local root="${HD["${prefix}_root"]:-}"
  local path_w=$(( HD_W - 32 ))
  [[ "$path_w" -lt 20 ]] && path_w=20
  local mtime size path rel marker mcolor stamp shown=0
  if [[ -r "$state/${slug}-recent.tsv" ]]; then
    while IFS=$'\t' read -r mtime size path; do
      [[ -z "$path" ]] && continue
      marker="~"; mcolor="$C_CYAN"
      if [[ -s "$state/${slug}-added.txt" ]] \
         && grep -Fxq -- "$path" "$state/${slug}-added.txt" 2>/dev/null; then
        marker="+"; mcolor="$C_GREEN"
      fi
      stamp="$(date -d "@$mtime" '+%m-%d %H:%M' 2>/dev/null || echo '     ')"
      rel="${path#"$root"/}"
      printf '  %s%s%s %s%s%s  %9s  %s\n' \
        "$mcolor" "$marker" "$C_RESET" "$C_DIM" "$stamp" "$C_RESET" \
        "$(hd_bytes "$size")" "$(hd_shortpath "$rel" "$path_w")"
      shown=$(( shown + 1 ))
    done < "$state/${slug}-recent.tsv"
  fi

  # Deletions have no mtime to sort by — they only exist as a manifest diff.
  if [[ -s "$state/${slug}-deleted.txt" ]]; then
    local count=0 limit="${HEALTH_DELETED_SHOWN:-3}"
    while IFS= read -r path; do
      [[ "$count" -ge "$limit" ]] && break
      rel="${path#"$root"/}"
      printf '  %s-%s %s%s%s  %9s  %s\n' \
        "$C_YELLOW" "$C_RESET" "$C_DIM" "           " "$C_RESET" "" \
        "$(hd_shortpath "$rel" "$path_w")"
      count=$(( count + 1 ))
      shown=$(( shown + 1 ))
    done < "$state/${slug}-deleted.txt"
    if [[ "${HD["${prefix}_deleted"]:-0}" -gt "$limit" ]]; then
      printf '  %s  … and %s more deleted%s\n' \
        "$C_DIM" "$(( ${HD["${prefix}_deleted"]} - limit ))" "$C_RESET"
    fi
  fi

  [[ "$shown" == "0" ]] && printf '  %sno file activity recorded yet%s\n' "$C_DIM" "$C_RESET"
  printf '\n'
}

# hd_render_backup [SUBSYSTEM]
#
# One nightly archive covers the whole stack, so the panel is the same either
# way; SUBSYSTEM (drive | obsidian) adds the line that actually matters to the
# thing you asked about — what of it is really in there.
hd_render_backup() {
  local subsystem="${1:-}"
  hd_rule "BACKUP"

  if [[ -z "${HD[bk_latest]:-}" ]]; then
    printf '  %s%s%s no archives in %s\n' \
      "$C_YELLOW" "$G_WARN" "$C_RESET" "${HD[bk_dest]:-?}"
  else
    printf '  %s%s%s %s  %s  %s  %s%s kept · %s total%s\n' \
      "$(hd_level_color "${HD[bk_level]:-}")" "$(hd_level_glyph "${HD[bk_level]:-}")" "$C_RESET" \
      "${HD[bk_latest]}" \
      "$(hd_ago "${HD[bk_latest_epoch]:-}")" \
      "$(hd_bytes "${HD[bk_size]:-0}")" \
      "$C_DIM" "${HD[bk_count]:-0}" "$(hd_bytes "${HD[bk_total]:-0}")" "$C_RESET"
  fi

  case "$subsystem" in
    drive)
      if [[ "${BACKUP_INCLUDE_NEXTCLOUD_DATA:-false}" == "true" ]]; then
        printf '         %sdrive: database, config and every user file%s\n' "$C_DIM" "$C_RESET"
      else
        printf '         %sdrive: database and config only — user files are NOT in the archive%s\n' \
          "$C_YELLOW" "$C_RESET"
        printf '         %sset BACKUP_INCLUDE_NEXTCLOUD_DATA=true, or mirror them with rclone%s\n' \
          "$C_DIM" "$C_RESET"
      fi
      ;;
    obsidian)
      printf '         %svault: every CouchDB database is dumped in full%s\n' "$C_DIM" "$C_RESET"
      if [[ "${BACKUP_INCLUDE_FILES:-false}" == "true" ]]; then
        printf '         %sfiles: the FileBrowser tree is included%s\n' "$C_DIM" "$C_RESET"
      else
        printf '         %sfiles: the FileBrowser tree is NOT in the archive (BACKUP_INCLUDE_FILES=false)%s\n' \
          "$C_YELLOW" "$C_RESET"
      fi
      ;;
  esac
  printf '\n'
}

hd_render_issues() {
  [[ "${#HD_ISSUES[@]}" -eq 0 ]] && return 0
  hd_rule "NEEDS ATTENTION"
  local issue level component message
  for issue in "${HD_ISSUES[@]}"; do
    IFS='|' read -r level component message <<< "$issue"
    printf '  %s%s%s %s%s%s %s\n' \
      "$(hd_level_color "$level")" "$(hd_level_glyph "$level")" "$C_RESET" \
      "$C_BOLD" "$component" "$C_RESET" "$message"
  done
  printf '\n'
}

# ── Whole screens ────────────────────────────────────────────────────────────
# The base sections are always drawn: they describe the machine, and the machine
# is the same machine whichever subsystem you came to look at.
#
# File activity, backup and the issue list are per-subsystem, selected by the
# caller through these switches (health-dashboard.sh sets them from --drive /
# --obsidian). Default is base-only, which is the fast view: no tree walk.
HD_SHOW_ACTIVITY_FILES="${HD_SHOW_ACTIVITY_FILES:-0}"
HD_SHOW_ACTIVITY_DRIVE="${HD_SHOW_ACTIVITY_DRIVE:-0}"
HD_SHOW_BACKUP="${HD_SHOW_BACKUP:-0}"
HD_SHOW_ISSUES="${HD_SHOW_ISSUES:-0}"
HD_BACKUP_SUBSYSTEM="${HD_BACKUP_SUBSYSTEM:-}"

hd_render_full() {
  HD_W="$(hd_term_width)"
  hd_render_header
  hd_render_services
  hd_render_storage
  hd_render_pi
  hd_render_transfer

  [[ "$HD_SHOW_ACTIVITY_FILES" == "1" ]] && \
    hd_render_activity act files "FILE ACTIVITY (obsidian / filebrowser)"
  [[ "$HD_SHOW_ACTIVITY_DRIVE" == "1" ]] && \
    hd_render_activity dact drive "FILE ACTIVITY (drive)"

  [[ "$HD_SHOW_BACKUP" == "1" ]] && hd_render_backup "$HD_BACKUP_SUBSYSTEM"

  if [[ "$HD_SHOW_ISSUES" == "1" ]]; then
    hd_render_issues
  elif [[ "${#HD_ISSUES[@]}" -gt 0 ]]; then
    # Never hide the fact that something is wrong. The base sections already
    # colour a failed container or an unmounted drive, but an itemised list that
    # silently disappears with the default flags would be a trap.
    local worst_color
    worst_color="$(hd_level_color "$HD_OVERALL")"
    printf '%s%s %s issue(s) outstanding%s — %s--drive%s or %s--obsidian%s to itemise them\n\n' \
      "$worst_color" "$(hd_level_glyph "$HD_OVERALL")" "${#HD_ISSUES[@]}" "$C_RESET" \
      "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
  fi
  return 0
}

# Twelve lines for a small LCD HAT or a five-second glance from across the room.
hd_render_compact() {
  HD_W="$(hd_term_width)"
  local color glyph
  color="$(hd_level_color "$HD_OVERALL")"
  glyph="$(hd_level_glyph "$HD_OVERALL")"

  printf '%s%s %s%s  %s%s\n' \
    "$color$C_BOLD" "$glyph" "$(hd_verdict_text)" "$C_RESET" \
    "$C_DIM${HD[host]:-?} · ${HD[time]:-}" "$C_RESET"
  hd_rule

  local up=0 svc
  for svc in "${HD_SERVICES[@]}"; do
    [[ "${HD["dk_${svc}_level"]:-}" == "ok" ]] && up=$(( up + 1 ))
  done
  printf 'services %s%s/%s up%s   sync %s   web %s\n' \
    "$( [[ "$up" == "${#HD_SERVICES[@]}" ]] && printf '%s' "$C_GREEN" || printf '%s' "$C_RED" )" \
    "$up" "${#HD_SERVICES[@]}" "$C_RESET" \
    "$( [[ "${HD[couch_auth]:-0}" == "1" ]] && printf 'ok' || printf 'DOWN' )" \
    "$( [[ "${HD[fb_up]:-0}" == "1" ]] && printf 'ok' || printf 'DOWN' )"

  if [[ "${HD[data_mounted]:-0}" == "1" ]]; then
    printf 'disk     %s %s%%  %s free\n' \
      "$(hd_bar "${HD[data_pct]:-0}" 14 "${HD[data_level]:-}")" \
      "${HD[data_pct]:-?}" "$(hd_bytes "${HD[data_avail]:-0}")"
  else
    printf 'disk     %sNOT MOUNTED%s\n' "$C_RED$C_BOLD" "$C_RESET"
  fi
  printf 'temp     %s %s C\n' "$(hd_bar "$(( ${HD[temp_c]:-0} * 100 / 85 ))" 14 "${HD[temp_level]:-}")" "${HD[temp_c]:-?}"
  printf 'cpu      %s %s%%\n' "$(hd_bar "${HD[cpu_pct]:-0}" 14 "${HD[cpu_level]:-}")" "${HD[cpu_pct]:-?}"
  printf 'ram      %s %s%%\n' "$(hd_bar "${HD[mem_pct]:-0}" 14 "${HD[mem_level]:-}")" "${HD[mem_pct]:-?}"
  printf 'net      down %s  up %s\n' "$(hd_rate "${HD[net_rx_rate]:-0}")" "$(hd_rate "${HD[net_tx_rate]:-0}")"
  # One line per tree that was actually scanned. Printing "files 0 · 0 B" when
  # the scan was skipped would read as an empty drive rather than as no data.
  if [[ -n "${HD[act_count]:-}" ]]; then
    printf 'files    %s · %s' "$(hd_num "${HD[act_count]}")" "$(hd_bytes "${HD[act_bytes]:-0}")"
    [[ "${HD[act_diff]:-}" == "ok" ]] && \
      printf '  +%s ~%s -%s' "${HD[act_added]:-0}" "${HD[act_modified]:-0}" "${HD[act_deleted]:-0}"
    printf '\n'
  fi
  if [[ -n "${HD[dact_count]:-}" ]]; then
    printf 'drive    %s · %s' "$(hd_num "${HD[dact_count]}")" "$(hd_bytes "${HD[dact_bytes]:-0}")"
    [[ "${HD[dact_diff]:-}" == "ok" ]] && \
      printf '  +%s ~%s -%s' "${HD[dact_added]:-0}" "${HD[dact_modified]:-0}" "${HD[dact_deleted]:-0}"
    printf '\n'
  fi
  printf 'backup   %s\n' "$( [[ -n "${HD[bk_latest]:-}" ]] && hd_ago "${HD[bk_latest_epoch]}" || printf 'none' )"

  if [[ "${#HD_ISSUES[@]}" -gt 0 ]]; then
    hd_rule
    local issue level component message shown=0
    for issue in "${HD_ISSUES[@]}"; do
      [[ "$shown" -ge 4 ]] && { printf '%s… and %s more%s\n' "$C_DIM" "$(( ${#HD_ISSUES[@]} - 4 ))" "$C_RESET"; break; }
      IFS='|' read -r level component message <<< "$issue"
      # Truncate from the right: these are sentences, not paths.
      printf '%s%s%s %s: %s\n' \
        "$(hd_level_color "$level")" "$(hd_level_glyph "$level")" "$C_RESET" "$component" \
        "$(hd_trunc "$message" $(( HD_W - ${#component} - 5 )))"
      shown=$(( shown + 1 ))
    done
  fi
}

# Line-per-check output for logs and cron mail. No cursor tricks, no bars.
hd_render_log() {
  local svc
  for svc in "${HD_SERVICES[@]}"; do
    _hd_log_line "${HD["dk_${svc}_level"]:-unknown}" \
      "homedrive-${svc}: ${HD["dk_${svc}_status"]:-?} (${HD["dk_${svc}_health"]:-none})"
  done
  _hd_log_line "$( [[ "${HD[data_mounted]:-0}" == "1" ]] && echo ok || echo crit )" \
    "${HD[data_path]:-?}: $( [[ "${HD[data_mounted]:-0}" == "1" ]] && echo mounted || echo 'NOT MOUNTED' )"
  [[ -n "${HD[data_pct]:-}" ]] && _hd_log_line "${HD[data_level]:-}" \
    "data disk: ${HD[data_pct]}% used, $(hd_bytes "${HD[data_avail]:-0}") free"
  [[ -n "${HD[root_pct]:-}" ]] && _hd_log_line "${HD[root_level]:-}" "root disk: ${HD[root_pct]}% used"
  [[ -n "${HD[temp_c]:-}" ]] && _hd_log_line "${HD[temp_level]:-}" "soc temperature: ${HD[temp_c]} C"
  _hd_log_line "$( [[ "${HD[ts_state]:-}" == "Running" ]] && echo ok || echo crit )" \
    "tailscale: ${HD[ts_state]:-unknown} ${HD[ts_ip]:-}"
  _hd_log_line "$( [[ "${HD[couch_up]:-0}" == "1" ]] && echo ok || echo crit )" "couchdb: /_up"
  _hd_log_line "$( [[ "${HD[couch_auth]:-0}" == "1" ]] && echo ok || echo crit )" "couchdb: admin credentials"
  [[ -n "${HD[couch_doc_count]:-}" ]] && _hd_log_line ok \
    "couchdb: ${HD[couch_doc_count]} docs in ${HD[couch_db]:-?}, +${HD[couch_seq_delta]:-0} updates since last run"
  _hd_log_line "$( [[ "${HD[fb_up]:-0}" == "1" ]] && echo ok || echo crit )" "filebrowser: :8080"
  [[ -n "${HD[bk_latest]:-}" ]] && _hd_log_line "${HD[bk_level]:-}" \
    "backup: ${HD[bk_latest]} is ${HD[bk_age_h]}h old"
  if [[ "${HD[act_diff]:-}" == "ok" ]]; then
    _hd_log_line ok "files: ${HD[act_count]} files, $(hd_bytes "${HD[act_bytes]:-0}"), +${HD[act_added]} ~${HD[act_modified]} -${HD[act_deleted]}"
  fi
  if [[ "${HD[dact_diff]:-}" == "ok" ]]; then
    _hd_log_line ok "drive: ${HD[dact_count]} files, $(hd_bytes "${HD[dact_bytes]:-0}"), +${HD[dact_added]} ~${HD[dact_modified]} -${HD[dact_deleted]}"
  fi
  [[ -n "${HD[net_rx_rate]:-}" ]] && _hd_log_line ok \
    "network: down $(hd_rate "${HD[net_rx_rate]}"), up $(hd_rate "${HD[net_tx_rate]:-0}") averaged over ${HD[rate_window]:-?}"
}

# ── Painting the physically attached screen ──────────────────────────────────
# hd_console_show CONSOLE SECONDS INTERVAL COLLECT_FN RENDER_FN
#
# Draws the dashboard on the Pi's own display for SECONDS, refreshing every
# INTERVAL, then hands the console back. Used by --screen and by the monitor's
# post-check flash.
#
# The collector runs in this shell (it fills global state); only the renderer is
# captured in a subshell, so nothing it does can leak into the next frame.
hd_console_show() {
  local console="$1" seconds="$2" interval="$3" collect_fn="$4" render_fn="$5"
  local rows cols size

  size="$(stty -F "$console" size 2>/dev/null || true)"
  read -r rows cols <<< "${size:-24 80}"
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  export HEALTH_WIDTH="$cols"
  if [[ "$rows" -lt 22 || "$cols" -lt 70 ]]; then
    export HD_SMALL_SCREEN=1
  fi

  # A console that has blanked itself shows nothing however hard we draw on it.
  if command -v setterm >/dev/null 2>&1; then
    setterm --term linux --blank poke > "$console" 2>/dev/null || true
  fi
  # An optional large font makes this readable from across the room on a TV.
  if [[ -n "${HEALTH_DISPLAY_FONT:-}" ]] && command -v setfont >/dev/null 2>&1; then
    setfont "$HEALTH_DISPLAY_FONT" -C "$console" 2>/dev/null || true
  fi

  HD_CONSOLE_DEV="$console"
  trap _hd_console_restore EXIT INT TERM

  local started frame elapsed remaining
  started="$(date +%s)"
  printf '\033[?25l' > "$console" 2>/dev/null || true

  while true; do
    "$collect_fn"
    frame="$("$render_fn")"
    printf '\033[H\033[2J%s' "$frame" > "$console" 2>/dev/null || true

    # SECONDS = 0 means "stay up until something kills us" — the kiosk service.
    if [[ "$seconds" -le 0 ]]; then
      sleep "$interval"
      continue
    fi
    elapsed=$(( $(date +%s) - started ))
    remaining=$(( seconds - elapsed ))
    [[ "$remaining" -le 0 ]] && break
    if [[ "$remaining" -lt "$interval" ]]; then sleep "$remaining"; else sleep "$interval"; fi
    # Collecting takes a second or two, so re-check before drawing again: without
    # this a five-second flash spends its last moment rendering a frame nobody
    # gets to read.
    [[ $(( $(date +%s) - started )) -ge "$seconds" ]] && break
  done

  _hd_console_restore
  trap - EXIT INT TERM
}

# Give the console back: cursor on, screen cleared, original font restored.
_hd_console_restore() {
  [[ -n "${HD_CONSOLE_DEV:-}" ]] || return 0
  printf '\033[?25h\033[2J\033[H' > "$HD_CONSOLE_DEV" 2>/dev/null || true
  if [[ -n "${HEALTH_DISPLAY_FONT:-}" ]] && command -v setfont >/dev/null 2>&1; then
    setfont -C "$HD_CONSOLE_DEV" 2>/dev/null || true
  fi
}

_hd_log_line() {
  local level="${1:-unknown}" text="$2" tag
  case "$level" in
    ok)   tag="${C_GREEN}[OK]${C_RESET}  " ;;
    warn) tag="${C_YELLOW}[WARN]${C_RESET}" ;;
    crit) tag="${C_RED}[FAIL]${C_RESET}" ;;
    *)    tag="${C_DIM}[----]${C_RESET}" ;;
  esac
  printf '%s %s %s\n' "${HD[time]:-}" "$tag" "$text"
}
