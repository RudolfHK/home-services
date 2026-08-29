# PiHub — Unified Self-Hosted Multimedia Platform for Raspberry Pi 5

A modular dashboard that brings PiTune (local music + YouTube audio) and
Jellyfin (video/TV) together behind one URL, while keeping every service
independent: stop or crash one, the others keep running.

**For personal use on a home network only.** No auth layer of its own — see
[Security model](#security-model).

## Architecture

```
              Phone / Laptop (same LAN)
                        │  http://<pi>/
                        ▼
              ┌─────────────────────────┐
              │   nginx (core, :80)      │  ← the only port for daily use
              └───┬──────┬───────┬───────┘
        /dashboard/  /pitune/    /jellyfin/
           │            │            │
           ▼            ▼            ▼
    ┌───────────┐ ┌───────────────┐ ┌──────────┐
    │ dashboard │ │ pitune-       │ │ jellyfin │
    │           │ │ frontend      │ │  :8096   │
    └─────┬─────┘ └──┬─────────┬──┘ └────┬─────┘
          │ /api/     │         │        │
          ▼           ▼         ▼        ▼
   ┌──────────────┐ ┌────────┐ ┌──────┐ /media/{videos,movies,shows}
   │management-api│ │navidrome│ │pitune-│  (read-only)
   │ (docker API) │ │ :4533  │ │backend│
   └──────────────┘ └───┬────┘ └───┬──┘
                         │          │
                /media/music   /media/downloads
                 (read-only)     (read-write)
```

`core` (nginx, dashboard, management-api, autoheal) is always on. `pitune`
(navidrome, pitune-backend, pitune-frontend) and `jellyfin` are independent
Compose profiles — either can be stopped, crash, or be entirely absent from
`.env`'s `COMPOSE_PROFILES` without affecting the other two groups.

## Why this design

- **Product-level control, everywhere.** The dashboard, the `pihub` CLI, and
  the management API all group containers into the same three units — core,
  pitune, jellyfin — never exposing raw container names to a user. "Start
  PiTune" always means the same three containers, consistently.
- **No cross-product `depends_on`.** nginx starts without waiting on
  anything; if Jellyfin is down, `/jellyfin/` 502s but the dashboard and
  PiTune are unaffected. pitune-frontend depending on navidrome/pitune-backend
  is PiTune's *own* internal wiring, not a PiHub-level dependency — see the
  file header in `docker-compose.yml`.
- **State survives a reboot via Docker's own restart policy, not a trick.**
  `restart: unless-stopped` already means "come back after a host reboot,
  but stay off if a human explicitly stopped you." `pihub stop <x>` uses
  `docker compose stop` (not `down`) specifically so that guarantee holds.
  See `pihub`'s comments for the one place this required care: `pihub
  update` must not resurrect something you'd deliberately stopped.
- **A healthcheck alone doesn't restart anything.** Docker only restarts a
  container when its *process* exits, not when a healthcheck merely reports
  unhealthy. The `autoheal` sidecar is what actually closes that gap — it
  kills a container the moment it's marked unhealthy, so the restart policy
  can then do its job.
- **A missing media drive fails loudly, not silently.** Every bind mount from
  `MEDIA_ROOT` uses `create_host_path: false`, so a disconnected drive means
  Navidrome/Jellyfin's containers simply don't start — and the dashboard
  shows them as "not found", not a crash loop.
- **`/api/save` writes to a disposable `downloads/` folder, never the curated
  music library.** See `pitune/backend/app/main.py`. Add `downloads/` as a
  second Navidrome library from its own admin UI once you trust what's
  landing there.

## Prerequisites

- Raspberry Pi 5 (4GB or 8GB), 64-bit Raspberry Pi OS, Docker Engine + the
  Compose v2 plugin
- An existing music and/or video library on a separate drive
- Internet access for YouTube search/streaming and image pulls

## Quick start

```bash
git clone https://github.com/<you>/home-services.git
cd home-services/pihub
bash scripts/setup.sh
```

`setup.sh` checks Docker is installed, asks for your media drive path,
creates the folder layout, writes `.env`, pulls every image, and starts
core + PiTune + Jellyfin. It prints the dashboard URL when done.

Two one-time manual steps it can't do for you (both need each service's own
admin UI, which PiHub doesn't reimplement):

1. Open `http://<pi>:4533/` and create your first Navidrome user — PiTune's
   own Library tab logs in with that account.
2. Open `http://<pi>:8096/`, run Jellyfin's setup wizard, add your
   videos/movies/shows libraries, then go to **Dashboard → Networking →
   Base URL**, set it to `/jellyfin`, and restart the `jellyfin` service
   (`./pihub restart jellyfin`). Without this, Jellyfin's own links and
   websocket calls are generated without the prefix and break under the
   `/jellyfin/` proxy path.

Prefer running `pihub` from anywhere? `sudo ln -s "$(pwd)/pihub" /usr/local/bin/pihub`.

## The `pihub` CLI

```bash
pihub status              # show every container's state, grouped by product
pihub start pitune        # start just PiTune (all 3 of its containers)
pihub stop jellyfin       # stop just Jellyfin
pihub start all           # start everything, regardless of .env
pihub restart jellyfin    # restart one product
pihub logs pitune         # tail logs for a product (or a raw container name)
pihub update              # pull latest images, recreate only what was running
```

## Configuration (`.env`)

| Variable | Default | What it controls |
|---|---|---|
| `COMPOSE_PROFILES` | `core,pitune,jellyfin` | Which products a bare `docker compose up -d` brings up. Narrowing this doesn't limit `pihub` — see `pihub`'s `compose()` wrapper. |
| `MEDIA_ROOT` | `/media/storage` | The external drive. `setup.sh` creates `music/ videos/ movies/ shows/ downloads/ photos/ backups/` under it. |
| `NAVIDROME_DATA_PATH` / `JELLYFIN_CONFIG_PATH` | `./navidrome/data` / `./jellyfin/config` | Per-service config, deliberately off `MEDIA_ROOT` — a missing media drive must never take a service's own config down with it. |
| `PIHUB_PORT` | `80` | The one port for daily use. |
| `NAVIDROME_PORT` / `JELLYFIN_PORT` | `4533` / `8096` | Published directly too — Navidrome for its one-time admin/account setup, Jellyfin for its setup wizard and for troubleshooting hardware transcoding without the proxy in the way. |
| `PUID` / `PGID` | `1000`/`1000` | uid/gid Navidrome runs as, so it can read `MEDIA_ROOT`. |
| `DOWNLOAD_ENABLED` | `false` | Enables PiTune's "save this YouTube track" button, writing MP3s into `MEDIA_ROOT/downloads/`. |
| `YTDLP_COOKIES_HOST_FILE` | unset | Path to a Netscape-format `cookies.txt`, for age-restricted/region-locked videos. |

## Storage layout

```
${MEDIA_ROOT}/
├── music/       → Navidrome (read-only)
├── videos/      → Jellyfin, general library (read-only)
├── movies/      → Jellyfin, movies library (read-only)
├── shows/       → Jellyfin, TV library (read-only)
├── downloads/   → PiTune's yt-dlp saves (read-write for pitune-backend only)
├── photos/      → reserved for a future Immich — nothing mounts it yet
└── backups/     → scripts/backup.sh's default destination
```

## Raspberry Pi considerations

- **Boot drive vs. media drive.** Run the OS/Docker/configs off the NVMe SSD;
  point `MEDIA_ROOT` at an external USB drive. Add it to `/etc/fstab` with
  the `nofail` option so the Pi still boots if that drive is ever
  disconnected — `setup.sh` deliberately refuses to proceed if `MEDIA_ROOT`
  doesn't already exist, rather than creating an empty directory on the boot
  drive by mistake.
- **Jellyfin hardware acceleration.** The `devices:` block in
  `docker-compose.yml` maps the V4L2 stateless-decode devices Raspberry Pi
  OS's kernel exposes (`/dev/video10-12`). Pi 5 can hardware-*decode* some
  codecs this way but cannot hardware-*encode* — direct play is still
  strictly preferred; hardware transcoding is a fallback for the codecs it
  can't play directly, enabled from Jellyfin's own admin UI (**Dashboard →
  Playback**, V4L2M2M). If those device paths don't exist on your board,
  comment the whole block out — Jellyfin runs fine on software decoding.
- **Idle RAM.** Core + PiTune + Jellyfin (idle, no active streams) should sit
  comfortably under the ~1.5GB target on an 4GB Pi 5; Jellyfin's own memory
  use grows mainly while actively transcoding.

## Security model

Same posture as this repo's other stacks that don't put a VPN in front of
themselves: this assumes it never leaves your home network. If you want
access away from home, put PiHub behind your own VPN (see `home-drive`'s
Tailscale setup for a working example) rather than exposing `PIHUB_PORT`
directly to the internet.

| Control | What it does |
|---|---|
| Docker socket mounted `read_only: true` into management-api | Stops the container from replacing/deleting the socket file — **not** a real permission boundary on what Docker API calls it can make (full socket access is root-equivalent). The real control is the next row. |
| management-api's hardcoded `SERVICES` allow-list | Every start/stop/restart/logs call is resolved against a fixed set of container names baked into the image; the API never accepts a raw container name from a caller. See the module docstring in `management-api/app/main.py`. |
| Media library mounts are `read_only: true` everywhere except PiTune's `downloads/` | Navidrome and Jellyfin can't be tricked into writing into your library; the one writer (`pitune-backend`) is scoped to a disposable folder, not the library itself. |
| `no-new-privileges` on every container | Standard defense-in-depth. |
| Video-ID validation in pitune-backend | YouTube video IDs are checked against `^[A-Za-z0-9_-]{11}$` before reaching a `yt-dlp` command line, so a crafted ID can't be parsed as a CLI flag. |
| Each product manages its own accounts | PiHub doesn't invent a login system — Navidrome and Jellyfin keep their own, and PiTune's UI just forwards Subsonic credentials to Navidrome. |
| `.env` never committed | See `.gitignore`. No real secrets live here by default (neither service needs a password from PiHub itself), but keep it out of git regardless. |

## Troubleshooting

**A product shows "not found" on the dashboard.** Its container was never
created — almost always because `MEDIA_ROOT` (or one of its subfolders) was
missing when you last ran `docker compose up`/`pihub start`. Every bind
mount uses `create_host_path: false` on purpose, so a disconnected drive
fails loudly instead of quietly writing to the boot drive. Reconnect the
drive and re-run `pihub start <product>`.

**Jellyfin's own links/player break under `/jellyfin/`.** Its Base URL
isn't set — see step 2 of Quick start.

**YouTube search/playback in PiTune fails with signature or 403 errors.**
Stale `yt-dlp` — run `scripts/update-yt-dlp.sh`.

**`pihub stop jellyfin` (or any command) errors about an unknown service.**
Make sure you're running the `pihub` script from this checkout (or via the
symlink described above) — it needs `docker-compose.yml` next to it.

## Future services

The registry pattern in `management-api/app/main.py`'s `SERVICES` list plus
one profile block in `docker-compose.yml` is the whole integration surface —
by design, adding Immich, Pi-hole, Uptime Kuma, Mealie or Home Assistant
later means touching exactly those two places, never the dashboard, the CLI,
or any existing product's config.

## File structure

```
pihub/
├── docker-compose.yml
├── .env.example
├── pihub                    # CLI (see above)
├── nginx/
│   └── nginx.conf           # central reverse proxy
├── dashboard/                # status + start/stop/restart + system stats
│   ├── Dockerfile
│   └── src/
├── management-api/           # Docker API wrapper behind the dashboard + CLI
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/main.py
├── pitune/
│   ├── backend/              # yt-dlp search/stream API
│   └── frontend/             # unified local+YouTube player UI
├── jellyfin/
│   └── config/               # persisted Jellyfin config (gitignored)
├── navidrome/
│   └── data/                 # persisted Navidrome database (gitignored)
└── scripts/
    ├── setup.sh
    ├── update-yt-dlp.sh
    └── backup.sh             # backs up configs, not media
```
