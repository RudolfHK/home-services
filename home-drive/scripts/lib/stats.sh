#!/usr/bin/env bash
# stats.sh — collection and grading of every Home Drive metric.
#
# Sourced by health-monitor.sh (unattended) and health-dashboard.sh (human).
# Both read the same numbers from here so they can never disagree about what
# "healthy" means.
#
# Everything lands in the associative array HD. Problems land in HD_ISSUES as
# "level|component|message" and roll up into HD_OVERALL.
#
# Design notes:
#   * Rates need two samples. Interactive callers set HD_LIVE_SAMPLE=1 and get a
#     real one-second measurement; unattended callers diff against the counters
#     the previous run persisted, which yields the average since then.
#   * Nothing here is allowed to be fatal. A missing tool, an unmounted drive or
#     a dead Docker daemon must degrade to "unknown" and let the other checks
#     run — a health check that aborts on the first problem hides the rest.

[[ -n "${HD_STATS_SOURCED:-}" ]] && return 0
HD_STATS_SOURCED=1

# shellcheck source=./common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

declare -gA HD=()
declare -gA HD_PREV=()
declare -ga HD_ISSUES=()
HD_OVERALL="ok"

# ── Thresholds (override in .env) ────────────────────────────────────────────
HD_DISK_WARN="${HEALTH_DISK_WARN:-75}";      HD_DISK_CRIT="${HEALTH_DISK_CRIT:-90}"
HD_ROOT_WARN="${HEALTH_ROOT_WARN:-85}";      HD_ROOT_CRIT="${HEALTH_ROOT_CRIT:-95}"
HD_TEMP_WARN="${HEALTH_TEMP_WARN:-70}";      HD_TEMP_CRIT="${HEALTH_TEMP_CRIT:-80}"
HD_MEM_WARN="${HEALTH_MEM_WARN:-85}";        HD_MEM_CRIT="${HEALTH_MEM_CRIT:-95}"
HD_CPU_WARN="${HEALTH_CPU_WARN:-85}";        HD_CPU_CRIT="${HEALTH_CPU_CRIT:-95}"
HD_LOAD_WARN="${HEALTH_LOAD_WARN:-100}";     HD_LOAD_CRIT="${HEALTH_LOAD_CRIT:-200}"
HD_BACKUP_WARN_H="${HEALTH_BACKUP_WARN_H:-26}"
HD_BACKUP_CRIT_H="${HEALTH_BACKUP_CRIT_H:-48}"
# CPU/load/memory spikes are normal on a box that is serving files; they are
# coloured in the dashboard but do not page you unless you ask for it.
HD_ALERT_ON_RESOURCE="${HEALTH_ALERT_ON_RESOURCE:-false}"

HD_SCAN_INTERVAL_MIN="${HEALTH_SCAN_INTERVAL_MIN:-30}"
HD_SCAN_TIMEOUT="${HEALTH_SCAN_TIMEOUT:-90}"
HD_SCAN_MAX_FILES="${HEALTH_SCAN_MAX_FILES:-200000}"

HD_SERVICES=(tailscale filebrowser couchdb)

# ── Issue bookkeeping ────────────────────────────────────────────────────────
hd_issue() {
  local level="$1" component="$2" message="$3"
  HD_ISSUES+=("${level}|${component}|${message}")
  HD_OVERALL="$(hd_level_max "$HD_OVERALL" "$level")"
}

# Raise an issue only if the level warrants it.
hd_grade() {
  local level="$1" component="$2" message="$3"
  [[ "$level" == "ok" || "$level" == "unknown" ]] && return 0
  hd_issue "$level" "$component" "$message"
}

# ── Persisted counters ───────────────────────────────────────────────────────
hd_prev_load() {
  local file; file="$(hd_state_dir)/counters.env"
  [[ -r "$file" ]] || return 1
  local line key value
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || continue
    HD_PREV["$key"]="$value"
  done < "$file"
  return 0
}

