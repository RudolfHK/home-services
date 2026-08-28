#!/usr/bin/env bash
# healthcheck.sh — Check container health, the data mount, disk space,
#                  Tailscale state, service reachability and backup freshness.
#
# Exits non-zero when anything is wrong, so cron mails you even if NTFY_URL is
# not configured.
#
# Add to crontab (run `crontab -e`):
#   0 * * * * /home/pi/home-services/home-drive/scripts/healthcheck.sh >> /var/log/homedrive-health.log 2>&1
set -uo pipefail
# NOTE: deliberately no `set -e`. This script's job is to run every check and
# report all of them; aborting on the first failure would hide the rest.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found."; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

TIMESTAMP="$(date '+%F %T')"
ISSUES=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "$TIMESTAMP ${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "$TIMESTAMP ${YELLOW}[WARN]${NC} $*"; ISSUES+=("$*"); }
fail() { echo -e "$TIMESTAMP ${RED}[FAIL]${NC} $*"; ISSUES+=("$*"); }

DATA_PATH="${DATA_PATH:-/mnt/data}"
BACKUP_DEST="${BACKUP_DEST:-${DATA_PATH}/backups}"

echo "======= Health check $TIMESTAMP ======="

# ── 1. Container status ───────────────────────────────────────────────────────
for SERVICE in tailscale filebrowser couchdb; do
  CONTAINER="homedrive-${SERVICE}"
  STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
  HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo "missing")

  if [[ "$STATUS" == "running" ]]; then
    if [[ "$HEALTH" == "healthy" || "$HEALTH" == "none" ]]; then
      ok "$CONTAINER: running ($HEALTH)"
    else
      warn "$CONTAINER: running but health=$HEALTH"
    fi
  else
    fail "$CONTAINER: status=$STATUS"
  fi
done

# ── 2. Data drive is actually mounted ─────────────────────────────────────────
# This is the check that matters most: if the external drive silently dropped
# off the USB bus, DATA_PATH still exists as an empty directory on the SD card.
# The compose bind mounts use create_host_path: false so the containers will not
# restart into that state, but a drive that vanishes while they are running will
# not be noticed by anything else.
if mountpoint -q "$DATA_PATH" 2>/dev/null; then
  ok "$DATA_PATH is mounted"
elif [[ -d "$DATA_PATH" ]]; then
  fail "$DATA_PATH exists but is NOT a mount point — the external drive is missing"
else
  fail "$DATA_PATH does not exist"
fi

# ── 3. Disk space ─────────────────────────────────────────────────────────────
if [[ -d "$DATA_PATH" ]]; then
  USED_PCT=$(df -P "$DATA_PATH" | awk 'NR==2 {gsub(/%/,""); print $5}')
  AVAIL=$(df -Ph "$DATA_PATH" | awk 'NR==2 {print $4}')

  if [[ -z "$USED_PCT" ]]; then
    warn "Could not read disk usage for $DATA_PATH"
  elif [[ "$USED_PCT" -ge 90 ]]; then
    fail "Disk usage at ${USED_PCT}% on $DATA_PATH (${AVAIL} free)"
  elif [[ "$USED_PCT" -ge 75 ]]; then
    warn "Disk usage at ${USED_PCT}% on $DATA_PATH (${AVAIL} free)"
  else
    ok "Disk usage: ${USED_PCT}% (${AVAIL} free) on $DATA_PATH"
  fi
fi

ROOT_USED=$(df -P / | awk 'NR==2 {gsub(/%/,""); print $5}')
if [[ -n "$ROOT_USED" && "$ROOT_USED" -ge 85 ]]; then
  warn "Root filesystem at ${ROOT_USED}%"
else
  ok "Root filesystem: ${ROOT_USED:-?}%"
fi

# ── 4. Tailscale status ───────────────────────────────────────────────────────
TS_JSON=$(docker exec homedrive-tailscale tailscale status --json 2>/dev/null || echo "{}")

if command -v jq &>/dev/null; then
  TS_STATE=$(echo "$TS_JSON" | jq -r '.BackendState // "unknown"')
  TS_IP=$(echo "$TS_JSON" | jq -r '.Self.TailscaleIPs[0] // "no-ip"')
else
  # jq is used elsewhere in this project, but the health check should still work
  # on a box where it is missing rather than reporting a false failure.
  TS_STATE=$(echo "$TS_JSON" | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4)
  TS_IP="(jq not installed)"
  TS_STATE="${TS_STATE:-unknown}"
