# PiHub Homepage — Unified Dashboard & Health Monitor

The single page you open when you type the Pi's IP into a browser: every
PiHub service as a card (status, uptime, port, quick launch), system stats
(CPU/temp/RAM/disk/uptime), a health panel with alerts and failure history,
and start/stop/restart/logs controls — all driven by one YAML file, so
adding a future service never means touching code.

Replaces PiHub's earlier `dashboard/` + `management-api/` pair with one
config-driven service. If you're looking for `home-drive`'s own
`healthcheck.sh`/`health-dashboard.sh` — that's a separate, independent
project with its own monitoring (Tailscale, FileBrowser, CouchDB,
Nextcloud); this dashboard doesn't touch it, on purpose. See
[Why this design](#why-this-design).

## Architecture

```
  Browser ──▶ PiHub's nginx (:80) ──▶ homepage:8080
                                          │
                            ┌─────────────┼─────────────────┐
                            ▼             ▼                 ▼
                       config/*.yml   Docker socket    /host/proc, thermal,
                       (re-read       (container       /hostroot, /media
                       every request) status, start/    (system stats)
                                      stop/restart,
                                      logs, image
                                      update check)
                                          │
                                          ▼
                            HTTP health check against each
                            service's own health_url (e.g.
                            http://navidrome:4533/)
```

One container serves both the static frontend and the `/api/*` backend —
no separate nginx needed for this service, which is most of how it stays
under a 100MB idle footprint. PiHub's own central nginx proxies everything
under `/` to it; see `../nginx/nginx.conf`.

## Why this design

- **Config-driven, not code-driven.** `config/services.yml` is re-read on
  every `/api/services` request — add a service, save the file, refresh the
  page. No restart, no code change. See that file's own header comments for
  the schema.
- **Docker status and HTTP health are two different questions, checked
  separately.** A container can be `running` in Docker's eyes while its
  actual endpoint times out (deploying, deadlocked, out of memory) — this
  dashboard checks both and reports `unhealthy` when they disagree, which
  is strictly more information than watching container state alone (what
  PiHub's old management-api did).
- **A stopped service is not an error.** If Docker reports a container
  `exited` and nothing else is wrong, that shows as **Stopped** — Docker
  doesn't record *why* a container isn't running, so neither do we; there's
  no way to distinguish "you clicked Stop" from "it crashed and gave up
  retrying" from container state alone, and guessing wrong in either
  direction would be worse than a plain, honest "stopped".
- **Nothing here blocks the event loop.** Every docker-py and `psutil` call
  is fully synchronous under the hood; called directly from an `async def`
  route it would freeze this *entire* process — including someone else's
  start/stop click — for as long as that one call takes. Everything routes
  through `asyncio.to_thread`, and independent containers are queried/acted
  on concurrently, not one at a time.
- **Update checks are on-demand, never in the poll loop.** Checking yt-dlp's
  version hits PyPI; checking image freshness hits the container registry.
  Both are cached for an hour and only run when you click **Check for
  updates** — polling either one every 10-15 seconds would just get you
  rate-limited for no benefit.
- **`home-drive` is left alone, deliberately.** It's a separate product
  monitoring a separate stack (Tailscale, FileBrowser, CouchDB, Nextcloud)
  that may not even run on the same Pi as PiHub — folding its checks in
  here would mean this dashboard's backend needs to know about CouchDB and
  Nextcloud, which has nothing to do with PiTune or Jellyfin. If you *do*
  run both on one Pi, home-drive's own `health-dashboard.sh` is still the
  right tool for its own stack; this one doesn't replace it.

## Quick start (as part of PiHub)

This is how you'll normally run it — see `../README.md` for the full PiHub
setup. From the `pihub/` directory:

```bash
./pihub start homepage
```

Then open `http://<pi>/` — PiHub's nginx serves the dashboard at the root
path. `homepage` is its own Compose profile (not lumped into `core`), so
`pihub stop homepage` / `pihub start homepage` work independently of
everything else, exactly like `pitune` and `jellyfin`.

## Standalone use

`homepage/docker-compose.yml` runs this dashboard entirely on its own,
against any Docker host:

```bash
cd pihub/homepage
cp .env.example .env
nano .env   # MEDIA_ROOT, HOMEPAGE_PORT
nano config/services.yml   # point health_url entries at YOUR services
docker compose up -d --build
```

Both deployment modes build the exact same `./backend` and `./frontend`
code — there's one implementation either way, just two compose files for
two different ways of running it.

## Configuration

### `config/services.yml`

One entry per product. Read fresh on every poll — see the file's own header
comment for the full field reference. The short version:

```yaml
services:
  pitune:
    name: PiTune
    description: Local music library + YouTube audio streaming
    icon: music
    containers: [navidrome, pitune-backend, pitune-frontend]   # all 3 = one card
    health_url: http://navidrome:4533   # Docker-network address, NOT localhost
    health_endpoint: /
    launch_url: /pitune/                # what the "Open" button opens
```

`containers` is a list on purpose: PiTune is three containers that PiHub
treats as one product everywhere else (the CLI, the old management-api,
and now here) — `compose_service: jellyfin` is just shorthand for
`containers: [jellyfin]` when a product really is one container.

**`health_url` is not `launch_url`.** `health_url` is how *this backend*
reaches the service directly over the Docker compose network (a service
name — `localhost` inside this container means this container, not the Pi
and not any other service). `launch_url` is what the *browser* opens, which
is either a relative path through the reverse proxy (`/pitune/`) or an
absolute `http://<pi>:<port>/` for something published on its own port.
Conflating the two is a real, easy-to-make mistake — worth double-checking
if a new service's card never goes green despite the container clearly
running.

### `config/settings.yml`

UI preferences: title, default theme (a user's own toggle always wins after
their first visit — see `frontend/src/app.js`), poll intervals, and the
warning thresholds shown in the health panel (deliberately the same numbers
`home-drive`'s own monitoring uses, not a second copy that could drift).

## API reference

| Endpoint | What it does |
|---|---|
| `GET /api/services` | Every configured service's Docker + HTTP health status, combined |
| `POST /api/services/{id}/start\|stop\|restart` | Acts on all of that product's containers together |
| `POST /api/services/start-all` / `stop-all` | Bulk actions across every manageable service |
| `GET /api/services/{id}/logs?lines=200` | Last N lines from one container |
| `GET /api/system/stats` | CPU%, temp, RAM, disk (media + boot), Pi uptime |
| `GET /api/system/updates` | On-demand: yt-dlp version + Docker image freshness, cached 1h |
| `GET /api/config/settings` | Serves `settings.yml` to the frontend |

## Security model

| Control | What it does |
|---|---|
| No raw Docker socket in this container | `DOCKER_HOST` points at `docker-proxy` (a `tecnativa/docker-socket-proxy` sidecar that holds the actual mounted socket), which forwards only container/image/registry read+lifecycle endpoints — `EXEC=0`, `NETWORKS=0`, `VOLUMES=0`, and everything else this stack doesn't use is off. A bug or a compromised dependency in this process only gets what the proxy allows through, not the whole Docker API. See `docker-compose.yml`'s `docker-proxy` service and `backend/docker_monitor.py`'s module docstring. |
| `config/services.yml`'s fixed container list | On top of the proxy: every start/stop/restart/logs action resolves a container name from there, never from a request — even the endpoints the proxy does allow are never reachable with an arbitrary name. |
| `API_TOKEN` on every mutating endpoint | Without it, start/stop/restart/logs have no auth at all, and a plain unauthenticated POST is a "simple request" a browser will send cross-origin regardless of CORS — CORS only ever gates whether the response can be *read*, not whether the request is *sent*. A required custom header forces a preflight, which a non-wildcard `CORS_ORIGINS` then actually blocks for any other origin. `scripts/setup.sh` generates one; see `backend/main.py`'s `CORS_ORIGINS`/`API_TOKEN` comments for the full reasoning — including its honest limit: this stops a malicious *webpage*, not a compromised device with direct LAN access, which has no browser and thus no CORS to enforce in the first place. |
| `CORS_ORIGINS` empty by default, not `*` | The frontend and this API are always same-origin (one container, reached through nginx) — legitimate use never needs a cross-origin allowance, so there's no reason to widen this unless you have a specific, understood need to. |
| Security headers (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, a strict `Content-Security-Policy`) | Set both here (so the standalone deployment, with no nginx in front, is still protected) and at PiHub's central nginx (which hides this app's copies to avoid sending duplicates — see `../nginx/nginx.conf`). The CSP is safe to make this strict specifically because this frontend has no external images, no inline scripts/styles, and one same-origin API. |
| `/hostroot` mounted read-only | Exists only so `shutil.disk_usage()` can report boot-drive space, which never reads file contents — only filesystem-level stat. Still the broadest mount in this stack; comment it out (and the `BOOT_PATH` code path in `backend/system_stats.py`) if you'd rather not have it, at the cost of losing that one stat. |
| `no-new-privileges` | Standard defense-in-depth. |

## Troubleshooting

**A card never goes past "Error" even though the container is running.**
Check `health_url` isn't `localhost` — see the callout above. It has to be
a Docker Compose service name reachable from *this* container.

**Navidrome/Jellyfin show "Unhealthy" but work fine in the browser.**
The health check hits `health_url` + `health_endpoint` directly over the
Docker network, bypassing PiHub's nginx entirely — if that specific
in-container path needs auth or a header nginx normally adds, the check can
fail even while the real, browser-facing route works. Point
`health_endpoint` at something unauthenticated (Navidrome's `/`, Jellyfin's
`/health`) rather than a real API route.

**"Check for updates" says a yt-dlp version is unknown.** It calls
`http://pitune-backend:8000/api/version` — if you renamed that service in
`docker-compose.yml`, update the hardcoded URL in `backend/main.py`'s
`updates()` call site too.

**Start/stop/restart/logs return 401.** `API_TOKEN` is set but the request
didn't include a matching `X-PiHub-Token` header — normal if you're calling
the API directly (curl, a script); the frontend handles this itself by
fetching `/api/auth/token` once at load. If it's happening *in the browser*,
check the browser console for the `/api/auth/token` call failing.

**Stats show "not mounted" for the boot drive.** `/hostroot` isn't bind
-mounted — either it was deliberately commented out (see Security model
above) or you're running the standalone compose file without that line.

## File structure

```
homepage/
├── Dockerfile                 # one image: backend + frontend, no separate nginx
├── docker-compose.yml         # standalone use — see "Standalone use" above
├── .env.example
├── config/
│   ├── services.yml           # service registry — edit this to add a service
│   └── settings.yml           # UI prefs, poll rates, alert thresholds
├── backend/
│   ├── requirements.txt
│   ├── main.py                # FastAPI app, routes, config loading
│   ├── docker_monitor.py      # container status/start/stop/restart/logs/image-check
│   ├── health_checker.py      # HTTP checks + in-memory failure/response-time history
│   └── system_stats.py        # CPU/RAM/disk/temp/uptime + yt-dlp version check
└── frontend/
    └── src/
        ├── index.html
        ├── app.js              # polling loops, theme, wiring
        ├── components/
        │   ├── ServiceCard.js
        │   ├── SystemStats.js
        │   ├── HealthPanel.js
        │   └── LogViewer.js
        └── styles/main.css
```
