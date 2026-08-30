"""PiTune backend — wraps yt-dlp for YouTube search and audio-only streaming.

Two things this deliberately does NOT do:
  - It never downloads a full video file to serve /api/stream. It pipes
    yt-dlp's own stdout straight into the HTTP response, chunk by chunk, in
    whatever container YouTube served (webm/opus or m4a/aac) — no re-encode,
    no temp file, minimal CPU/disk load on a Pi.
  - It never redirects the browser to the raw googlevideo.com URL yt-dlp
    resolves. That URL is only valid for the IP that requested it — which
    would be this container, not the browser — so redirecting would just 403.
"""

import asyncio
import logging
import os
import re
import secrets
import shutil
from pathlib import Path

import yt_dlp
from fastapi import Depends, FastAPI, Header, HTTPException, Path as PathParam, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

logger = logging.getLogger("pitune.backend")
logging.basicConfig(level=logging.INFO)

SEARCH_RESULT_LIMIT = int(os.environ.get("SEARCH_RESULT_LIMIT", "20"))
DOWNLOAD_ENABLED = os.environ.get("DOWNLOAD_ENABLED", "false").strip().lower() == "true"
MUSIC_PATH = Path(os.environ.get("MUSIC_PATH", "/music"))
# Empty, not "*": the frontend and this API are always same-origin (served
# through the same nginx), so legitimate use never needs a cross-origin
# allowance. See main.py's require_token for why this alone wouldn't be
# enough to protect /api/save even if it were narrowed instead of emptied.
CORS_ORIGINS = [o.strip() for o in os.environ.get("CORS_ORIGINS", "").split(",") if o.strip()]

# Protects /api/save only — /api/search and /api/stream are read-only and
# stay open (see README.md's security model for that trade-off). Without
# this, a malicious webpage's background POST would trigger a real download
# to disk with no user interaction, purely because DOWNLOAD_ENABLED=true —
# CORS alone would not stop it: a plain POST with no custom header is a
# "simple request" that a browser sends cross-origin regardless of CORS,
# which only ever gates whether the attacker's JS can read the response.
API_TOKEN = os.environ.get("API_TOKEN", "").strip()
if DOWNLOAD_ENABLED and not API_TOKEN:
    logger.warning(
        "DOWNLOAD_ENABLED=true but API_TOKEN is not set — /api/save has no "
        "auth at all. Set API_TOKEN in .env before exposing this beyond "
        "your own machine."
    )


async def require_token(x_pihub_token: str = Header(default="")):
    if not API_TOKEN:
        return
    if not secrets.compare_digest(x_pihub_token, API_TOKEN):
        raise HTTPException(status_code=401, detail="Missing or invalid X-PiHub-Token header")

# /dev/null is bind-mounted here when YTDLP_COOKIES_FILE is unset (see
# docker-compose.yml) — reading it back yields an empty file, not an error, so
# this only takes effect when a real cookies.txt is mounted over it.
_COOKIES_FILE = Path("/config/cookies.txt")
YTDLP_COOKIES_FILE = str(_COOKIES_FILE) if _COOKIES_FILE.is_file() and _COOKIES_FILE.stat().st_size > 0 else None

# YouTube video IDs are always exactly 11 URL-safe base64-ish characters.
# Validating this up front matters beyond input hygiene: video_id is passed as
# a literal argv element to the yt-dlp CLI in stream(), and a value starting
# with "-" would otherwise be parsed as a yt-dlp flag instead of a URL.
_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")

_EXT_MIME = {"webm": "audio/webm", "m4a": "audio/mp4", "mp3": "audio/mpeg", "opus": "audio/opus"}

app = FastAPI(title="PiTune backend")
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)

_BASE_OPTS = {"quiet": True, "no_warnings": True, "noplaylist": True}
if YTDLP_COOKIES_FILE:
    _BASE_OPTS["cookiefile"] = YTDLP_COOKIES_FILE


def _validate_video_id(video_id: str) -> str:
    if not _VIDEO_ID_RE.match(video_id):
        raise HTTPException(status_code=400, detail="Invalid YouTube video ID")
    return video_id


def _video_url(video_id: str) -> str:
    return f"https://www.youtube.com/watch?v={video_id}"


