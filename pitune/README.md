# PiTune — Self-Hosted Music Server with YouTube Streaming

A dockerized music server for Raspberry Pi that combines your local library
with ad-free, audio-only YouTube playback in one unified web player, reachable
from any device on your home network.

**For personal use on a home network only.** There is no authentication layer
in front of PiTune itself — see [Security model](#security-model).

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

Only the frontend's port needs to be reached day to day — everything else
talks over the internal compose network. Navidrome's own port is also
published so you can reach its admin UI directly to create library users.

## Why this design

- **One origin for the browser.** nginx proxies both `/api/` and `/rest/` so
  the SPA never makes a cross-origin request. That sidesteps CORS entirely
  and means the whole app is one URL — the thing that actually matters for
  "open it on my phone on the same Wi-Fi".
- **No re-encoding, no temp files.** `/api/stream/<id>` pipes `yt-dlp`'s own
  stdout straight into the HTTP response in whatever container YouTube served
  (webm/opus or m4a/aac). No video stream is ever requested, and nothing
  touches disk — light on a Pi's CPU and SD card alike.
- **No redirect to the raw YouTube URL.** The direct googlevideo.com URL
  `yt-dlp` resolves is only valid for the IP that requested it (the backend
  container), not the browser, so it has to be proxied through, not handed
  off.
- **Local library and YouTube share one player.** Both are just an `<audio>`
  `src` — a Navidrome Subsonic stream URL or a `/api/stream/<id>` URL — so one
  queue, one set of transport controls, one now-playing bar covers both.

## Prerequisites

- Raspberry Pi 5 (4GB or 8GB), 64-bit Raspberry Pi OS, with Docker Engine +
  the Compose v2 plugin (`docker compose version` should print `v2.x`)
- An existing local music library (FLAC, MP3, etc.) on disk
- Internet access for the YouTube features (obviously not needed for the
  local library)

## Quick start

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
   admin user — this is Navidrome's own account system, separate from
   anything PiTune adds.
2. Open `http://<pi-ip>:8096/` (PiTune itself). On the **Library** tab, log
   in with that same Navidrome account — this is stored only in your
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
| `NAVIDROME_TAG` | `latest` | Pin once the stack is validated — see the note in `.env.example`. |
| `ND_SCANSCHEDULE` | `@every 1h` | How often Navidrome rescans `MUSIC_PATH`. |
| `SEARCH_RESULT_LIMIT` | `20` | Max YouTube results per search. |
| `YTDLP_COOKIES_HOST_FILE` | unset | Path to a Netscape-format `cookies.txt`, only needed for age-restricted/region-locked videos. |
| `DOWNLOAD_ENABLED` + `MUSIC_MOUNT_MODE` | `false` / `true` (read-only) | Together enable "save this YouTube track to the library" — see below. Both must be flipped; `DOWNLOAD_ENABLED` alone does nothing while the mount stays read-only. |

## Ports

| Container | Published as | Notes |
|---|---|---|
| frontend | `${PITUNE_PORT}:80` | The app. |
| navidrome | `${NAVIDROME_PORT}:4533` | Admin UI + direct Subsonic clients. |
| backend | *(not published)* | Reached only via the frontend's `/api/` proxy. |

## Features

- Browse and stream the local library via Navidrome's Subsonic API
- YouTube search → click a result → audio-only playback starts immediately,
  no video, no ads
- One queue and one player for both local and YouTube tracks — play/pause,
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
actually re-resolves the latest release) and restarts just that container —
Navidrome and your library are untouched.

## Security model

This stack assumes it never leaves your home network — there is no VPN layer
here (unlike this repo's `home-drive` stack, which puts everything behind
Tailscale). If you want PiTune reachable away from home, put it behind your
own VPN or reverse proxy with auth rather than exposing `PITUNE_PORT`
directly to the internet.

| Control | What it does |
|---|---|
| Local library mounted read-only into Navidrome | Navidrome only ever scans; it can't be tricked into writing into your library. |
| Local library mounted read-only into the backend by default | `/api/save` (the only writer) is a no-op until you explicitly opt in via `DOWNLOAD_ENABLED` **and** `MUSIC_MOUNT_MODE`. |
| Navidrome's own auth (Subsonic token scheme) | PiTune doesn't invent its own user system for the library — it reuses Navidrome's, salted-hash-per-request, never sending the raw password after the first browser-local save. |
| `no-new-privileges` on every container | Standard defense-in-depth even though nothing here needs extra capabilities. |
| Video-ID validation in the backend | YouTube video IDs are checked against `^[A-Za-z0-9_-]{11}$` before being placed on a `yt-dlp` command line, so a crafted ID can't be parsed as a CLI flag. |
| `.env` never committed | Holds no secrets by default in this stack (no passwords are generated here), but keep it out of git regardless — see `.gitignore`. |

## Troubleshooting

**YouTube search/playback returns errors that mention signatures, formats, or
403s.** Almost always a stale `yt-dlp` — run `scripts/update-ytdlp.sh`.

**Age-restricted or "Sign in to confirm you're not a bot" errors.** Export a
`cookies.txt` from a browser logged into YouTube (e.g. the "Get cookies.txt"
extension), set `YTDLP_COOKIES_HOST_FILE` in `.env`, and
`docker compose up -d backend`.

**Library tab won't log in.** Confirm the account exists in Navidrome's own
admin UI at `http://<pi-ip>:4533/` first — PiTune's login just forwards your
credentials to Navidrome's Subsonic API, it doesn't create accounts.

**Navidrome doesn't see a file you just added.** Either wait for the next
`ND_SCANSCHEDULE` tick or trigger a rescan from Navidrome's admin UI
(Settings → force a full scan).

**"bind source path does not exist" on startup.** `MUSIC_PATH` or
`NAVIDROME_DATA_PATH` isn't there yet — both bind mounts use
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
└── scripts/
    └── update-ytdlp.sh
```
