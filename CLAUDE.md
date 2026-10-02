# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Self-hosted services for a single Raspberry Pi 5 (aarch64, Raspberry Pi OS, Docker + Compose v2). The code is edited on a Windows machine but only ever runs on the Pi: no Docker here, and there's no build or test harness for the Docker stacks. The root `README.md` is the end-to-end setup path; each project has its own README with the full reasoning.

- **`home-drive/`**: Nextcloud (nginx + php-fpm + Postgres + Redis + cron). Standalone compose project, container names prefixed `homedrive-`.
- **`pihub/`**: media platform behind one nginx: homepage dashboard (FastAPI + vanilla JS), PiTune (Navidrome + a yt-dlp FastAPI backend + a static frontend), and Jellyfin. Container names prefixed `pihub-`.
- **`tailscale/`**: not a stack. It's the shared ACL policy (`acl-policy.hujson`) and device-onboarding docs for both stacks' optional `tailscale` compose profiles.
- **`home-signal-scanner/`**: an unrelated Python RF monitor/emitter (RTL-SDR, HackRF, Ubertooth). Not Dockerized and not mentioned in the root README.

The two Docker stacks are deliberately independent. They share nothing at the compose level; the only coupling is on the host filesystem (see "PiHub ↔ Nextcloud" below).

## Commands

