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
              └───┬──────────┬───────┬───┘
             /       /pitune/    /jellyfin/
              │            │            │
              ▼            ▼            ▼
       ┌───────────┐ ┌───────────────┐ ┌──────────┐
       │ homepage  │ │ pitune-       │ │ jellyfin │
       │ (UI + API │ │ frontend      │ │  :8096   │
       │  in one)  │ │               │ │          │
       └─────┬─────┘ └──┬─────────┬──┘ └────┬─────┘
             │ docker    │         │        │
             │ socket    ▼         ▼        ▼
             ▼    ┌────────┐ ┌──────┐ /media/{videos,movies,shows}
       every       │navidrome│ │pitune-│  (read-only)
       container's  │ :4533  │ │backend│
       status/logs  └───┬────┘ └───┬──┘
                         │          │
                /media/music   /media/downloads
                 (read-only)     (read-write)
```

`core` (nginx, autoheal) is always on. `homepage`, `pitune` (navidrome,
pitune-backend, pitune-frontend) and `jellyfin` are independent Compose
profiles — any one of them can be stopped, crash, or be entirely absent
from `.env`'s `COMPOSE_PROFILES` without affecting the others. See
`homepage/README.md` for the dashboard itself.

## Why this design

- **Product-level control, everywhere.** The homepage dashboard and the
  `pihub` CLI both group containers into the same units — core, homepage,
  pitune, jellyfin — never exposing raw container names to a user. "Start
  PiTune" always means the same three containers, consistently.
- **No cross-product `depends_on`.** nginx starts without waiting on
  anything; if Jellyfin is down, `/jellyfin/` 502s but the homepage
  dashboard and PiTune are unaffected. pitune-frontend depending on
  navidrome/pitune-backend is PiTune's *own* internal wiring, not a
  PiHub-level dependency — see the file header in `docker-compose.yml`.
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
  Navidrome/Jellyfin's containers simply don't start — and the homepage
  dashboard shows them as "not found", not a crash loop.
- **`/api/save` writes to a disposable `downloads/` folder, never the curated
  music library.** See `pitune/backend/app/main.py`. Add `downloads/` as a
  second Navidrome library from its own admin UI once you trust what's
  landing there.
- **Jellyfin's healthcheck can't be a `/health` path check.** Setting Base
  URL (required — see Quick start) moves ALL of Jellyfin's routes under that
  prefix, `/health` included. A check hardcoded to `/health` would pass
  before that one-time step and then fail forever right after it — with
  `autoheal` watching, that's a real restart loop on a perfectly healthy
  container. The healthcheck is a bare TCP connect instead, which doesn't
  care what path Jellyfin answers on.
- **The homepage dashboard never blocks on a slow Docker call.** `docker-py`
  is fully synchronous; calling it directly from an `async def` route would
  freeze the *entire* API — including someone else's start/stop click —
  for as long as that one call takes. Every docker-py and `psutil` call in
  `homepage/backend/` runs via `asyncio.to_thread`, and the per-container
  status checks in `/api/services` run concurrently rather than one
  container at a time. See `homepage/README.md` for the rest of its design.

## Prerequisites

- Raspberry Pi 5 (4GB or 8GB), 64-bit Raspberry Pi OS, Docker Engine + the
  Compose v2 plugin
- An existing music and/or video library on a separate drive
- Internet access for YouTube search/streaming and image pulls

## Prepare the Pi

Starting from a bare Pi 5. Skip whatever you've already done.

### 1. Flash Raspberry Pi OS

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) on another
computer:

1. Choose **Raspberry Pi 5** as the device and **Raspberry Pi OS Lite
   (64-bit)** as the OS — Lite is enough, this whole stack is headless.
2. Click the gear icon (⚙) / "Edit settings" **before** writing the image and
   set: hostname, an SSH username/password (or your public key), and your
   Wi-Fi details if you're not using Ethernet. This gets you a Pi you can SSH
   into on first boot with no monitor/keyboard attached.
3. Write the image, boot the Pi, then:
   ```bash
   ssh <user>@<hostname-or-ip>.local
   ```

### 2. Update and verify

```bash
sudo apt-get update && sudo apt-get full-upgrade -y
uname -m                # must print: aarch64  (confirms the 64-bit OS)
timedatectl              # "System clock synchronized: yes"
sudo reboot
```

### 3. Install Docker and the Compose plugin

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
newgrp docker            # apply the group without logging out

docker version           # daemon reachable without sudo
docker compose version   # must print v2.x — the plugin, not docker-compose
```

