# PiHub: Unified Self-Hosted Multimedia Platform for Raspberry Pi 5

A modular dashboard that brings PiTune (local music + YouTube audio) and
Jellyfin (video/TV) together behind one URL, while keeping every service
independent: stop or crash one, the others keep running.

**For personal use on a home network only.** No auth layer of its own; see
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
                /media/music   /media/music/youtube
                 (read-only)     (read-write)
```

`core` (nginx, autoheal) is always on. `homepage`, `pitune` (navidrome,
pitune-backend, pitune-frontend) and `jellyfin` are independent Compose
profiles: any one of them can be stopped, crash, or be entirely absent
from `.env`'s `COMPOSE_PROFILES` without affecting the others. See
`homepage/README.md` for the dashboard itself.

## Why this design

- **Product-level control, everywhere.** The homepage dashboard and the
  `pihub` CLI both group containers into the same units (core, homepage,
  pitune, jellyfin), never exposing raw container names to a user. "Start
  PiTune" always means the same three containers, consistently.
- **No cross-product `depends_on`.** nginx starts without waiting on
  anything; if Jellyfin is down, `/jellyfin/` 502s but the homepage
  dashboard and PiTune are unaffected. pitune-frontend depending on
  navidrome/pitune-backend is PiTune's *own* internal wiring, not a
  PiHub-level dependency; see the file header in `docker-compose.yml`.
- **State survives a reboot via Docker's own restart policy, not a trick.**
  `restart: unless-stopped` already means "come back after a host reboot,
  but stay off if a human explicitly stopped you." `pihub stop <x>` uses
  `docker compose stop` (not `down`) specifically so that guarantee holds.
  See `pihub`'s comments for the one place this required care: `pihub
  update` must not resurrect something you'd deliberately stopped.
- **A healthcheck alone doesn't restart anything.** Docker only restarts a
  container when its *process* exits, not when a healthcheck merely reports
  unhealthy. The `autoheal` sidecar is what actually closes that gap: it
  kills a container the moment it's marked unhealthy, so the restart policy
  can then do its job.
- **A missing media drive fails loudly, not silently.** Every bind mount from
  `MEDIA_ROOT` uses `create_host_path: false`, so a disconnected drive means
  Navidrome/Jellyfin's containers simply don't start, and the homepage
  dashboard shows them as "not found," not a crash loop.
- **`/api/save` writes into `music/YouTube/`, inside the actual library, and
  runs automatically once a YouTube track finishes playing.** On by default
  (`DOWNLOAD_ENABLED=true`). Scoped to that one subfolder, never the rest of
  `music/`. See `pitune/backend/app/main.py`.
- **Jellyfin's healthcheck can't be a `/health` path check.** Setting Base
  URL (required; see Quick start) moves ALL of Jellyfin's routes under that
  prefix, `/health` included. A check hardcoded to `/health` would pass
  before that one-time step and then fail forever right after it. With
  `autoheal` watching, that's a real restart loop on a perfectly healthy
  container. The healthcheck is a bare TCP connect instead, which doesn't
  care what path Jellyfin answers on.
- **The homepage dashboard never blocks on a slow Docker call.** `docker-py`
  is fully synchronous; calling it directly from an `async def` route would
  freeze the *entire* API, including someone else's start/stop click, for
  as long as that one call takes. Every docker-py and `psutil` call in
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
   (64-bit)** as the OS. Lite is enough; this whole stack is headless.
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
a separate drive: Jellyfin libraries in particular get large fast.

```bash
lsblk -f                          # identify the device, e.g. /dev/sda1
sudo mkdir -p /media/storage
sudo mount /dev/sda1 /media/storage
```

Add it to `/etc/fstab` with the **`nofail`** option, so the Pi still boots
normally even if the drive is ever unplugged. Every bind mount in
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

If these don't exist, Jellyfin still works fine on software decoding. Just
comment out the `devices:` block for the `jellyfin` service in
`docker-compose.yml` before starting the stack, or Compose will fail to
start that container over a missing device path.

## Quick start

> Assumes the Pi is already prepared. See [Prepare the Pi](#prepare-the-pi)
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

1. Open `http://<pi>:4533/` and create your first Navidrome user. PiTune's
   own Library tab logs in with that account.
