#!/bin/sh
# Templates config.js.template into config.js before nginx starts, so the
# page can read window.PIHUB_API_TOKEN without this container's own image
# baking in a fixed value. Runs automatically: the base nginx image executes
# every *.sh file under /docker-entrypoint.d/ on startup.
set -eu

envsubst '${API_TOKEN}' \
  < /usr/share/nginx/html/config.js.template \
  > /usr/share/nginx/html/config.js
