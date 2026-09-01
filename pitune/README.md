# PiTune: Self-Hosted Music Server with YouTube Streaming

A dockerized music server for Raspberry Pi that combines your local library
with ad-free, audio-only YouTube playback in one unified web player, reachable
from any device on your home network.

**For personal use on a home network only.** There is no authentication layer
in front of PiTune itself; see [Security model](#security-model).

## Architecture

```
  Phone / Laptop (same LAN)
         │  http://<pi>:8096/
         ▼
  ┌─────────────────────────── frontend (nginx) ───────────────────────────┐
  │  Serves the SPA.  Reverse-proxies:                                     │
  │    /api/*  → backend:8000   (YouTube search + audio streaming)         │
  │    /rest/* → navidrome:4533 (Subsonic API — local library)             │
  └───────────┬─────────────────────────────────────┬──────────────────────┘
              ▼                                     ▼
  ┌───────────────────────┐             ┌─────────────────────────────────┐
  │ backend (FastAPI)     │             │ navidrome                        │
  │  yt-dlp search        │             │  Subsonic API over MUSIC_PATH    │
  │  pipes audio-only     │             │  own admin UI on :4533           │
  │  stream, no re-encode │             └─────────────────────────────────┘
  └───────────────────────┘
```

Only the frontend's port needs to be reached day to day; everything else
talks over the internal compose network. Navidrome's own port is also
published so you can reach its admin UI directly to create library users.

## Why this design

- **One origin for the browser.** nginx proxies both `/api/` and `/rest/` so
  the SPA never makes a cross-origin request. That sidesteps CORS entirely
  and means the whole app is one URL, which is the thing that actually
  matters for "open it on my phone on the same Wi-Fi".
- **No re-encoding, no temp files.** `/api/stream/<id>` pipes `yt-dlp`'s own
  stdout straight into the HTTP response in whatever container YouTube served
  (webm/opus or m4a/aac). No video stream is ever requested, and nothing
  touches disk, so it's light on a Pi's CPU and SD card alike.
- **No redirect to the raw YouTube URL.** The direct googlevideo.com URL
  `yt-dlp` resolves is only valid for the IP that requested it (the backend
  container), not the browser, so it has to be proxied through, not handed
  off.
- **Local library and YouTube share one player.** Both are just an `<audio>`
  `src`, whether a Navidrome Subsonic stream URL or a `/api/stream/<id>` URL,
  so one queue, one set of transport controls, one now-playing bar covers both.
- **yt-dlp's own cache survives restarts.** Every `/api/stream` request
  extracts a video's metadata twice (once to resolve `Content-Type` before
  the response starts, once more inside the actual `yt-dlp` subprocess).
  `XDG_CACHE_HOME` points at a named volume specifically so the expensive
  part of that (YouTube's player-JS signature functions, keyed by player
  version) isn't recomputed from scratch after every container restart.

## Prerequisites

- Raspberry Pi 5 (4GB or 8GB), 64-bit Raspberry Pi OS, with Docker Engine +
  the Compose v2 plugin (`docker compose version` should print `v2.x`)
- An existing local music library (FLAC, MP3, etc.) on disk
- Internet access for the YouTube features (obviously not needed for the
  local library)

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

### 4. Where does your music library live?

`MUSIC_PATH` just needs to be a directory the Pi can read; it doesn't have
to be an external drive. If your library already fits comfortably on the
Pi's boot storage (a large NVMe SSD, say), a plain directory there is fine.
If you're pointing at a separate external drive instead:

```bash
lsblk -f                                  # identify the device, e.g. /dev/sda1
sudo mkdir -p /mnt/music
sudo mount /dev/sda1 /mnt/music
```