hd_prev_save() {
  local file; file="$(hd_state_dir)/counters.env"
  local tmp="${file}.tmp.$$"
  {
    local key
    for key in "${!HD_COUNTER[@]}"; do
      printf '%s=%s\n' "$key" "${HD_COUNTER[$key]}"
    done
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

declare -gA HD_COUNTER=()

# hd_delta KEY CURRENT → per-second rate since the previous run (empty if none).
#
# Pure: it reads HD_PREV and writes nothing. Callers must record the new counter
# themselves with HD_COUNTER[key]=current. It has to work this way because every
# caller reads the rate through $(…), and an assignment made inside a command
# substitution happens in a subshell and is lost — which silently left every
# network and disk counter unpersisted, so no rate was ever available.
hd_delta() {
  local key="$1" current="$2"
  local prev="${HD_PREV[$key]:-}" prev_ts="${HD_PREV[ts]:-}" now="${HD[now]}"
  [[ -z "$prev" || -z "$prev_ts" ]] && return 1
  local span=$(( now - prev_ts ))
  [[ "$span" -le 0 ]] && return 1
  # A counter that went backwards means a reboot or an interface reset.
  [[ "$current" -lt "$prev" ]] && return 1
  printf '%s' $(( (current - prev) / span ))
}

# ── System ───────────────────────────────────────────────────────────────────
hd_collect_system() {
  HD[now]="$(date +%s)"
  HD_COUNTER[ts]="${HD[now]}"
  HD[time]="$(date '+%F %T')"
  HD[host]="$(hostname 2>/dev/null || echo unknown)"
  HD[kernel]="$(uname -r 2>/dev/null || echo '-')"

  if [[ -r /proc/device-tree/model ]]; then
    HD[model]="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
  else
    HD[model]="$(uname -m 2>/dev/null || echo '-')"
  fi

  if [[ -r /proc/uptime ]]; then
    HD[uptime_s]="$(awk '{printf "%d", $1}' /proc/uptime)"
  fi

  HD[cores]="$(nproc 2>/dev/null || echo 1)"
  if [[ -r /proc/loadavg ]]; then
    local l1 l5 l15
    read -r l1 l5 l15 _ < /proc/loadavg
    HD[load1]="$l1"; HD[load5]="$l5"; HD[load15]="$l15"
    HD[load_pct]="$(awk -v l="$l1" -v c="${HD[cores]}" 'BEGIN{printf "%d", (c>0 ? l/c*100 : 0)}')"
  fi
  HD[load_level]="$(hd_level "${HD[load_pct]:-}" "$HD_LOAD_WARN" "$HD_LOAD_CRIT")"

  # Memory. MemAvailable is the honest number: "free" excludes cache that the
  # kernel will hand back on demand, and reports a Pi serving files as full.
  if [[ -r /proc/meminfo ]]; then
    local mem_total_kb mem_avail_kb swap_total_kb swap_free_kb
    mem_total_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    mem_avail_kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    # MemAvailable has been in /proc/meminfo since kernel 3.14 and is always
    # there on Pi OS. Missing means something is emulating procfs — report
    # nothing rather than treating "unknown available" as zero and claiming
    # the machine is at 100%.
    if [[ "$mem_total_kb" =~ ^[0-9]+$ && "$mem_avail_kb" =~ ^[0-9]+$ && "$mem_total_kb" -gt 0 ]]; then
      HD[mem_total]=$(( mem_total_kb * 1024 ))
      HD[mem_used]=$(( (mem_total_kb - mem_avail_kb) * 1024 ))
      HD[mem_pct]=$(( (mem_total_kb - mem_avail_kb) * 100 / mem_total_kb ))
    fi
    swap_total_kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"
    swap_free_kb="$(awk '/^SwapFree:/{print $2}' /proc/meminfo)"
    if [[ "$swap_total_kb" =~ ^[0-9]+$ && "$swap_free_kb" =~ ^[0-9]+$ && "$swap_total_kb" -gt 0 ]]; then
      HD[swap_total]=$(( swap_total_kb * 1024 ))
      HD[swap_used]=$(( (swap_total_kb - swap_free_kb) * 1024 ))
      HD[swap_pct]=$(( (swap_total_kb - swap_free_kb) * 100 / swap_total_kb ))
    fi
  fi
  HD[mem_level]="$(hd_level "${HD[mem_pct]:-}" "$HD_MEM_WARN" "$HD_MEM_CRIT")"
  if [[ "$HD_ALERT_ON_RESOURCE" == "true" ]]; then
    hd_grade "${HD[mem_level]}" "memory" "Memory at ${HD[mem_pct]:-?}%"
  elif [[ "${HD[mem_level]}" == "crit" ]]; then
    hd_issue crit memory "Memory at ${HD[mem_pct]}% — the OOM killer is close"
  fi

  # SoC temperature. The sysfs thermal zone is present on every Pi; vcgencmd is
  # not installed on a Lite image unless raspi-utils is.
  local temp_raw=""
  if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    temp_raw="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
    [[ "$temp_raw" =~ ^[0-9]+$ ]] && HD[temp_c]=$(( temp_raw / 1000 ))
  elif command -v vcgencmd >/dev/null 2>&1; then
    HD[temp_c]="$(vcgencmd measure_temp 2>/dev/null | sed -n "s/temp=\([0-9]*\).*/\1/p")"
  fi
  HD[temp_level]="$(hd_level "${HD[temp_c]:-}" "$HD_TEMP_WARN" "$HD_TEMP_CRIT")"
  hd_grade "${HD[temp_level]}" "temperature" "SoC at ${HD[temp_c]:-?} C"

  # Throttling / under-voltage. This is the check that explains a Pi which is
  # mysteriously slow or dropping USB drives: bit 0 = under-voltage now,
  # bit 16 = under-voltage has happened since boot.
  if command -v vcgencmd >/dev/null 2>&1; then
    local flags
    flags="$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)"
    if [[ "$flags" =~ ^0x[0-9a-fA-F]+$ ]]; then
      HD[throttled_hex]="$flags"
      local v=$(( flags ))
      HD[undervolt_now]=$(( (v >> 0) & 1 ))
      HD[throttle_now]=$(( (v >> 2) & 1 ))
      HD[undervolt_ever]=$(( (v >> 16) & 1 ))
      HD[throttle_ever]=$(( (v >> 18) & 1 ))
      [[ "${HD[undervolt_now]}" == "1" ]] && hd_issue crit power "Under-voltage right now — check the PSU and USB load"
      [[ "${HD[throttle_now]}" == "1" ]] && hd_issue warn power "CPU is being thermally throttled"
      if [[ "${HD[undervolt_now]}" == "0" && "${HD[undervolt_ever]}" == "1" ]]; then
        hd_issue warn power "Under-voltage has occurred since boot"
      fi
    fi
  fi

  # Pi 5 active cooler.
  local fan
  for fan in /sys/devices/platform/cooling_fan/hwmon/hwmon*/fan1_input; do
    [[ -r "$fan" ]] || continue
    HD[fan_rpm]="$(cat "$fan" 2>/dev/null)"
    break
  done
}

# ── CPU / network / disk rates ───────────────────────────────────────────────
_hd_cpu_sample() {
  # → "total idle"
  awk '/^cpu /{ idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print total, idle; exit }' /proc/stat 2>/dev/null
}

_hd_net_sample() {
  # → "iface rx_bytes tx_bytes" per line, skipping loopback and Docker's own
  # bridge/veth churn. Replacing the colon re-splits the record, so $1 is the
  # interface, $2 the first rx counter and $10 the first tx counter.
  awk 'NR > 2 {
    sub(/:/, " ");
    if ($1 == "lo" || $1 ~ /^(docker|veth|br-)/) next;
    print $1, $2, $10;
  }' /proc/net/dev 2>/dev/null
}

_hd_disk_sample() {
  # → "dev sectors_read sectors_written" for whole devices only
  awk '$3 ~ /^(sd[a-z]|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/ { print $3, $6, $10 }' /proc/diskstats 2>/dev/null
}

# Collect CPU/net/disk throughput.
#   HD_LIVE_SAMPLE=1 → two samples one second apart (what a human wants to see)
#   otherwise        → diff against the previous run's persisted counters
hd_collect_rates() {
  local live="${HD_LIVE_SAMPLE:-0}" interval="${HD_SAMPLE_SECONDS:-1}"
  local cpu_a cpu_b net_a net_b disk_a disk_b

  cpu_a="$(_hd_cpu_sample)"; net_a="$(_hd_net_sample)"; disk_a="$(_hd_disk_sample)"

  if [[ "$live" == "1" ]]; then
    sleep "$interval"
    cpu_b="$(_hd_cpu_sample)"; net_b="$(_hd_net_sample)"; disk_b="$(_hd_disk_sample)"
    HD[rate_window]="${interval}s"
  else
    cpu_b="$cpu_a"; net_b="$net_a"; disk_b="$disk_a"
    local span=$(( ${HD[now]} - ${HD_PREV[ts]:-0} ))
    if [[ -n "${HD_PREV[ts]:-}" && "$span" -gt 0 ]]; then
      HD[rate_window]="$(hd_duration "$span")"
    else
      HD[rate_window]="first run"
    fi
  fi

  # CPU
  local ta ia tb ib
  read -r ta ia <<< "${cpu_a:-0 0}"
  read -r tb ib <<< "${cpu_b:-0 0}"
  if [[ "$live" == "1" ]]; then
    local dt=$(( tb - ta )) di=$(( ib - ia ))
    [[ "$dt" -gt 0 ]] && HD[cpu_pct]=$(( (dt - di) * 100 / dt ))
  else
    HD_COUNTER[cpu_total]="$tb"; HD_COUNTER[cpu_idle]="$ib"
    local pt="${HD_PREV[cpu_total]:-}" pi="${HD_PREV[cpu_idle]:-}"
    if [[ -n "$pt" && -n "$pi" && "$tb" -gt "$pt" ]]; then
      local dt=$(( tb - pt )) di=$(( ib - pi ))
      [[ "$dt" -gt 0 ]] && HD[cpu_pct]=$(( (dt - di) * 100 / dt ))
    fi
  fi
  HD[cpu_level]="$(hd_level "${HD[cpu_pct]:-}" "$HD_CPU_WARN" "$HD_CPU_CRIT")"
  [[ "$HD_ALERT_ON_RESOURCE" == "true" ]] && hd_grade "${HD[cpu_level]}" "cpu" "CPU at ${HD[cpu_pct]:-?}%"

  # Network — per interface plus a stack-wide total
  local ifaces="" total_rx=0 total_tx=0 rx_rate_sum=0 tx_rate_sum=0
  local name rx_a tx_a rx_b tx_b rx_rate tx_rate
  while read -r name rx_a tx_a; do
    [[ -z "$name" ]] && continue
    rx_b="$rx_a"; tx_b="$tx_a"
    if [[ "$live" == "1" ]]; then
      read -r rx_b tx_b <<< "$(awk -v n="$name" '$1 == n { print $2, $3 }' <<< "$net_b")"
      [[ -z "$rx_b" ]] && continue
      rx_rate=$(( (rx_b - rx_a) / interval ))
      tx_rate=$(( (tx_b - tx_a) / interval ))
    else
      HD_COUNTER["net_${name}_rx"]="$rx_b"
      HD_COUNTER["net_${name}_tx"]="$tx_b"
      rx_rate="$(hd_delta "net_${name}_rx" "$rx_b" || true)"
      tx_rate="$(hd_delta "net_${name}_tx" "$tx_b" || true)"
    fi
    ifaces+="${name} "
    HD["net_${name}_rx"]="$rx_b"
    HD["net_${name}_tx"]="$tx_b"
    HD["net_${name}_rx_rate"]="${rx_rate:-}"
    HD["net_${name}_tx_rate"]="${tx_rate:-}"
    total_rx=$(( total_rx + rx_b ))
    total_tx=$(( total_tx + tx_b ))
    [[ -n "${rx_rate:-}" ]] && rx_rate_sum=$(( rx_rate_sum + rx_rate ))
    [[ -n "${tx_rate:-}" ]] && tx_rate_sum=$(( tx_rate_sum + tx_rate ))
  done <<< "$net_a"

  HD[net_ifaces]="${ifaces% }"
  HD[net_rx_total]="$total_rx"
  HD[net_tx_total]="$total_tx"
  HD[net_rx_rate]="$rx_rate_sum"
  HD[net_tx_rate]="$tx_rate_sum"

  # Disk throughput — 512-byte sectors
  local devs="" read_sum=0 write_sum=0
  local dev rs_a ws_a rs_b ws_b r_rate w_rate
  while read -r dev rs_a ws_a; do
    [[ -z "$dev" ]] && continue
    rs_b="$rs_a"; ws_b="$ws_a"
    if [[ "$live" == "1" ]]; then
      read -r rs_b ws_b <<< "$(awk -v n="$dev" '$1 == n { print $2, $3 }' <<< "$disk_b")"
      [[ -z "$rs_b" ]] && continue
      r_rate=$(( (rs_b - rs_a) * 512 / interval ))
      w_rate=$(( (ws_b - ws_a) * 512 / interval ))
    else
      HD_COUNTER["disk_${dev}_r"]="$rs_b"
      HD_COUNTER["disk_${dev}_w"]="$ws_b"
      r_rate="$(hd_delta "disk_${dev}_r" "$rs_b" || true)"
      w_rate="$(hd_delta "disk_${dev}_w" "$ws_b" || true)"
      [[ -n "$r_rate" ]] && r_rate=$(( r_rate * 512 ))
      [[ -n "$w_rate" ]] && w_rate=$(( w_rate * 512 ))
    fi
    devs+="${dev} "
    HD["disk_${dev}_read_rate"]="${r_rate:-}"
    HD["disk_${dev}_write_rate"]="${w_rate:-}"
    [[ -n "${r_rate:-}" ]] && read_sum=$(( read_sum + r_rate ))
    [[ -n "${w_rate:-}" ]] && write_sum=$(( write_sum + w_rate ))
  done <<< "$disk_a"

  HD[disk_devs]="${devs% }"
  HD[disk_read_rate]="$read_sum"
  HD[disk_write_rate]="$write_sum"
}

# ── Storage ──────────────────────────────────────────────────────────────────
hd_collect_storage() {
  local data="${DATA_PATH:-/mnt/data}"
  HD[data_path]="$data"

  # The check that matters most: if the external drive silently dropped off the
  # USB bus, DATA_PATH still exists as an empty directory on the OS drive.
  if mountpoint -q "$data" 2>/dev/null; then
    HD[data_mounted]=1
  elif [[ -d "$data" ]]; then
    HD[data_mounted]=0
    hd_issue crit storage "$data exists but is NOT a mount point — the external drive is missing"
  else
    HD[data_mounted]=0
    hd_issue crit storage "$data does not exist"
  fi

  if [[ -d "$data" ]]; then
    # Count columns from the RIGHT. A device name containing a space shifts
    # every left-indexed field and turns a size into a percentage; the mount
    # point is the last column and the numbers sit at fixed offsets from it.
    local line dev size used avail pct
    line="$(df -P -B1 "$data" 2>/dev/null | awk 'NR==2 {
      p = $(NF-1); gsub(/%/, "", p);
      print $1, $(NF-4), $(NF-3), $(NF-2), p
    }')"
    if [[ -n "$line" ]]; then
      read -r dev size used avail pct <<< "$line"
      HD[data_dev]="$dev"; HD[data_size]="$size"; HD[data_used]="$used"
      HD[data_avail]="$avail"; HD[data_pct]="$pct"
      HD[data_level]="$(hd_level "${HD[data_pct]}" "$HD_DISK_WARN" "$HD_DISK_CRIT")"
      hd_grade "${HD[data_level]}" "storage" \
        "Data drive at ${HD[data_pct]}% ($(hd_bytes "${HD[data_avail]}") free)"
    fi
    HD[data_fstype]="$(df -PT "$data" 2>/dev/null | awk 'NR==2 {print $2}')"
    # Inodes fill before bytes do on a vault of many tiny files.
    HD[data_inode_pct]="$(df -Pi "$data" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    if [[ "${HD[data_inode_pct]:-0}" =~ ^[0-9]+$ && "${HD[data_inode_pct]}" -ge 90 ]]; then
      hd_issue warn storage "Inode usage at ${HD[data_inode_pct]}% on $data"
    fi
  fi

  local root r_size r_used r_avail r_pct
  root="$(df -P -B1 / 2>/dev/null | awk 'NR==2 {
    p = $(NF-1); gsub(/%/, "", p);
    print $(NF-4), $(NF-3), $(NF-2), p
  }')"
  if [[ -n "$root" ]]; then
    read -r r_size r_used r_avail r_pct <<< "$root"
    HD[root_size]="$r_size"; HD[root_used]="$r_used"
    HD[root_avail]="$r_avail"; HD[root_pct]="$r_pct"
    HD[root_level]="$(hd_level "${HD[root_pct]}" "$HD_ROOT_WARN" "$HD_ROOT_CRIT")"
    hd_grade "${HD[root_level]}" "storage" "Root filesystem at ${HD[root_pct]}%"
  fi

  # SMART, when smartctl is installed and passwordless sudo allows it. Silence
  # is the correct outcome otherwise — this is a bonus, not a requirement.
  if command -v smartctl >/dev/null 2>&1 && [[ -n "${HD[data_dev]:-}" ]]; then
    local base="${HD[data_dev]}"
    base="${base%%[0-9]*}"
    [[ "$base" =~ nvme ]] && base="${HD[data_dev]%p[0-9]*}"
    local smart=""
    if [[ -b "$base" ]]; then
      smart="$(sudo -n smartctl -H -A "$base" 2>/dev/null || smartctl -H -A "$base" 2>/dev/null || true)"
    fi
    if [[ -n "$smart" ]]; then
      HD[smart_dev]="$base"
      HD[smart_health]="$(awk -F: '/overall-health self-assessment/ {gsub(/^ +/,"",$2); print $2}' <<< "$smart" | head -1)"
      [[ -z "${HD[smart_health]}" ]] && HD[smart_health]="$(awk -F: '/SMART overall-health/ {gsub(/^ +/,"",$2); print $2}' <<< "$smart" | head -1)"
      HD[smart_temp]="$(awk '/Temperature_Celsius|^Temperature:/ {for (i=NF; i>0; i--) if ($i ~ /^[0-9]+$/) {print $i; exit}}' <<< "$smart" | head -1)"
      HD[smart_hours]="$(awk '/Power_On_Hours|^Power On Hours/ {for (i=NF; i>0; i--) if ($i ~ /^[0-9,]+$/) {gsub(/,/,"",$i); print $i; exit}}' <<< "$smart" | head -1)"
      HD[smart_realloc]="$(awk '/Reallocated_Sector_Ct/ {print $NF}' <<< "$smart" | head -1)"
      if [[ -n "${HD[smart_health]}" && "${HD[smart_health]}" != "PASSED" && "${HD[smart_health]}" != "OK" ]]; then
        hd_issue crit storage "SMART health on $base is ${HD[smart_health]} — replace the drive"
      fi
      if [[ "${HD[smart_realloc]:-0}" =~ ^[0-9]+$ && "${HD[smart_realloc]}" -gt 0 ]]; then
        hd_issue warn storage "SMART reports ${HD[smart_realloc]} reallocated sectors on $base"
      fi
    fi
  fi

  # Directory breakdown. couchdb/, filebrowser/ and backups/ are small enough to
  # walk every run; files/ is not — its size comes from the activity scan, which
  # is cached and time-boxed.
  local sub
  for sub in couchdb filebrowser backups couchdb-etc; do
    [[ -d "$data/$sub" ]] || continue
    HD["dir_${sub//-/_}_bytes"]="$(du -sb "$data/$sub" 2>/dev/null | awk '{print $1}')"
  done
}

