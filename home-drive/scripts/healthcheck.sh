#!/usr/bin/env bash
# healthcheck.sh — compatibility shim.
#
# The health check was split in two:
#
#   scripts/health-monitor.sh    unattended: runs from a timer, quiet unless
#                                something is wrong, alerts, records history
#   scripts/health-dashboard.sh  interactive: the full status screen, with
#                                storage breakdown, transfer rates, file
#                                activity and Pi health
#
# This file stays behind so an existing crontab entry keeps working. It forwards
# every argument to health-monitor.sh. New setups should install the timer:
#
#   bash scripts/install-monitoring.sh
#
# See docs/MONITORING.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "NOTE: healthcheck.sh is now health-monitor.sh (see docs/MONITORING.md)." >&2

# --verbose reproduces the old behaviour: one line per check, every run.
exec "$SCRIPT_DIR/health-monitor.sh" --verbose "$@"