Validate a compose file after editing it (on the Pi, from the stack's directory):
```bash
docker compose --env-file .env config >/dev/null          # home-drive
docker compose --profile core --profile homepage --profile pitune --profile jellyfin --profile tailscale config >/dev/null   # pihub
```

PiHub, operated through its CLI (`pihub/pihub`, a bash script) at the product level:
```bash
./pihub status | start <core|homepage|pitune|jellyfin|tailscale|all> | stop <x> | restart <x> | logs <x|container> | update
docker compose build pitune-frontend && docker compose up -d pitune-frontend   # frontend/backend source is baked into images; edits need a rebuild
```

home-drive:
```bash
bash scripts/install.sh [--skip-pull] [--yes] [--no-autostart]   # idempotent; re-run after config changes; refuses to run as root
docker exec -u www-data homedrive-nextcloud-app php occ <cmd>
```

home-signal-scanner (Python 3.11+; `--mock` needs no hardware):
```bash
python test/test_sequence.py --mock          # all 5 phases
python test/test_single_tone.py --mock       # one phase; each test/test_*.py has its own __main__
```

Shell scripts use `shellcheck` directives; keep them shellcheck-clean.

## PiHub architecture

- **Products = Compose profiles.** Every service belongs to exactly one profile: `core` (nginx, autoheal, docker-proxy), `homepage`, `pitune` (navidrome, pitune-backend, pitune-frontend), `jellyfin`, `tailscale` (optional). The same product grouping shows up in three places that have to agree: `docker-compose.yml` profiles, `services_for()` in the `pihub` CLI, and `homepage/config/services.yml`.
- **No cross-product `depends_on`.** nginx waits on nothing, so a down product just 502s its path. Compose refuses to parse the file if a `depends_on` target's profile isn't active alongside the dependent service's, which is why `docker-proxy` lists both `core` and `homepage`, and why `tailscale` doesn't depend on nginx.
- **`pihub stop` uses `compose stop`, never `down`**, so `restart: unless-stopped` keeps stopped services stopped across reboots. `pihub update` recreates only what was already running. The CLI forces every profile active on each call so named services always resolve.
- **`autoheal`** kills any `autoheal=true` container that goes unhealthy, which is why healthchecks have to be correct. Jellyfin's check is a bare TCP connect because setting its Base URL to `/jellyfin` moves `/health`.
- **Routing**: central `nginx/nginx.conf` sends `/` to homepage:8080, `/pitune/` (prefix stripped) to pitune-frontend, and `/jellyfin/` to Jellyfin. pitune-frontend's own nginx proxies `/api/` to pitune-backend:8000 and `/rest/` to Navidrome's Subsonic API. **Frontend `fetch()` URLs in PiTune must be relative (`api/...`, `rest/...`), never absolute (`/api/...`)**. An absolute path skips the `/pitune/` prefix and lands on homepage, which 404s with JSON that looks like a Subsonic failure.
- **`services.yml` fields**: `containers`/`compose_service` take the real `container_name` (`pihub-jellyfin`), not the compose service key (`jellyfin`), or every docker-proxy call 404s. `health_url` is the other way round: it's the compose service key over Docker DNS (`http://navidrome:4533`), never `localhost`. `launch_url` is what the browser opens. The file is re-read on every `/api/services` request, so no restart is needed.
- **homepage backend** talks to Docker only through `docker-proxy` (tecnativa socket proxy, `DOCKER_HOST=tcp://docker-proxy:2375`, `EXEC=0`), and only for containers listed in `services.yml`, never names taken from a request. docker-py and psutil are synchronous, so every call goes through `asyncio.to_thread` and per-container checks run concurrently. Keep it that way.
- **`API_TOKEN` / `X-PiHub-Token`** guards every mutating or sensitive-read endpoint in both homepage and pitune-backend (`Depends(require_token)`). homepage's frontend prompts for it and stores it in `localStorage`. The backend must never serve the token. pitune-frontend gets it templated into `config.js` at container start (`docker-entrypoint.d/30-inject-api-token.sh`), which is intentional. `tailscale-preflight` refuses to start the tailscale profile when `API_TOKEN` is empty.
- **pitune-backend** streams yt-dlp stdout straight through (no temp files, no redirect to googlevideo URLs), validates video IDs against `^[A-Za-z0-9_-]{11}$` before they reach a CLI argv, and `/api/save` writes only into `music/YouTube/`. The `/api/discover/*` endpoints and the Discover tab are stubs; the intended design is in `pihub/README.md`.

## Storage and mount invariants (both stacks)

- Every bind mount uses `create_host_path: false`, so a missing drive fails loudly and nothing gets written to the boot drive. Keep this on any new mount.
- PiHub: `MEDIA_ROOT` is the physical drive. `MEDIA_LIBRARY_ROOT`, if set, redirects only `music/videos/shows/photos`. `movies/`, `downloads/`, and `backups/` always stay under `MEDIA_ROOT`; movies are deliberately kept out of Nextcloud. Media mounts are read-only everywhere except pitune-backend's `music/YouTube`.
- **PiHub ↔ Nextcloud**: `MEDIA_LIBRARY_ROOT` can point inside home-drive's `${DATA_PATH}/nextcloud/data/<user>/files/media`, which is mode 750 and owned by Nextcloud's uid. Read access comes from `MEDIA_GID` (`group_add`); pitune-backend runs as root to write there. Anything written into Nextcloud's data dir from outside needs `occ files:scan --all` afterwards.
- home-drive uses a fixed subnet (`homedrive_net`, `10.89.0.0/24`) because `config/nextcloud/zz-homedrive.config.php`'s `trusted_proxies` names it. `install.sh` stages that overlay only *after* Nextcloud's first install; pre-staging it breaks the install (see the home-drive README troubleshooting).
- Both stacks default to host port 80 (`NEXTCLOUD_PORT`, `PIHUB_PORT`). On a shared Pi, PiHub has to move (`setup.sh` checks for this).
- Tailscale `serve.json` files: containerboot only expands `${TS_CERT_DOMAIN}`. They proxy to the stack's own nginx by compose DNS name. Use `serve`, never `funnel`.

## home-signal-scanner constraint

Every emitter must call `emitter/legal_guard.check_legal_params()` before transmitting. Never catch or bypass `LegalViolationError`, and never raise the limits in `config/settings.py` (20 dBm EIRP, 10% duty cycle, ETSI EN 300 328 / German TKG).

## Conventions

- Comments and READMEs explain the *why* at length and point at each other by filename and section (e.g. "see `homepage/README.md`'s security model"). When behavior changes, update the matching README or comment in the same change, and match that level of comment density.
- Commit subjects are prefixed with the stack (`pihub: ...`, `home-drive: ...`), with a body explaining the root cause.
- `.env` is never committed; `.env.example` documents every variable. New variables go in `.env.example` with a comment, and in `pihub/scripts/setup.sh` if it needs a generated value.
- This checkout has `core.autocrlf=true`, so the working tree is CRLF while the index is LF. Shell scripts have to stay LF in git because they're executed inside containers and on the Pi.