# ── File activity ────────────────────────────────────────────────────────────
# One find pass produces everything: the recent-edit list, the total file count
# and size, and the manifest whose diff against the previous run is the only way
# to see DELETED files — find can list what exists, never what stopped existing.
hd_collect_activity() {
  local force="${1:-0}"
  local state; state="$(hd_state_dir)"
  local root="${DATA_PATH:-/mnt/data}/files"
  local manifest="$state/files-manifest.tsv"
  local cache="$state/activity.env"

  HD[act_root]="$root"

  if [[ ! -d "$root" ]]; then
    HD[act_status]="unavailable"
    return 0
  fi

  # Reuse the cached result when it is fresh enough. A full metadata walk of a
  # multi-terabyte drive is not something to do on every dashboard refresh.
  if [[ "$force" != "1" && -r "$cache" ]]; then
    local age_min=$(( ( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ) / 60 ))
    if [[ "$age_min" -lt "$HD_SCAN_INTERVAL_MIN" ]]; then
      _hd_activity_load "$cache"
      HD[act_status]="cached"
      return 0
    fi
  fi

  local scan; scan="$(mktemp "${TMPDIR:-/tmp}/homedrive-scan.XXXXXX")" || { HD[act_status]="error"; return 0; }
  local timed_out=0

  if command -v timeout >/dev/null 2>&1; then
    timeout "$HD_SCAN_TIMEOUT" find "$root" -xdev -type f -printf '%T@\t%s\t%p\n' > "$scan" 2>/dev/null || timed_out=$?
  else
    find "$root" -xdev -type f -printf '%T@\t%s\t%p\n' > "$scan" 2>/dev/null || true
  fi

  if [[ "$timed_out" == "124" ]]; then
    HD[act_status]="timeout"
    hd_issue warn activity "File scan exceeded ${HD_SCAN_TIMEOUT}s — figures are partial"
  else
    HD[act_status]="fresh"
  fi

  HD[act_count]="$(wc -l < "$scan" | tr -d ' ')"
  HD[act_bytes]="$(awk -F'\t' '{s += $2} END {printf "%d", s}' "$scan")"
  HD[dir_files_bytes]="${HD[act_bytes]}"

  # Most recently written files — "what was last edited or uploaded".
  awk -F'\t' '{printf "%d\t%s\t%s\n", $1, $2, $3}' "$scan" \
    | sort -rn -k1,1 | head -n "${HEALTH_RECENT_COUNT:-8}" > "$state/recent.tsv" 2>/dev/null || true

  # Manifest diff → added / deleted / modified since the previous scan.
  # LC_ALL=C throughout: comm requires both inputs in the same collation, and a
  # locale change between runs would otherwise report the whole tree as churned.
  local new_manifest="$state/files-manifest.new"
  awk -F'\t' '{printf "%s\t%d\t%s\n", $3, $1, $2}' "$scan" \
    | LC_ALL=C sort -t$'\t' -k1,1 > "$new_manifest" 2>/dev/null || true

  : > "$state/added.txt"; : > "$state/deleted.txt"; : > "$state/modified.txt"
  HD[act_added]=0; HD[act_deleted]=0; HD[act_modified]=0
  HD[act_diff]="none"

  if [[ "${HD[act_count]:-0}" -gt "$HD_SCAN_MAX_FILES" ]]; then
    HD[act_diff]="skipped"
    hd_issue warn activity "More than $HD_SCAN_MAX_FILES files — change tracking disabled (raise HEALTH_SCAN_MAX_FILES)"
  elif [[ -r "$manifest" ]]; then
    cut -f1 "$manifest" > "$state/.paths.prev"
    cut -f1 "$new_manifest" > "$state/.paths.new"
    LC_ALL=C comm -13 "$state/.paths.prev" "$state/.paths.new" > "$state/added.txt" 2>/dev/null || true
    LC_ALL=C comm -23 "$state/.paths.prev" "$state/.paths.new" > "$state/deleted.txt" 2>/dev/null || true
    awk -F'\t' 'NR==FNR {a[$1] = $2 "\t" $3; next} ($1 in a) && a[$1] != $2 "\t" $3 {print $1}' \
      "$manifest" "$new_manifest" > "$state/modified.txt" 2>/dev/null || true
    rm -f "$state/.paths.prev" "$state/.paths.new"
    HD[act_added]="$(wc -l < "$state/added.txt" | tr -d ' ')"
    HD[act_deleted]="$(wc -l < "$state/deleted.txt" | tr -d ' ')"
    HD[act_modified]="$(wc -l < "$state/modified.txt" | tr -d ' ')"
    HD[act_diff]="ok"
    HD[act_since]="$(stat -c %Y "$manifest" 2>/dev/null || echo '')"

    # A mass deletion is worth knowing about before the next backup rotates the
    # last copy of those files out of retention.
    local del_warn="${HEALTH_DELETE_WARN:-50}"
    if [[ "${HD[act_deleted]}" -ge "$del_warn" ]]; then
      hd_issue warn activity "${HD[act_deleted]} files disappeared from $root since the last check"
    fi
  else
    HD[act_diff]="baseline"
  fi

  mv -f "$new_manifest" "$manifest" 2>/dev/null || true
  rm -f "$scan"

  HD[act_scanned_at]="${HD[now]}"
  _hd_activity_save "$cache"
}

