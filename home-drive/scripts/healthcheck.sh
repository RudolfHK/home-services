#!/usr/bin/env bash
# healthcheck.sh — Check container health, disk space, and Tailscale status.
#
# Add to crontab (run `crontab -e`):
#   0 * * * * /home/pi/homedrive-pi/scripts/healthcheck.sh >> /var/log/homedrive-health.log 2>&1
set -euo pipefail

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

# ── 2. Disk space on data drive ───────────────────────────────────────────────
DATA_PATH="${DATA_PATH:-/mnt/data}"
if mountpoint -q "$DATA_PATH" 2>/dev/null || [[ -d "$DATA_PATH" ]]; then
  # Get used percentage (strip the %)
  USED_PCT=$(df "$DATA_PATH" | awk 'NR==2 {gsub(/%/,""); print $5}')
  AVAIL=$(df -h "$DATA_PATH" | awk 'NR==2 {print $4}')

  if [[ "$USED_PCT" -ge 90 ]]; then
    fail "Disk usage at ${USED_PCT}% on $DATA_PATH (${AVAIL} free)"
  elif [[ "$USED_PCT" -ge 75 ]]; then
    warn "Disk usage at ${USED_PCT}% on $DATA_PATH (${AVAIL} free)"
  else
    ok "Disk usage: ${USED_PCT}% (${AVAIL} free) on $DATA_PATH"
  fi
else
  fail "$DATA_PATH is not mounted"
fi

# Root filesystem check
ROOT_USED=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
if [[ "$ROOT_USED" -ge 85 ]]; then
  warn "Root filesystem at ${ROOT_USED}%"
else
  ok "Root filesystem: ${ROOT_USED}%"
fi

# ── 3. Tailscale status ───────────────────────────────────────────────────────
TS_JSON=$(docker exec homedrive-tailscale tailscale status --json 2>/dev/null || echo "{}")
TS_STATE=$(echo "$TS_JSON" | jq -r '.BackendState // "unknown"')

if [[ "$TS_STATE" == "Running" ]]; then
  TS_IP=$(echo "$TS_JSON" | jq -r '.Self.TailscaleIPs[0] // "no-ip"')
  ok "Tailscale: $TS_STATE ($TS_IP)"
else
  fail "Tailscale: BackendState=$TS_STATE"
fi

# ── 4. CouchDB reachability ───────────────────────────────────────────────────
COUCH_URL="http://localhost:5984"
COUCH_AUTH="${COUCHDB_USER}:${COUCHDB_PASSWORD}"

COUCH_STATUS=$(docker exec homedrive-couchdb \
  curl -sf -o /dev/null -w "%{http_code}" -u "$COUCH_AUTH" "$COUCH_URL/" 2>/dev/null || echo "000")

if [[ "$COUCH_STATUS" == "200" ]]; then
  ok "CouchDB: HTTP $COUCH_STATUS"
else
  fail "CouchDB: HTTP $COUCH_STATUS (expected 200)"
fi

# ── 5. FileBrowser reachability ───────────────────────────────────────────────
FB_STATUS=$(docker exec homedrive-filebrowser \
  wget -qO- --server-response http://localhost:8080/health 2>&1 \
  | grep "HTTP/" | awk '{print $2}' || echo "000")

if [[ "$FB_STATUS" == "200" ]]; then
  ok "FileBrowser: HTTP $FB_STATUS"
else
  fail "FileBrowser: HTTP $FB_STATUS (expected 200)"
fi

# ── 6. Notify on issues ───────────────────────────────────────────────────────
if [[ "${#ISSUES[@]}" -gt 0 ]]; then
  SUMMARY="Home Drive issues on ${TS_HOSTNAME:-homepi}: $(IFS='; '; echo "${ISSUES[*]}")"
  echo "$TIMESTAMP [SUMMARY] $SUMMARY"

  # Send notification via ntfy if configured
  if [[ -n "${NTFY_URL:-}" ]]; then
    curl -sf \
      -H "Title: Home Drive Alert" \
      -H "Priority: high" \
      -H "Tags: warning" \
      -d "$SUMMARY" \
      "$NTFY_URL" \
      -o /dev/null || true
  fi
else
  ok "All checks passed."
fi

echo "======= Health check done ======="