def _run_search(query: str, limit: int) -> list[dict]:
    """Blocking (network I/O) — always call via asyncio.to_thread."""
    opts = {**_BASE_OPTS, "extract_flat": "in_playlist", "skip_download": True}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"ytsearch{limit}:{query}", download=False)

    results = []
    for entry in info.get("entries") or []:
        if not entry:
            continue
        thumbnails = entry.get("thumbnails") or []
        results.append({
            "id": entry.get("id"),
            "title": entry.get("title"),
            "artist": entry.get("uploader") or entry.get("channel"),
            "duration": entry.get("duration"),
            "thumbnail": thumbnails[-1]["url"] if thumbnails else None,
        })
    return results


def _resolve_audio(video_id: str) -> dict:
    """Resolves the best audio-only format WITHOUT downloading, so we know the
    container (webm/m4a) and can set Content-Type before the stream starts."""
    opts = {**_BASE_OPTS, "format": "bestaudio/best", "skip_download": True}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(_video_url(video_id), download=False)
    return {"ext": info.get("ext", "webm"), "title": info.get("title")}


@app.get("/api/health")
async def health():
    return {"status": "ok"}


@app.get("/api/version")
async def version():
    return {"yt_dlp_version": yt_dlp.version.__version__}


@app.get("/api/search")
async def search(q: str = Query(..., min_length=1), limit: int = SEARCH_RESULT_LIMIT):
    try:
        results = await asyncio.to_thread(_run_search, q, max(1, min(limit, 50)))
    except yt_dlp.utils.DownloadError as exc:
        raise HTTPException(status_code=502, detail=f"YouTube search failed: {exc}")
    return {"results": results}


@app.get("/api/stream/{video_id}")
async def stream(video_id: str = PathParam(..., min_length=11, max_length=11)):
    video_id = _validate_video_id(video_id)

    try:
        meta = await asyncio.to_thread(_resolve_audio, video_id)
    except yt_dlp.utils.DownloadError as exc:
        raise HTTPException(status_code=404, detail=f"Video unavailable: {exc}")

    ytdlp_bin = shutil.which("yt-dlp")
    cmd = [ytdlp_bin]
    if YTDLP_COOKIES_FILE:
        cmd += ["--cookies", YTDLP_COOKIES_FILE]
    cmd += [
        "--quiet", "--no-warnings", "--no-playlist",
        "-f", "bestaudio/best",
        "-o", "-",
        _video_url(video_id),
    ]

    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )

    async def body():
        try:
            while True:
                chunk = await proc.stdout.read(64 * 1024)
                if not chunk:
                    break
                yield chunk
        finally:
            # A skipped/closed track must not leave yt-dlp running in the
            # background still pulling bytes off YouTube.
            if proc.returncode is None:
                proc.kill()
            await proc.wait()

    media_type = _EXT_MIME.get(meta["ext"], "application/octet-stream")
    return StreamingResponse(body(), media_type=media_type)


@app.post("/api/save/{video_id}", dependencies=[Depends(require_token)])
async def save_to_library(video_id: str = PathParam(..., min_length=11, max_length=11)):
    video_id = _validate_video_id(video_id)

    if not DOWNLOAD_ENABLED:
        raise HTTPException(
            status_code=403,
            detail="Saving to the library is disabled (set DOWNLOAD_ENABLED=true and "
                   "MUSIC_MOUNT_MODE=rw in .env)",
        )
    if not MUSIC_PATH.is_dir():
        raise HTTPException(status_code=500, detail=f"{MUSIC_PATH} is not mounted")

    def _download() -> str:
        opts = {
            **_BASE_OPTS,
            "format": "bestaudio/best",
            "outtmpl": str(MUSIC_PATH / "YouTube" / "%(uploader)s - %(title)s.%(ext)s"),
            "postprocessors": [{
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "192",
            }],
        }
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(_video_url(video_id), download=True)
        return info.get("title", video_id)

    try:
        title = await asyncio.to_thread(_download)
    except yt_dlp.utils.DownloadError as exc:
        raise HTTPException(status_code=502, detail=f"Download failed: {exc}")

    return {"saved": True, "title": title}