_hd_activity_save() {
  local file="$1" key
  {
    for key in act_status act_count act_bytes act_added act_deleted act_modified act_diff act_since dir_files_bytes; do
      printf '%s=%s\n' "$key" "${HD[$key]:-}"
    done
  } > "$file" 2>/dev/null || true
}

_hd_activity_load() {
  local file="$1" line key value
  while IFS= read -r line; do
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || continue
    HD["$key"]="$value"
  done < "$file"
  HD[act_scanned_at]="$(stat -c %Y "$file" 2>/dev/null || echo '')"
}

# ── Containers ───────────────────────────────────────────────────────────────
hd_collect_containers() {
  if ! command -v docker >/dev/null 2>&1; then
    hd_issue crit docker "docker is not installed on this host"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    hd_issue crit docker "Cannot talk to the Docker daemon"
    return 0
  fi

  local svc container inspect
  for svc in "${HD_SERVICES[@]}"; do
    container="homedrive-${svc}"
    inspect="$(docker inspect \
      --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}' \
      "$container" 2>/dev/null || true)"

    if [[ -z "$inspect" ]]; then
      HD["dk_${svc}_status"]="missing"
      HD["dk_${svc}_level"]="crit"
      hd_issue crit "$container" "container does not exist"
      continue
    fi

    IFS='|' read -r HD["dk_${svc}_status"] HD["dk_${svc}_health"] HD["dk_${svc}_restarts"] HD["dk_${svc}_started"] <<< "$inspect"

    local started_epoch
    started_epoch="$(date -d "${HD["dk_${svc}_started"]}" +%s 2>/dev/null || echo '')"
    [[ -n "$started_epoch" ]] && HD["dk_${svc}_uptime"]=$(( ${HD[now]} - started_epoch ))

    if [[ "${HD["dk_${svc}_status"]}" != "running" ]]; then
      HD["dk_${svc}_level"]="crit"
      hd_issue crit "$container" "status=${HD["dk_${svc}_status"]}"
    elif [[ "${HD["dk_${svc}_health"]}" != "healthy" && "${HD["dk_${svc}_health"]}" != "none" ]]; then
      HD["dk_${svc}_level"]="warn"
      hd_issue warn "$container" "running but health=${HD["dk_${svc}_health"]}"
    else
      HD["dk_${svc}_level"]="ok"
    fi

    # A container that keeps restarting is "running" every time you look at it.
    if [[ "${HD["dk_${svc}_restarts"]:-0}" =~ ^[0-9]+$ && "${HD["dk_${svc}_restarts"]}" -ge "${HEALTH_RESTART_WARN:-5}" ]]; then
      hd_issue warn "$container" "restarted ${HD["dk_${svc}_restarts"]} times"
    fi
  done

  # Per-container CPU/memory. One docker stats call costs a second or two, so
  # only the dashboard asks for it.
  if [[ "${HD_WANT_CONTAINER_STATS:-0}" == "1" ]]; then
    local line name cpu mem
    while IFS=$'\t' read -r name cpu mem; do
      [[ -z "$name" ]] && continue
      svc="${name#homedrive-}"
      HD["dk_${svc}_cpu"]="$cpu"
      HD["dk_${svc}_mem"]="${mem%% /*}"
    done < <(docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' \
               homedrive-tailscale homedrive-filebrowser homedrive-couchdb 2>/dev/null || true)
  fi
}

# ── Services ─────────────────────────────────────────────────────────────────
# Credentials reach curl through a config file on stdin, never as `-u` on the
# command line: `ps auxww` shows every argument of a docker exec, and this runs
# from a timer.
_hd_couch_curl() {
  local esc_user esc_pass
  esc_user="${COUCHDB_USER//\\/\\\\}"; esc_user="${esc_user//\"/\\\"}"
  esc_pass="${COUCHDB_PASSWORD//\\/\\\\}"; esc_pass="${esc_pass//\"/\\\"}"
  printf 'user = "%s:%s"\n' "$esc_user" "$esc_pass" \
    | docker exec -i homedrive-couchdb curl -sS -f -K - "$@" 2>/dev/null
}

hd_collect_couchdb() {
  local url="http://127.0.0.1:5984"
  HD[couch_up]=0; HD[couch_auth]=0

  [[ "${HD[dk_couchdb_status]:-}" == "running" ]] || return 0

  # /_up needs no credentials (require_valid_user_except_for_up = true).
  if docker exec homedrive-couchdb curl -sf -o /dev/null "${url}/_up" 2>/dev/null; then
    HD[couch_up]=1
  else
    hd_issue crit couchdb "/_up did not respond"
  fi

  # Verify the admin credentials separately: a wrong password in .env breaks
  # backups silently while /_up keeps returning 200.
  local dbs
  if dbs="$(_hd_couch_curl "${url}/_all_dbs")" && [[ -n "$dbs" ]]; then
    HD[couch_auth]=1
    HD[couch_dbs]="$dbs"
  else
    hd_issue crit couchdb "admin credentials rejected (check COUCHDB_USER/COUCHDB_PASSWORD in .env)"
    return 0
  fi

  command -v jq >/dev/null 2>&1 || { HD[couch_detail]="jq not installed"; return 0; }

  local db="${COUCHDB_OBSIDIAN_DB:-obsidian}"
  HD[couch_db]="$db"
  HD[couch_db_count]="$(jq -r '[.[] | select(startswith("_") | not)] | length' <<< "$dbs" 2>/dev/null)"

  if ! jq -e --arg db "$db" 'index($db)' >/dev/null 2>&1 <<< "$dbs"; then
    hd_issue warn couchdb "database '$db' does not exist yet"
    return 0
  fi

  local info
  info="$(_hd_couch_curl "${url}/${db}")" || return 0
  HD[couch_doc_count]="$(jq -r '.doc_count // 0' <<< "$info")"
  HD[couch_del_count]="$(jq -r '.doc_del_count // 0' <<< "$info")"
  HD[couch_size]="$(jq -r '.sizes.file // 0' <<< "$info")"
  HD[couch_seq]="$(jq -r '.update_seq' <<< "$info" | cut -d- -f1)"

  # The update sequence moving is the one honest signal that a device actually
  # synced since the last check — the document count barely moves on edits.
  if [[ "${HD[couch_seq]}" =~ ^[0-9]+$ ]]; then
    local prev_seq="${HD_PREV[couch_seq]:-}"
    HD_COUNTER[couch_seq]="${HD[couch_seq]}"
    if [[ "$prev_seq" =~ ^[0-9]+$ && "${HD[couch_seq]}" -ge "$prev_seq" ]]; then
      HD[couch_seq_delta]=$(( ${HD[couch_seq]} - prev_seq ))
    fi
  fi

  local changes
  changes="$(_hd_couch_curl "${url}/${db}/_changes?descending=true&limit=1&include_docs=true")" || return 0
  HD[couch_last_change]="$(jq -r '(.results[0].doc.mtime // .results[0].doc.ctime // empty) | if . then (. / 1000 | floor) else empty end' <<< "$changes" 2>/dev/null)"
}

hd_collect_filebrowser() {
  HD[fb_up]=0
  [[ "${HD[dk_filebrowser_status]:-}" == "running" ]] || return 0
  # The image ships busybox wget, which cannot report a status code — the exit
  # status is all we get. /health exists on modern v2 builds; fall back to /.
  if docker exec homedrive-filebrowser wget -q -O /dev/null "http://127.0.0.1:8080/health" 2>/dev/null \
     || docker exec homedrive-filebrowser wget -q -O /dev/null "http://127.0.0.1:8080/" 2>/dev/null; then
    HD[fb_up]=1
  else
    hd_issue crit filebrowser "not responding on :8080"
  fi
}

hd_collect_tailscale() {
  HD[ts_state]="unknown"
  [[ "${HD[dk_tailscale_status]:-}" == "running" ]] || return 0

  local json
  json="$(docker exec homedrive-tailscale tailscale status --json 2>/dev/null || echo '{}')"

  if command -v jq >/dev/null 2>&1; then
    HD[ts_state]="$(jq -r '.BackendState // "unknown"' <<< "$json")"
    HD[ts_ip]="$(jq -r '.Self.TailscaleIPs[0] // ""' <<< "$json")"
    HD[ts_name]="$(jq -r '.Self.DNSName // "" | rtrimstr(".")' <<< "$json")"
    HD[ts_peers]="$(jq -r '(.Peer // {}) | length' <<< "$json")"
    HD[ts_peers_online]="$(jq -r '[(.Peer // {})[] | select(.Online)] | length' <<< "$json")"
    HD[ts_rx]="$(jq -r '[(.Peer // {})[] | .RxBytes // 0] | add // 0' <<< "$json")"
    HD[ts_tx]="$(jq -r '[(.Peer // {})[] | .TxBytes // 0] | add // 0' <<< "$json")"
  else
    # tailscale pretty-prints its JSON; collapse whitespace before matching or
    # the key never matches and a healthy tailnet reads as down.
    HD[ts_state]="$(tr -d '[:space:]' <<< "$json" | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4)"
    HD[ts_state]="${HD[ts_state]:-unknown}"
    HD[ts_ip]="(jq not installed)"
  fi

  if [[ "${HD[ts_state]}" != "Running" ]]; then
    hd_issue crit tailscale "BackendState=${HD[ts_state]}"
  fi
}

# ── Backups ──────────────────────────────────────────────────────────────────
hd_collect_backups() {
  local dest="${BACKUP_DEST:-${DATA_PATH:-/mnt/data}/backups}"
  HD[bk_dest]="$dest"

  if [[ ! -d "$dest" ]]; then
    hd_issue warn backup "backup directory $dest does not exist"
    return 0
  fi

  local latest
  latest="$(ls -1t "$dest"/homedrive_*.tar.gz 2>/dev/null | head -n1)"
  HD[bk_count]="$(ls -1 "$dest"/homedrive_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  HD[bk_total]="$(du -sb "$dest" 2>/dev/null | awk '{print $1}')"

  if [[ -z "$latest" ]]; then
    hd_issue warn backup "no backups found in $dest — is the nightly job installed?"
    return 0
  fi

  HD[bk_latest]="$(basename "$latest")"
  HD[bk_latest_epoch]="$(stat -c %Y "$latest" 2>/dev/null)"
  HD[bk_size]="$(stat -c %s "$latest" 2>/dev/null)"
  HD[bk_age_h]=$(( ( ${HD[now]} - ${HD[bk_latest_epoch]} ) / 3600 ))
  HD[bk_level]="$(hd_level "${HD[bk_age_h]}" "$HD_BACKUP_WARN_H" "$HD_BACKUP_CRIT_H")"
  hd_grade "${HD[bk_level]}" "backup" \
    "newest backup is ${HD[bk_age_h]}h old (${HD[bk_latest]})"
}

# ── History ──────────────────────────────────────────────────────────────────
# A rolling buffer of samples so the dashboard can draw sparklines instead of
# single numbers. Capped so it can never grow into a disk-space problem itself.
hd_history_append() {
  local file; file="$(hd_state_dir)/${HD_HISTORY_FILE:-history.csv}"
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "${HD[now]}" "${HD[cpu_pct]:-}" "${HD[temp_c]:-}" "${HD[mem_pct]:-}" \
    "${HD[data_pct]:-}" "${HD[net_rx_rate]:-}" "${HD[net_tx_rate]:-}" >> "$file" 2>/dev/null || return 0

  local max="${HEALTH_HISTORY_POINTS:-240}"
  local lines; lines="$(wc -l < "$file" 2>/dev/null || echo 0)"
  if [[ "$lines" -gt $(( max * 2 )) ]]; then
    tail -n "$max" "$file" > "${file}.tmp" 2>/dev/null && mv -f "${file}.tmp" "$file"
  fi
}

# hd_history_column N → space-separated values of field N, oldest first
hd_history_column() {
  local col="$1" file
  file="$(hd_state_dir)/${HD_HISTORY_FILE:-history.csv}"
  [[ -r "$file" ]] || return 0
  awk -F, -v c="$col" -v n="${2:-240}" '{ v[NR] = $c } END {
    start = (NR > n) ? NR - n + 1 : 1;
    out = "";
    for (i = start; i <= NR; i++) if (v[i] != "") out = out v[i] " ";
    print out;
  }' "$file"
}