Then add it to `/etc/fstab` with the **`nofail`** option, so the Pi still
boots normally even if that drive is ever unplugged. Docker will simply
refuse to start the affected container instead (see
[Troubleshooting](#troubleshooting)), rather than the whole Pi hanging at
boot waiting for a missing mount:

```bash
blkid /dev/sda1        # copy the UUID
sudo nano /etc/fstab    # add: UUID=<uuid>  /mnt/music  ext4  defaults,nofail  0  2
sudo mount -a           # verify the fstab line is valid
```

## Quick start

> Assumes the Pi is already prepared. See [Prepare the Pi](#prepare-the-pi)
> above.

```bash
git clone https://github.com/<you>/home-services.git
cd home-services/pitune

cp .env.example .env
nano .env   # set MUSIC_PATH, NAVIDROME_DATA_PATH, PUID/PGID, TZ at minimum

mkdir -p "$(grep ^NAVIDROME_DATA_PATH .env | cut -d= -f2)"

docker compose up -d --build
```

Then:

1. Open `http://<pi-ip>:4533/` (Navidrome's own port) and create your first
   admin user. This is Navidrome's own account system, separate from
   anything PiTune adds.
2. Open `http://<pi-ip>:8096/` (PiTune itself). On the **Library** tab, log
   in with that same Navidrome account. This is stored only in your
   browser's `localStorage`, never on the server.
3. Use the **YouTube** tab to search and stream audio, or browse your library
   under **Library**. Both add to the same **Queue**.

## Configuration (`.env`)

| Variable | Default | What it controls |
|---|---|---|
| `MUSIC_PATH` | — | Host path to your existing music library. Mounted read-only into Navidrome always, and into the backend unless `DOWNLOAD_ENABLED`/`MUSIC_MOUNT_MODE` are turned on. |
| `NAVIDROME_DATA_PATH` | — | Host path for Navidrome's own database/cache/index. Keep this off `MUSIC_PATH` so a rescan can't touch it. |
| `PITUNE_PORT` | `8096` | The one port you actually use day to day. |
| `NAVIDROME_PORT` | `4533` | Navidrome's own admin UI / direct Subsonic access. |
| `PUID` / `PGID` | `1000`/`1000` | uid/gid Navidrome runs as, so it can read `MUSIC_PATH`. Run `id -u` / `id -g`. |
| `NAVIDROME_TAG` | `latest` | Pin once the stack is validated; see the note in `.env.example`. |
| `ND_SCANSCHEDULE` | `@every 1h` | How often Navidrome rescans `MUSIC_PATH`. |
| `SEARCH_RESULT_LIMIT` | `20` | Max YouTube results per search. |
| `YTDLP_COOKIES_HOST_FILE` | unset | Path to a Netscape-format `cookies.txt`, only needed for age-restricted/region-locked videos. |
| `DOWNLOAD_ENABLED` + `MUSIC_MOUNT_MODE` | `false` / `true` (read-only) | Together enable "save this YouTube track to the library"; see below. Both must be flipped, since `DOWNLOAD_ENABLED` alone does nothing while the mount stays read-only. |

## Ports

| Container | Published as | Notes |
|---|---|---|
| frontend | `${PITUNE_PORT}:80` | The app. |
| navidrome | `${NAVIDROME_PORT}:4533` | Admin UI + direct Subsonic clients. |
| backend | *(not published)* | Reached only via the frontend's `/api/` proxy. |
| tailscale | *(not published, joins your tailnet instead)* | Optional, off by default. See [Remote access via Tailscale](#remote-access-via-tailscale-optional). |

## Features

- Browse and stream the local library via Navidrome's Subsonic API
- YouTube search → click a result → audio-only playback starts immediately,
  no video, no ads
- One queue and one player for both local and YouTube tracks: play/pause,
  skip, seek, volume
- Dark UI by default, responsive layout for phones
- Optional: save a YouTube track as an MP3 into the library
  (`POST /api/save/<video_id>`, gated by `DOWNLOAD_ENABLED`)

## Keeping `yt-dlp` up to date

YouTube changes its player/signature logic often enough that an old `yt-dlp`
simply stops finding or playing audio. `yt-dlp` is intentionally left
unpinned in `backend/requirements.txt`; when search or playback starts
failing, run:

```bash
bash scripts/update-ytdlp.sh
```

This rebuilds the backend image with `--no-cache` (so the `pip install` layer
actually re-resolves the latest release) and restarts just that container.
Navidrome and your library are untouched.

## Security model

This stack assumes it never leaves your home network by default. There's
no VPN layer running unless you turn one on. An optional Tailscale profile
for secure remote access is available; see
[Remote access via Tailscale](#remote-access-via-tailscale-optional) below,
rather than exposing `PITUNE_PORT` directly to the internet.

| Control | What it does |
|---|---|
| Local library mounted read-only into Navidrome | Navidrome only ever scans; it can't be tricked into writing into your library. |
| Local library mounted read-only into the backend by default | `/api/save` (the only writer) is a no-op until you explicitly opt in via `DOWNLOAD_ENABLED` **and** `MUSIC_MOUNT_MODE`. |
| `API_TOKEN` on `/api/save` | Without it, that endpoint has no auth at all once `DOWNLOAD_ENABLED=true`. A plain unauthenticated POST is a "simple request" a browser sends cross-origin regardless of CORS, so CORS alone wouldn't have stopped a malicious webpage from triggering a download with no user interaction. See `backend/app/main.py`'s `API_TOKEN`/`CORS_ORIGINS` comments for the full reasoning. |
| `CORS_ORIGINS` empty by default, not `*` | The frontend and backend are always same-origin here (one reverse proxy), so legitimate use never needs a cross-origin allowance. |
| Security headers (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, a strict `Content-Security-Policy`) | Set at the frontend's own nginx, which is safe to make this strict specifically because the app has no inline scripts/styles and only one external resource type (YouTube's thumbnail CDN, allowed via `img-src`). |
| Navidrome's own auth (Subsonic token scheme) | PiTune doesn't invent its own user system for the library; it reuses Navidrome's, salted-hash-per-request, never sending the raw password after the first browser-local save. |
| `no-new-privileges` on every container | Standard defense-in-depth even though nothing here needs extra capabilities. |
| Video-ID validation in the backend | YouTube video IDs are checked against `^[A-Za-z0-9_-]{11}$` before being placed on a `yt-dlp` command line, so a crafted ID can't be parsed as a CLI flag. |
| `.env` never committed | Holds no long-lived secrets besides `API_TOKEN` and, if you enable it, `TS_AUTHKEY`; keep it out of git regardless, see `.gitignore`. |
| Tailscale ACL allow-list (`../tailscale/acl-policy.hujson`), off by default | Only used if you opt into the `tailscale` profile; see [Remote access via Tailscale](#remote-access-via-tailscale-optional). Grants only `tag:approved-device` sources access to `tag:pitune-server:443`, a tag scoped to this stack alone, not the whole node and not shared with home-drive/PiHub. |
| `tailscale-preflight` container, only in the `tailscale` profile | Refuses to let `tailscale` start if `DOWNLOAD_ENABLED=true` but `API_TOKEN` is unset; see [Remote access via Tailscale](#remote-access-via-tailscale-optional). A hard gate, not just a warning, since this profile is what turns an unauthenticated `/api/save` from a LAN-only convenience into a remote exposure. |

**`NAVIDROME_PORT` has no proxy in front of it.** Unlike `PITUNE_PORT`
(nginx: rate-limit-able, gets the headers above), Navidrome's direct port is
its own bare HTTP server, reachable by anything on your LAN with nothing
extra between them. Consider restricting it to your own subnet with `ufw`:

```bash
ip -br -4 addr show eth0        # find YOUR LAN subnet, e.g. 192.168.1.0/24
sudo ufw allow from 192.168.1.0/24 to any port 4533 proto tcp
sudo ufw deny 4533/tcp           # only reachable from that subnet now
```

## Remote access via Tailscale (optional)

By default this stack really does stop at your LAN, as the Security model
above says. If you also want to reach PiTune from outside the house,
without opening any port on your router, an optional `tailscale` profile
is included:

```bash
cp .env.example .env   # if you haven't already
nano .env               # set API_TOKEN (only matters if DOWNLOAD_ENABLED=true) and TS_AUTHKEY; leave TS_HOSTNAME/TS_EXTRA_ARGS as-is
docker compose --profile tailscale up -d tailscale
```

This starts one extra container that joins your tailnet and, over that
private WireGuard network only, serves PiTune's existing frontend at
`https://<TS_HOSTNAME>.<your-tailnet>.ts.net/`. `PITUNE_PORT` keeps working
on the LAN exactly as before; this is an additional way in, not a
replacement.

**If `DOWNLOAD_ENABLED=true`, `API_TOKEN` is a hard prerequisite for this
profile, not just a recommendation.** A `tailscale-preflight` container
runs before `tailscale` starts and refuses to let it come up if
`DOWNLOAD_ENABLED=true` but `API_TOKEN` is unset, because once `/api/save`
is reachable from outside the LAN, "no auth configured yet" stops being a
quick-local-test convenience. `docker compose --profile tailscale up -d`
fails loudly with an explanation in that case instead of starting anyway.
(If `DOWNLOAD_ENABLED=false`, the default, this check is a no-op.)

**Before you enable this, more has to happen on Tailscale's side first, not
just in this repo:**

1. Apply [`../tailscale/acl-policy.hujson`](../tailscale/acl-policy.hujson)
   to your tailnet's ACL (Tailscale admin console → Access Controls). Skip
   this and joining the tailnet exposes *every* open port on the Pi,
   including `NAVIDROME_PORT`, to any device on your tailnet, not just the
   one path above. See
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

See [`../tailscale/README.md`](../tailscale/README.md) for the full
picture, including why the ACL grants only `tag:pitune-server:443` (a
separate tag per stack, not one shared tag for everything, so a device can
be scoped to just this stack if you want) rather than opening the whole
node, and why a static device allow-list, not a live concurrent-connection
counter, is the actual "only these devices, only this many" control here.
`frontend/nginx.conf`'s `limit_conn` (20 per source IP) is a narrower,
complementary safety net on top of that, not a substitute for it.

## Troubleshooting

**YouTube search/playback returns errors that mention signatures, formats, or
403s.** Almost always a stale `yt-dlp`; run `scripts/update-ytdlp.sh`.

**Age-restricted or "Sign in to confirm you're not a bot" errors.** Export a
`cookies.txt` from a browser logged into YouTube (e.g. the "Get cookies.txt"
extension), set `YTDLP_COOKIES_HOST_FILE` in `.env`, and
`docker compose up -d backend`.

**Library tab won't log in.** Confirm the account exists in Navidrome's own
admin UI at `http://<pi-ip>:4533/` first. PiTune's login just forwards your
credentials to Navidrome's Subsonic API; it doesn't create accounts.

**Library tab shows "Could not reach Navidrome" with a Retry button, instead
of the login form.** This is by design, not a stuck state: your saved login
is kept (nothing said the password was wrong), and it means Navidrome itself
is unreachable right now, most often because it's still starting up, or
mid-restart after an update. Click **Retry**, or just wait for
`docker compose ps` to show it healthy again. The login form only reappears
on an actual wrong-password response from Navidrome.

**Navidrome doesn't see a file you just added.** Either wait for the next
`ND_SCANSCHEDULE` tick or trigger a rescan from Navidrome's admin UI
(Settings → force a full scan).

**"bind source path does not exist" on startup.** `MUSIC_PATH` or
`NAVIDROME_DATA_PATH` isn't there yet. Both bind mounts use
`create_host_path: false` deliberately, so a typo'd or unmounted path fails
loudly instead of Docker quietly creating an empty directory in the wrong
place.

## File structure

```
pitune/
├── docker-compose.yml
├── .env.example
├── backend/              # FastAPI wrapper around yt-dlp
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/main.py
├── frontend/              # nginx: static SPA + reverse proxy
│   ├── Dockerfile
│   ├── nginx.conf
│   └── src/
├── tailscale/
│   └── serve.json         # optional profile — see Remote access via Tailscale
└── scripts/
    └── update-ytdlp.sh
```

See also [`../tailscale/`](../tailscale/) at the repo root: the shared ACL
policy and device-onboarding docs used by every stack's Tailscale profile,
not just this one.
