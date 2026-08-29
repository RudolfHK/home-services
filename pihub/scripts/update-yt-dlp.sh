#!/usr/bin/env bash
# Rebuilds the pitune-backend image so it picks up the latest yt-dlp release
# from PyPI. yt-dlp is deliberately unpinned in pitune/backend/requirements.txt,
# but Docker's build cache would otherwise reuse the old pip-install layer
# forever since that file itself never changes — `--no-cache` forces it to
# re-run and actually re-resolve the latest version.
#
# YouTube changes its player/signature logic often enough that yt-dlp needs
# updating regularly; run this whenever PiTune's YouTube search or playback
# starts failing. Nothing else in the stack is touched.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Rebuilding pitune-backend with the latest yt-dlp..."
docker compose build --pull --no-cache pitune-backend
docker compose up -d pitune-backend

echo
echo "Now running:"
docker compose exec pitune-backend yt-dlp --version
