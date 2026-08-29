#!/usr/bin/env bash
# obsidian-check.sh — Is Obsidian LiveSync actually reaching CouchDB?
#
# Answers the one question that separates "sync is configured" from "sync is
# working": has anything arrived on the server, and when?
#
# Usage:
#   bash scripts/obsidian-check.sh            # uses COUCHDB_OBSIDIAN_DB from .env
#   bash scripts/obsidian-check.sh myvault    # or name the database explicitly
#
# Typical workflow when a device seems not to sync:
#   1. run this, note the document count
#   2. edit a note on the suspect device and save
#   3. run it again — if the count did not move, that device is not sending.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found."; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

DB="${1:-${COUCHDB_OBSIDIAN_DB:-obsidian}}"
COUCH_URL="http://127.0.0.1:5984"
COUCH_CONTAINER="homedrive-couchdb"

command -v jq &>/dev/null || { echo "ERROR: jq is required (sudo apt-get install -y jq)."; exit 1; }

docker inspect -f '{{.State.Running}}' "$COUCH_CONTAINER" 2>/dev/null | grep -q true \
  || { fail "$COUCH_CONTAINER is not running. Start the stack: docker compose up -d"; exit 1; }

# Credentials go to curl through a config file on stdin, never as `-u` on the
# command line, so the admin password stays out of the host's process list.
couch_curl() {
  local esc_user esc_pass
  esc_user="${COUCHDB_USER//\\/\\\\}"; esc_user="${esc_user//\"/\\\"}"
  esc_pass="${COUCHDB_PASSWORD//\\/\\\\}"; esc_pass="${esc_pass//\"/\\\"}"
  printf 'user = "%s:%s"\n' "$esc_user" "$esc_pass" \
    | docker exec -i "$COUCH_CONTAINER" curl -sS -f -K - "$@"
}

echo "======================================================"
echo "  Obsidian LiveSync — server-side check"
echo "  $(date '+%F %T')"
echo "======================================================"
echo ""

# ── 1. Which databases exist? ────────────────────────────────────────────────
# More than one vault-looking database usually means two devices were pointed at
# different names and are each syncing happily to their own island.
echo "Databases on the server:"
ALL_DBS="$(couch_curl "${COUCH_URL}/_all_dbs" 2>/dev/null)" || {
  fail "Could not list databases — check COUCHDB_USER / COUCHDB_PASSWORD in .env"
  exit 1
}
echo "$ALL_DBS" | jq -r '.[] | "  - " + .'
echo ""

USER_DBS="$(echo "$ALL_DBS" | jq -r '[.[] | select(startswith("_") | not)] | length')"
if [[ "$USER_DBS" -gt 1 ]]; then
  warn "More than one non-system database exists."
  warn "If two devices are pointed at different names they will never see each other."
  warn "See docs/OBSIDIAN.md troubleshooting T7."
  echo ""
fi

if ! echo "$ALL_DBS" | jq -e --arg db "$DB" 'index($db)' >/dev/null; then
  fail "Database '$DB' does not exist."
  echo ""
  echo "  Create it in Fauxton: https://<hostname>.<tailnet>.ts.net:8443/_utils/"
  echo "  It must match COUCHDB_OBSIDIAN_DB in .env and the plugin's 'Database name'."
  exit 1
fi

# ── 2. How much is in it? ────────────────────────────────────────────────────
INFO="$(couch_curl "${COUCH_URL}/${DB}" 2>/dev/null)" || { fail "Could not read '$DB'."; exit 1; }

DOC_COUNT="$(echo "$INFO" | jq -r '.doc_count')"
DEL_COUNT="$(echo "$INFO" | jq -r '.doc_del_count')"
SIZE="$(echo "$INFO" | jq -r '.sizes.file // 0')"
SEQ="$(echo "$INFO" | jq -r '.update_seq' | cut -d- -f1)"

echo "Database '$DB':"
echo "  documents      : $DOC_COUNT"
echo "  deleted        : $DEL_COUNT"
echo "  on-disk size   : $(numfmt --to=iec --suffix=B "$SIZE" 2>/dev/null || echo "${SIZE} bytes")"
echo "  update sequence: $SEQ"
echo ""

if [[ "$DOC_COUNT" -eq 0 ]]; then
  fail "The database is EMPTY — no device has ever pushed to it."
  echo ""
  echo "  On the seed device, run the action that sends the local vault to the server"
  echo "  ('Rebuild everything' / 'Overwrite remote'). See docs/OBSIDIAN.md step 1.7."
  echo "  Do not set up a second device until this count is non-zero."
  exit 1
fi

# LiveSync splits notes into chunks, so the document count is far higher than the
# note count. A few dozen documents for a real vault means the push was partial.
if [[ "$DOC_COUNT" -lt 50 ]]; then
  warn "Only $DOC_COUNT documents. LiveSync chunks notes, so a real vault produces"
  warn "hundreds to thousands. This may be a partial or interrupted upload."
else
  ok "$DOC_COUNT documents present."
fi
echo ""

# ── 3. What changed most recently? ───────────────────────────────────────────
# The useful signal: edit a note, re-run, and see it appear here.
echo "5 most recent changes:"
CHANGES="$(couch_curl "${COUCH_URL}/${DB}/_changes?descending=true&limit=5&include_docs=true" 2>/dev/null)" || true

if [[ -z "$CHANGES" ]]; then
  warn "  (could not read the changes feed)"
else
  echo "$CHANGES" | jq -r '
    .results[]
    | (.doc.mtime // .doc.ctime // empty) as $t
    | "  - " + (.id | if length > 60 then .[0:57] + "..." else . end)
      + (if $t then "   (" + (($t / 1000) | strftime("%Y-%m-%d %H:%M:%S")) + ")" else "" end)
  ' 2>/dev/null || echo "  (documents are encrypted or path-obfuscated — ids not readable)"
fi
echo ""

echo "======================================================"
echo "  To test a specific device:"
echo "    1. note the document count above"
echo "    2. edit and save a note on that device"
echo "    3. re-run this script"
echo "  Count unchanged => that device is not sending."
echo "  Count changed but the other device sees nothing"
echo "    => the problem is on the receiving device."
echo "  See docs/OBSIDIAN.md troubleshooting T2."
echo "======================================================"