### 4. Attach and mount the media drive

Unlike PiTune alone, PiHub's storage layout (`music/ videos/ movies/ shows/
downloads/ photos/ backups/` all under one `MEDIA_ROOT`) is really meant for
a separate drive — Jellyfin libraries in particular get large fast.

```bash
lsblk -f                          # identify the device, e.g. /dev/sda1
sudo mkdir -p /media/storage
sudo mount /dev/sda1 /media/storage
```

Add it to `/etc/fstab` with the **`nofail`** option, so the Pi still boots
normally even if the drive is ever unplugged — every bind mount in
`docker-compose.yml` uses `create_host_path: false`, so a missing drive shows
up as a service the dashboard reports "not found" (see
[Troubleshooting](#troubleshooting)), not a Pi that won't boot:

```bash
blkid /dev/sda1        # copy the UUID
sudo nano /etc/fstab    # add: UUID=<uuid>  /media/storage  ext4  defaults,nofail  0  2
sudo mount -a           # verify the fstab line is valid
```

### 5. Check Jellyfin's hardware decode devices exist (optional)

```bash
ls -la /dev/video1[0-2]
```

If these don't exist, Jellyfin still works fine on software decoding — just
comment out the `devices:` block for the `jellyfin` service in
`docker-compose.yml` before starting the stack, or Compose will fail to
start that container over a missing device path.

## Quick start

> Assumes the Pi is already prepared — see [Prepare the Pi](#prepare-the-pi)
> above.

```bash
git clone https://github.com/<you>/home-services.git
cd home-services/pihub
bash scripts/setup.sh
```

`setup.sh` checks Docker is installed, asks for your media drive path,
creates the folder layout, writes `.env`, pulls every image, and starts
core + homepage + PiTune + Jellyfin. It prints the dashboard URL when done.

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
pihub start homepage      # start just the dashboard
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
| `COMPOSE_PROFILES` | `core,homepage,pitune,jellyfin` | Which products a bare `docker compose up -d` brings up. Narrowing this doesn't limit `pihub` — see `pihub`'s `compose()` wrapper. |
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
| Docker socket mounted `read_only: true` into homepage | Stops the container from replacing/deleting the socket file — **not** a real permission boundary on what Docker API calls it can make (full socket access is root-equivalent). The real control is the next row. |
| homepage's config-driven container allow-list | Every start/stop/restart/logs call is resolved against `homepage/config/services.yml`'s fixed container list; the API never accepts a raw container name from a caller. See `homepage/README.md`'s security model. |
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

**PiTune's Library tab shows "Could not reach Navidrome" with a Retry
button, instead of asking to log in again.** By design — your saved login
is kept, since nothing said the password was wrong, only that Navidrome
itself didn't answer (most often it's still starting, or mid-restart after
`pihub update`). Click **Retry**, or wait for `pihub status` to show
`pihub-navidrome` as running. The login form only reappears on an actual
wrong-password response.

**`pihub stop jellyfin` (or any command) errors about an unknown service.**
Make sure you're running the `pihub` script from this checkout (or via the
symlink described above) — it needs `docker-compose.yml` next to it.

## Future services

Adding a service (Immich, Pi-hole, Uptime Kuma, Mealie, Home Assistant, ...)
means two things: one entry in `homepage/config/services.yml` (no code
change — see `homepage/README.md`) and one profile block in this file's
`docker-compose.yml`. Nothing else — not the dashboard's code, not the CLI,
not any existing product's config — needs to change.

## File structure

```
pihub/
├── docker-compose.yml
├── .env.example
├── pihub                    # CLI (see above)
├── nginx/
│   └── nginx.conf           # central reverse proxy
├── homepage/                 # unified dashboard + health monitor
│   ├── Dockerfile
│   ├── config/services.yml   # ← add a service here
│   ├── backend/
│   └── frontend/
│   (see homepage/README.md for its own full documentation)
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
