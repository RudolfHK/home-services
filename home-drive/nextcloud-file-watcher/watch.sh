#!/bin/sh
# Watches WATCH_RELATIVE_PATH (under Nextcloud's own data directory) for new
# files and runs a SCOPED `occ files:scan --path=...`, not `--all`, the
# moment one finishes writing. Exists because PiTune's own writer
# (pitune-backend, in PiHub's stack) saves straight to disk, bypassing
# Nextcloud's file API entirely, so Nextcloud's own index never learns about a
# new file until something calls occ, and --all rescans the whole library,
# not just the one new file. See ../README.md.
set -eu

if [ -z "${WATCH_RELATIVE_PATH:-}" ]; then
  echo "WATCH_RELATIVE_PATH is not set; nothing to watch. See ../README.md." >&2
  exec sleep infinity
fi

WATCH_DIR="/var/www/html/data/${WATCH_RELATIVE_PATH}"

# The folder is meant to be created through Nextcloud's own web UI or sync
# client first (see PiHub's README's "Mounting a Nextcloud folder as your
# media library"), not by this container; compose brings this up alongside
# nextcloud-app with no ordering guarantee that's already happened, so wait
# rather than exit and crash-loop.
while [ ! -d "$WATCH_DIR" ]; do
  echo "Waiting for $WATCH_DIR to exist (create it through Nextcloud first)..."
  sleep 10
done

echo "Watching $WATCH_DIR; new files there trigger: occ files:scan --path=\"$WATCH_RELATIVE_PATH\""

# close_write: a plain write-then-close. moved_to: an atomic rename into
# place (how yt-dlp/ffmpeg typically finalize a converted file). Either way
# means "a complete file just landed here", which is the only thing that
# should ever trigger a scan, never a partially-written .part/.ytdl temp
# file mid-download.
inotifywait -m -r -e close_write -e moved_to --format '%f' "$WATCH_DIR" | while read -r _; do
  echo "Change detected under $WATCH_RELATIVE_PATH, running a scoped rescan..."
  # gosu, not su: the same privilege-drop tool Nextcloud's own entrypoint
  # uses internally, avoiding su's occasional "no controlling terminal"
  # complaints in a plain container process. The `|| echo ...` below (not a
  # bare `|| true`) so one failed scan (e.g. a momentary DB hiccup) doesn't
  # take the whole watch loop down; set -eu would otherwise exit the script
  # entirely on the first failure, and a silent `|| true` would hide it.
  gosu www-data php occ files:scan --path="$WATCH_RELATIVE_PATH" || echo "Scan failed; will retry on the next change." >&2
done