# ── Orchestration ────────────────────────────────────────────────────────────
# hd_collect_all [--live] [--scan] [--container-stats]
hd_collect_all() {
  local live=0 scan=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --live)            live=1 ;;
      --scan)            scan=1 ;;
      --container-stats) HD_WANT_CONTAINER_STATS=1 ;;
    esac
  done

  hd_prev_load || true
  HD_LIVE_SAMPLE="$live"

  hd_collect_system
  hd_collect_rates
  hd_collect_storage
  hd_collect_containers
  hd_collect_couchdb
  hd_collect_filebrowser
  hd_collect_tailscale
  hd_collect_backups
  hd_collect_activity "$scan"

  hd_prev_save
}

# ── Serialisation ────────────────────────────────────────────────────────────
hd_to_json() {
  local key first=1
  printf '{\n  "overall": "%s",\n  "issues": [' "$HD_OVERALL"
  local issue level component message
  for issue in ${HD_ISSUES[@]+"${HD_ISSUES[@]}"}; do
    IFS='|' read -r level component message <<< "$issue"
    [[ "$first" == "1" ]] && first=0 || printf ','
    printf '\n    {"level": "%s", "component": "%s", "message": "%s"}' \
      "$(hd_json_escape "$level")" "$(hd_json_escape "$component")" "$(hd_json_escape "$message")"
  done
  [[ "$first" == "1" ]] || printf '\n  '
  printf '],\n  "metrics": {'

  first=1
  for key in $(printf '%s\n' "${!HD[@]}" | sort); do
    [[ "$first" == "1" ]] && first=0 || printf ','
    printf '\n    "%s": "%s"' "$(hd_json_escape "$key")" "$(hd_json_escape "${HD[$key]}")"
  done
  printf '\n  }\n}\n'
}

# One-line summary used by ntfy and the log.
hd_summary_line() {
  local issue level component message parts=()
  for issue in ${HD_ISSUES[@]+"${HD_ISSUES[@]}"}; do
    IFS='|' read -r level component message <<< "$issue"
    parts+=("${component}: ${message}")
  done
  if [[ "${#parts[@]}" -eq 0 ]]; then
    printf 'all checks passed'
    return 0
  fi
  local i
  for i in "${!parts[@]}"; do
    [[ "$i" -gt 0 ]] && printf '; '
    printf '%s' "${parts[$i]}"
  done
}
