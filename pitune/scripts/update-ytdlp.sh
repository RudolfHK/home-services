#!/usr/bin/env bash
# Rebuilds the backend image so it picks up the latest yt-dlp release from
# PyPI. yt-dlp is deliberately unpinned in requirements.txt, but Docker's
# build cache would otherwise reuse the old pip-install layer forever since
# requirements.txt itself never changes — `--no-cache` forces that layer to
# re-run and actually re-resolve the latest version.
#
# YouTube changes its player/signature logic often enough that yt-dlp needs
# updating regularly; run this whenever search or playback starts failing.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Rebuilding the backend image with the latest yt-dlp..."
docker compose build --pull --no-cache backend
docker compose up -d backend

echo
echo "Now running:"
docker compose exec backend yt-dlp --version