fi

if [[ "$TS_STATE" == "Running" ]]; then
  ok "Tailscale: $TS_STATE ($TS_IP)"
else
  fail "Tailscale: BackendState=$TS_STATE"
fi

# ── 5. CouchDB reachability ───────────────────────────────────────────────────
COUCH_URL="http://127.0.0.1:5984"

# /_up needs no credentials (require_valid_user_except_for_up = true).
if docker exec homedrive-couchdb curl -sf -o /dev/null "${COUCH_URL}/_up" 2>/dev/null; then
  ok "CouchDB: /_up responding"
else
  fail "CouchDB: /_up did not respond"
fi

# Separately verify the admin credentials still work — a wrong password in .env
# breaks backups silently while /_up keeps returning 200.
# The password goes in via a curl config file on stdin so it never appears in
# the host's process list.
couch_esc_user="${COUCHDB_USER//\\/\\\\}"; couch_esc_user="${couch_esc_user//\"/\\\"}"
couch_esc_pass="${COUCHDB_PASSWORD//\\/\\\\}"; couch_esc_pass="${couch_esc_pass//\"/\\\"}"
if printf 'user = "%s:%s"\n' "$couch_esc_user" "$couch_esc_pass" \
     | docker exec -i homedrive-couchdb curl -sS -f -K - -o /dev/null "${COUCH_URL}/_all_dbs" 2>/dev/null
then
  ok "CouchDB: admin credentials accepted"
else
  fail "CouchDB: admin credentials rejected (check COUCHDB_USER/COUCHDB_PASSWORD in .env)"
fi
unset couch_esc_user couch_esc_pass

# ── 6. FileBrowser reachability ───────────────────────────────────────────────
# The filebrowser image ships busybox wget, which has no --server-response /
# response-code output. Just test whether the fetch succeeds.
if docker exec homedrive-filebrowser wget -q -O /dev/null "http://127.0.0.1:8080/health" 2>/dev/null \
   || docker exec homedrive-filebrowser wget -q -O /dev/null "http://127.0.0.1:8080/" 2>/dev/null; then
  ok "FileBrowser: responding on :8080"
else
  fail "FileBrowser: not responding on :8080"
fi

# ── 7. Backup freshness ───────────────────────────────────────────────────────
# A backup job that quietly stopped working is the classic way to lose a vault.
if [[ -d "$BACKUP_DEST" ]]; then
  LATEST=$(ls -1t "$BACKUP_DEST"/homedrive_*.tar.gz 2>/dev/null | head -n1)
  if [[ -n "$LATEST" ]]; then
    AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$LATEST") ) / 3600 ))
    if [[ "$AGE_H" -gt 48 ]]; then
      fail "Newest backup is ${AGE_H}h old ($(basename "$LATEST")) — the nightly job is not running"
    elif [[ "$AGE_H" -gt 26 ]]; then
      warn "Newest backup is ${AGE_H}h old ($(basename "$LATEST"))"
    else
      ok "Newest backup: $(basename "$LATEST") (${AGE_H}h old)"
    fi
  else
    warn "No backups found in $BACKUP_DEST — is the cron job installed?"
  fi
else
  warn "Backup directory $BACKUP_DEST does not exist"
fi

# ── 8. Notify on issues ───────────────────────────────────────────────────────
# ${#ISSUES[@]} on an empty array is safe under `set -u` in bash 4.4+ (Pi OS ships 5.x);
# ${ISSUES[*]} below is only ever reached when the array is non-empty.
if [[ "${#ISSUES[@]}" -gt 0 ]]; then
  SUMMARY="Home Drive issues on ${TS_HOSTNAME:-homepi}: $(IFS='; '; echo "${ISSUES[*]}")"
  echo "$TIMESTAMP [SUMMARY] $SUMMARY"

  if [[ -n "${NTFY_URL:-}" ]]; then
    curl -sf \
      -H "Title: Home Drive Alert" \
      -H "Priority: high" \
      -H "Tags: warning" \
      -d "$SUMMARY" \
      "$NTFY_URL" \
      -o /dev/null || echo "$TIMESTAMP [WARN] ntfy notification failed"
  fi

  echo "======= Health check done (${#ISSUES[@]} issue(s)) ======="
  exit 1
fi

ok "All checks passed."
echo "======= Health check done ======="