2. Open `http://<pi>:8096/`, run Jellyfin's setup wizard, add your
   videos/movies/shows libraries plus a **Photos**-type library pointed at
   `/media/photos` (Dashboard → Libraries → Add Media Library → Content
   type: Photos), then go to **Dashboard → Networking → Base URL**, set it
   to `/jellyfin`, and restart the `jellyfin` service
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
pihub start tailscale     # optional — see Remote access via Tailscale
```

## Configuration (`.env`)

| Variable | Default | What it controls |
|---|---|---|
| `COMPOSE_PROFILES` | `core,homepage,pitune,jellyfin` | Which products a bare `docker compose up -d` brings up. Narrowing this doesn't limit `pihub`; see `pihub`'s `compose()` wrapper. |
| `MEDIA_ROOT` | `/media/storage` | The external drive. `setup.sh` creates `music/ (with music/YouTube/) videos/ movies/ shows/ photos/ downloads/ backups/` under it. |
| `NAVIDROME_DATA_PATH` / `JELLYFIN_CONFIG_PATH` | `./navidrome/data` / `./jellyfin/config` | Per-service config, deliberately off `MEDIA_ROOT`, since a missing media drive must never take a service's own config down with it. |
| `PIHUB_PORT` | `80` | The one port for daily use. |
| `NAVIDROME_PORT` / `JELLYFIN_PORT` | `4533` / `8096` | Published directly too: Navidrome for its one-time admin/account setup, Jellyfin for its setup wizard and for troubleshooting hardware transcoding without the proxy in the way. |
| `PUID` / `PGID` | `1000`/`1000` | uid/gid Navidrome runs as, so it can read `MEDIA_ROOT`. |
| `MEDIA_LIBRARY_ROOT` | unset (falls back to `MEDIA_ROOT`) | Redirects only `music/videos/shows/photos` (never `movies/`, which routinely exceeds 50GB per file and always stays under `MEDIA_ROOT`) to a different parent directory, e.g. a folder inside home-drive's Nextcloud. See [Mounting a Nextcloud folder as your media library](#mounting-a-nextcloud-folder-as-your-media-library-optional) below. |
| `MEDIA_GID` | `0` (no-op) | Extra group Navidrome/Jellyfin are also given read access through. Only needed alongside `MEDIA_LIBRARY_ROOT` above, when it points at a directory owned by a different uid/gid than `PUID`/`PGID`. |
| `DOWNLOAD_ENABLED` | `true` | Once a YouTube track finishes playing, PiTune automatically saves it into `music/YouTube/`, inside the actual library. Set to `false` to turn this off. |
| `YTDLP_COOKIES_HOST_FILE` | unset | Path to a Netscape-format `cookies.txt`, for age-restricted/region-locked videos. |

## Storage layout

```
${MEDIA_ROOT}/
├── music/           → Navidrome (read-only)
│   └── YouTube/     → PiTune's auto-saved tracks (read-write for pitune-backend only)
├── videos/          → Jellyfin, general library (read-only)
├── movies/          → Jellyfin, movies library (read-only); always stays here, see below
├── shows/           → Jellyfin, TV library (read-only)
├── photos/          → Jellyfin, Photos library (read-only)
├── downloads/       → unused by default, free for your own manual use
└── backups/         → scripts/backup.sh's default destination
```

If `MEDIA_LIBRARY_ROOT` is set, `music/videos/shows/photos` move there;
`downloads/backups/movies` always stay under `MEDIA_ROOT` regardless. See
below for why `movies/` in particular is deliberately excluded.

## Mounting a Nextcloud folder as your media library (optional)

If this repo's `home-drive` stack is already running on the **same Pi**
(this only works as a same-machine bind mount, not over the network), you
can point PiHub's `music/videos/shows/photos` straight at a folder inside
its Nextcloud data directory, so adding, moving, or deleting files through
Nextcloud's own web UI, sync clients, or phone app is what actually manages
your library, instead of keeping a separate folder in sync by hand.
`movies/` is not part of this; see "Why `movies/` never moves" below.
This is also how a saved YouTube track (see `music/YouTube/` above) ends up
editable from any device running the Nextcloud client, not just from the Pi.

Nextcloud stores every user's files on the host at
`${DATA_PATH}/nextcloud/data/<nextcloud-username>/files/...`, where
`DATA_PATH` is set in **home-drive's own** `.env` (not PiHub's). So if
home-drive's `DATA_PATH=/mnt/data` and your Nextcloud username is `admin`,
a `media` folder created in the Nextcloud web UI lives on disk at
`/mnt/data/nextcloud/data/admin/files/media`, and PiHub expects `music/`,
`videos/`, `shows/`, and `photos/` subfolders (those exact lowercase
names) underneath it. Don't create a `movies/` subfolder here; it doesn't
belong inside Nextcloud at all (see below) and PiHub never looks for one
in this location.

**Why you can't just point `MEDIA_LIBRARY_ROOT` there and go.**
home-drive's own `scripts/install.sh` deliberately `chown`s the whole
`${DATA_PATH}/nextcloud/data` tree to Nextcloud's own internal user
(commonly uid/gid 33, detected per-image, not hardcoded) and sets it to
mode `750`, specifically so nothing outside the Nextcloud container can
read it by default. Navidrome runs as `PUID:PGID` (1000:1000 by default),
which is neither that user nor in its group, so a plain bind mount there
fails with a permission error.

**The fix**, without touching home-drive's own ownership or loosening its
permissions:

1. In Nextcloud's own web UI (or a sync client), create a `media` folder
   under your user, then `music`, `videos`, `shows`, and `photos`
   subfolders inside it (not `movies/`; see "Why `movies/` never moves"
   below), and put the matching files in each. Creating them through
   Nextcloud itself, rather than `mkdir` on the host, means Nextcloud's
   own index already knows about them from the start; see home-drive's
   [README.md](../home-drive/README.md#the-one-rule-nothing-else-writes-into-the-drive-without-telling-nextcloud)
   for what goes wrong if you add files from outside instead, and how to
   recover when something (PiTune's own auto-save included) has to.
2. Find the group that owns the Nextcloud data directory:
   ```bash
   stat -c '%g' /mnt/data/nextcloud/data     # replace with home-drive's actual DATA_PATH
   ```
3. In PiHub's `.env`, set `MEDIA_GID` to that number, and
   `MEDIA_LIBRARY_ROOT` to the `media` folder itself, not its subfolders
   (the compose file appends `music`/`videos`/`shows`/`photos` on its
   own; `movies` is never appended from this variable, see below):
   ```bash
   MEDIA_GID=33
   MEDIA_LIBRARY_ROOT=/mnt/data/nextcloud/data/admin/files/media
   ```
   `MEDIA_GID` adds that group as a *supplementary* group on the
   `navidrome` and `jellyfin` containers (`group_add` in
   `docker-compose.yml`), on top of their normal user. It doesn't change
   who owns anything on disk, and it only grants read access, matching
   the `750` permission's own group bits (`r-x`, no write): neither
   container can write into your Nextcloud files even if something else
   asked them to.
4. Also create `media/music/YouTube` the same way, through Nextcloud, if
   you want saved YouTube tracks to land inside Nextcloud too (optional;
   see the next paragraph for what changes if you do).
5. Recreate the affected containers so the new mounts and group take
   effect:
   ```bash
   pihub restart pitune
   pihub restart jellyfin
   ```

**Why `movies/` never moves.** Unlike `music/videos/shows/photos`,
`movies/` is not one of the folders `MEDIA_LIBRARY_ROOT` can redirect at
all; `docker-compose.yml`'s jellyfin service pins its `movies` mount to
`MEDIA_ROOT` directly, with no `MEDIA_LIBRARY_ROOT` fallback in that one
line. Individual movie files routinely exceed 50GB, and that's a real
problem specific to Nextcloud: its chunked-upload size ceiling, wasted
preview-generation attempts on huge video files, a `files:scan`/backup
pass that gets noticeably slower once files that size are in Nextcloud's
index, and sync clients/mobile apps that are impractical at that size in
the first place. `movies/` always stays under `MEDIA_ROOT` and is meant to
be managed directly on the drive, copy/move/delete by hand over a network
share, USB, or SFTP, never through Nextcloud's web UI or sync clients. If
you've decided that trade-off doesn't apply to you (a fast LAN, a Nextcloud
instance you don't mind being slower, files reliably under whatever your
own comfort threshold is), edit that one line in `docker-compose.yml`
yourself; this isn't enforced anywhere beyond that default.

**`downloads/` and `backups/` are never redirected by `MEDIA_LIBRARY_ROOT`,
and that's deliberate; `music/YouTube/` is different.** `pitune-backend`
(the writer behind `/api/save`) has no `user:` override and runs as root,
which ignores Unix permissions on anything its mounts can reach; that is
what makes a write into a `750`, Nextcloud-owned `music/YouTube/` work at
all. Unlike `downloads/`/`backups/`, which have no reason to ever exist
inside Nextcloud, `music/YouTube/` is meant to end up wherever the rest of
`music/` lives, Nextcloud-backed or not, since a saved track only earns its
place in your library the same way anything else does. The trade-off this
carries: if `MEDIA_LIBRARY_ROOT` points into Nextcloud, its own database
does **not** learn about a newly-saved file automatically, exactly the
"nothing else writes into the drive" case home-drive's README describes.
Run `docker exec -u www-data homedrive-nextcloud-app php occ files:scan --all`
after the fact (or put it on the same schedule as PiTune's auto-saves,
however often that ends up being for you), or set `DOWNLOAD_ENABLED=false`
if you'd rather this never happens automatically.

New files added through Nextcloud show up in PiTune/Jellyfin once their
own scans pick them up: Navidrome within `ND_SCANSCHEDULE` (every hour by
default) or a manual rescan from its admin UI; Jellyfin on its own library
scan schedule (**Dashboard → Libraries → Scan All Libraries** to force
one). Nothing Nextcloud-side needs to know either is reading from here,
since both only ever read.

## Discover (not yet implemented)

PiTune's **Discover** tab is scaffolding for a Spotify-style "browse your
library by sound" feature: find tracks that sound like this one, or like
"upbeat" or "late night," instead of only ever browsing by artist or album.
The UI tab and empty backend endpoints exist (`pihub/pitune/frontend/src/app.js`'s
Discover section, `pihub/pitune/backend/app/main.py`'s `/api/discover/*`
routes); nothing behind them runs any analysis yet.

The design, for whoever implements it next, is two passes:

1. **Raw audio analysis.** Run each library track through a model that
   estimates its acoustic properties directly from the waveform, the way
   Spotify's own audio features API works: tempo (BPM), musical key, and a
   mood/valence-arousal estimate. Output is one small feature vector per
   track. This has to be cached somewhere durable (a small local database,
   not recomputed per request) since it's the expensive part.
2. **Annoy** (Approximate Nearest Neighbor, the library Spotify itself
   published for exactly this) built as an index over those feature
   vectors, so "tracks similar to this one" becomes a nearest-neighbor
   lookup in that vector space, and browsing by mood/energy becomes
   clustering in the same space, instead of either needing a raw metadata
   match (same genre tag) that misses most real similarity.

**Why this stays manual, not automatic.** Both passes are real CPU work,
the first pass especially: analyzing an entire library is closer to
transcoding every track once than to a metadata scan. Running it
automatically on every Navidrome library scan (every hour, by default)
would make PiTune noticeably slower on a Pi for no benefit most of the
time. That's why `POST /api/discover/analyze` exists as an explicit,
separate action (the "Analyze library" button in the Discover tab, wired
but disabled until this is implemented) rather than a side effect of
anything else in this stack.

## Raspberry Pi considerations

- **Boot drive vs. media drive.** Run the OS/Docker/configs off the NVMe SSD;
  point `MEDIA_ROOT` at an external USB drive. Add it to `/etc/fstab` with
  the `nofail` option so the Pi still boots if that drive is ever
  disconnected. `setup.sh` deliberately refuses to proceed if `MEDIA_ROOT`
  doesn't already exist, rather than creating an empty directory on the boot
  drive by mistake.
- **Jellyfin hardware acceleration.** The `devices:` block in
  `docker-compose.yml` maps the V4L2 stateless-decode devices Raspberry Pi
  OS's kernel exposes (`/dev/video10-12`). Pi 5 can hardware-*decode* some
  codecs this way but cannot hardware-*encode*, so direct play is still
  strictly preferred; hardware transcoding is a fallback for the codecs it
  can't play directly, enabled from Jellyfin's own admin UI (**Dashboard →
  Playback**, V4L2M2M). Those paths are not present on every board — Pi 5
  included, depending on kernel and overlays — and Docker aborts the entire
  `up` over a device it can't find, so `scripts/setup.sh` probes for them and
  writes `JELLYFIN_V4L2_DEV10/11/12` into `.env` accordingly. Nothing to do
  by hand: absent devices mean software decoding, which is fine. If your
  board exposes a decoder under different numbers (`ls -l /dev/video*`), set
  those variables yourself as `host:container` pairs.
- **Idle RAM.** Core + PiTune + Jellyfin (idle, no active streams) should sit
  comfortably under the ~1.5GB target on an 4GB Pi 5; Jellyfin's own memory
  use grows mainly while actively transcoding.

## Security model

Same posture as this repo's other stacks by default: this assumes it never
leaves your home network unless you turn on the optional Tailscale profile.
See [Remote access via Tailscale](#remote-access-via-tailscale-optional)
below, rather than exposing `PIHUB_PORT` directly to the internet.

| Control | What it does |
|---|---|
| No raw Docker socket in homepage | It talks to `docker-proxy` (a `tecnativa/docker-socket-proxy` sidecar) instead, which forwards only the specific endpoints homepage needs. `EXEC=0` and everything else this stack doesn't use is off. A bug or a compromised dependency in homepage's own code only gets what the proxy allows through, never the whole Docker API. See `homepage/README.md`'s security model and `docker-compose.yml`'s `docker-proxy` service. |
| homepage's config-driven container allow-list | On top of the proxy: every start/stop/restart/logs call is resolved against `homepage/config/services.yml`'s fixed container list; the API never accepts a raw container name from a caller. |
| `API_TOKEN` on every mutating or sensitive-read endpoint (homepage's start/stop/restart/logs, PiMonitor's file-activity/user-activity, PiTune's `/api/save`, once implemented PiTune's `/api/discover/analyze`) | Without it, those endpoints have no auth at all, and a plain unauthenticated POST is a "simple request" a browser sends cross-origin regardless of CORS. CORS only gates whether the *response* can be read, not whether the request is *sent* (which is why PiMonitor's own reads are gated the same way as an actual mutation, even though nothing about them changes state). `scripts/setup.sh` generates one automatically. PiTune's frontend is handed this value at container start (templated into `config.js`, see `pitune/frontend/docker-entrypoint.d/`) so its own automatic save-on-finish call can set the header; that's a deliberate, safe exception, not a leak, since the header's real job is defeating a *third-party* site's blind cross-origin POST, which can't read PiTune's own page regardless. See `homepage/backend/main.py`'s comments for the full reasoning, including its honest limit: this stops a malicious *webpage*, not a compromised device with direct LAN access. |
| `CORS_ORIGINS` empty by default, not `*` | Every frontend here is always same-origin with its own API (reached through nginx), so legitimate use never needs a cross-origin allowance. |
| Security headers (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, a `Content-Security-Policy` for homepage and PiTune) | Set at PiHub's central nginx and, for homepage, also in its own FastAPI app (so its standalone deployment mode is covered too; nginx hides the duplicate). Not applied to Jellyfin's own responses: its player needs `blob:`/worker allowances for transcoding that aren't safe to guess at from outside its own app. |
| Media library mounts are `read_only: true` everywhere except PiTune's `music/YouTube/` | Navidrome and Jellyfin can't be tricked into writing into your library; the one writer (`pitune-backend`) is scoped to that one subfolder, never the rest of `music/` or any other media type. |
| `no-new-privileges` on every container | Standard defense-in-depth. |
| Video-ID validation in pitune-backend | YouTube video IDs are checked against `^[A-Za-z0-9_-]{11}$` before reaching a `yt-dlp` command line, so a crafted ID can't be parsed as a CLI flag. |
| Each product manages its own accounts | PiHub doesn't invent a login system: Navidrome and Jellyfin keep their own, and PiTune's UI just forwards Subsonic credentials to Navidrome. |
| `.env` never committed | See `.gitignore`. Holds `API_TOKEN` and, if you enable it, `TS_AUTHKEY`, in addition to paths/ports; keep it out of git regardless, as always. |
| Tailscale ACL allow-list (`../tailscale/acl-policy.hujson`), off by default | Only used if you opt into the `tailscale` profile; see [Remote access via Tailscale](#remote-access-via-tailscale-optional). Grants only `tag:approved-device` sources access to `tag:pihub-server:443`, a tag scoped to this stack alone, not the whole node and not shared with home-drive/PiTune. |
| `tailscale-preflight` container, only in the `tailscale` profile | Refuses to let `tailscale` start at all if `API_TOKEN` is unset; see [Remote access via Tailscale](#remote-access-via-tailscale-optional). A hard gate, not just a warning, specifically because this profile is what turns "unauthenticated homepage control-plane" from a LAN-only convenience into a remote exposure. |

**`NAVIDROME_PORT`/`JELLYFIN_PORT` have no proxy in front of them.** Unlike
the nginx-fronted routes, these direct ports are the services' own bare HTTP
servers, reachable by anything on your LAN with nothing extra between
them: no rate limiting, no security headers. Consider restricting them to
your own subnet with `ufw`:

```bash
ip -br -4 addr show eth0        # find YOUR LAN subnet, e.g. 192.168.1.0/24
sudo ufw allow from 192.168.1.0/24 to any port 4533 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 8096 proto tcp
sudo ufw deny 4533/tcp
sudo ufw deny 8096/tcp           # only reachable from that subnet now
```

## Remote access via Tailscale (optional)

By default PiHub really does stop at your LAN, as the Security model above
says. If you also want to reach it from outside the house, without opening
any port on your router, an optional `tailscale` profile is included:

```bash
cp .env.example .env   # if you haven't already
nano .env               # set API_TOKEN and TS_AUTHKEY (see below); leave TS_HOSTNAME/TS_EXTRA_ARGS as-is
pihub start tailscale    # or: docker compose --profile tailscale up -d tailscale
```

This starts one extra container that joins your tailnet and, over that
private WireGuard network only, serves PiHub's existing central nginx
(homepage, `/pitune/`, `/jellyfin/`, everything already behind `PIHUB_PORT`)
at `https://<TS_HOSTNAME>.<your-tailnet>.ts.net/`. `PIHUB_PORT` keeps working
on the LAN exactly as before; this is an additional way in, not a
replacement.

**`API_TOKEN` is a hard prerequisite, not just a recommendation, for this
profile.** A `tailscale-preflight` container runs before `tailscale` starts
and refuses to let it come up at all if `API_TOKEN` is unset, because once
homepage's start/stop/restart/logs endpoints are reachable from outside the
LAN, "no auth configured yet" stops being a quick-local-test convenience and
becomes an open remote control-plane. `docker compose --profile tailscale
up -d` fails loudly with an explanation in that case rather than starting
anyway.

**Before you enable this, more has to happen on Tailscale's side first, not
just in this repo:**

1. Apply [`../tailscale/acl-policy.hujson`](../tailscale/acl-policy.hujson)
   to your tailnet's ACL (Tailscale admin console → Access Controls). Skip
   this and joining the tailnet exposes *every* open port on the Pi,
   including `NAVIDROME_PORT` and `JELLYFIN_PORT`, to any device on your
   tailnet, not just the one path above. See
   [`../tailscale/docs/DEVICE-ONBOARDING.md`](../tailscale/docs/DEVICE-ONBOARDING.md)'s
   "One-time tailnet setup" step 2 for the full click-by-click walkthrough
   of that page, including what to do if this tailnet already has other
   ACL rules you don't want to lose.
2. Get a `TS_AUTHKEY` (prefer non-reusable, short expiry; see the comment
   in `.env.example` for why that's enough) and, ideally, turn on device
   approval so a new device can't reach anything until you've approved it.
   The full reasoning for why "must be set up on the LAN first" isn't
   something Tailscale checks literally, and what actually delivers that
   property instead, is written up in
   [`../tailscale/docs/DEVICE-ONBOARDING.md`](../tailscale/docs/DEVICE-ONBOARDING.md).
3. In the browser, the first mutating action you take (start/stop/restart,
   viewing logs) will prompt you once for the API token: paste the same
   value you put in `API_TOKEN` above. It's then remembered in that
   browser's own `localStorage`, never fetched from the server automatically;
   see `homepage/README.md`'s security model for why.

See [`../tailscale/README.md`](../tailscale/README.md) for the full
picture, including why the ACL grants only `tag:pihub-server:443` (a
separate tag per stack, not one shared tag for everything, so a device can
be scoped to just this stack if you want) rather than opening the whole
node, and why a static device allow-list, not a live concurrent-connection
counter, is the actual "only these devices, only this many" control here.
`nginx/nginx.conf`'s `limit_conn` (20 per source IP) is a narrower,
complementary safety net on top of that, and, worth knowing, only a true
per-device cap for direct LAN clients; over Tailscale it becomes an
aggregate cap across all tailnet traffic, since `tailscale serve` itself
hides the original client's IP at that layer (see the comment above
`limit_conn_zone` in that file).

## Troubleshooting

**A product shows "not found" on the dashboard.** Its container was never
created, almost always because `MEDIA_ROOT` (or one of its subfolders) was
missing when you last ran `docker compose up`/`pihub start`. Every bind
mount uses `create_host_path: false` on purpose, so a disconnected drive
fails loudly instead of quietly writing to the boot drive. Reconnect the
drive and re-run `pihub start <product>`.

**Jellyfin's own links/player break under `/jellyfin/`.** Its Base URL
isn't set; see step 2 of Quick start.

**YouTube search/playback in PiTune fails with signature or 403 errors.**
Stale `yt-dlp`; run `scripts/update-yt-dlp.sh`.

**PiTune's Library tab shows "Could not reach Navidrome" with a Retry
button, instead of asking to log in again.** By design: your saved login
is kept, since nothing said the password was wrong, only that Navidrome
itself didn't answer (most often it's still starting, or mid-restart after
`pihub update`). Click **Retry**, or wait for `pihub status` to show
`pihub-navidrome` as running. The login form only reappears on an actual
wrong-password response.

**`pihub stop jellyfin` (or any command) errors about an unknown service.**
Make sure you're running the `pihub` script from this checkout (or via the
symlink described above); it needs `docker-compose.yml` next to it.

## Future services

Adding a service (Immich, Pi-hole, Uptime Kuma, Mealie, Home Assistant, ...)
means two things: one entry in `homepage/config/services.yml` (no code
change; see `homepage/README.md`) and one profile block in this file's
`docker-compose.yml`. Nothing else, not the dashboard's code, not the CLI,
not any existing product's config, needs to change.

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
├── tailscale/
│   └── serve.json             # optional profile — see Remote access via Tailscale
└── scripts/
    ├── setup.sh
    ├── update-yt-dlp.sh
    └── backup.sh             # backs up configs, not media
```

See also [`../tailscale/`](../tailscale/) at the repo root: the shared ACL
policy and device-onboarding docs used by every stack's Tailscale profile,
not just this one.
