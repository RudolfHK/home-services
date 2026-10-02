"""PiTune backend — wraps yt-dlp for YouTube search and audio-only streaming.

/api/stream downloads the resolved audio-only format to a local cache file
first, then serves that file with FileResponse, rather than piping a live
yt-dlp subprocess straight into the response. A piped subprocess cannot
answer an HTTP Range request (there's no seeking backward or forward in a
one-way pipe), so <audio>'s own seek bar had nothing to work with and just
restarted playback from 0:00 on every scrub. FileResponse handles Range
natively, giving real seeking, at the cost of a delay before playback
starts (waiting for the whole track to download) instead of the previous
near-instant first byte. The cache is deliberately NOT a persistent volume:
plain container-local storage that disappears on every restart, so repeat
plays/seeks within one uptime are free without needing eviction logic for
an otherwise-unbounded "every song ever streamed" cache.

This still never redirects the browser to the raw googlevideo.com URL
yt-dlp resolves; that URL is only valid for the IP that requested it
(this container, not the browser), so redirecting would just 403.

/api/save/{id} (saving a track into the library) is fire-and-forget: the
POST starts the download as a background task and returns immediately,
rather than blocking the request for the whole download+MP3-reencode. The
frontend polls GET /api/save/{id}/status, backed by yt-dlp's own
progress_hooks, to show a real progress bar and to tell an actual failure
apart from "still working" instead of guessing from a single request
timing out.

/api/search's duration/upload_date filters and its sort-by-views are
YouTube's OWN search filters (the `sp` parameter its results page uses, see
_search_sp), so they apply across YouTube's whole index, exactly the way
the filter menu on youtube.com does. An earlier version filtered a few
dozen relevance-ranked results after the fact instead, which almost never
contained anything from "the last hour", could only sort by views within
that same small batch, and (since flat extraction carries no upload date
unless asked for, see _FLAT_OPTS) returned nothing at all for ANY
upload-date filter. Sorting by upload date is the one exception: YouTube's
search no longer honors that request (yt-dlp removed its ytsearchdate:
scheme over it, which is also why using it here had started returning 500s),
so it's a re-sort of the fetched batch by approximate upload time, see
_sort_entries. /api/channel/{id} (a channel's own uploads) has no
server-side filters to hand off to, so it still filters an over-fetched
batch itself (_matches_filters/_sort_entries); both endpoints return the
same flat, extract_flat "in_playlist" entry shape via _entry_to_result.
Neither supports true cursor-based pagination (neither list exposes one
through yt-dlp); "load more" instead re-asks for a larger `limit` and the
whole result set is re-rendered, not appended to, since a sort like
"views" can legitimately reorder once more candidates are considered.

/api/playcount/{source}/{id} is PiTune's OWN play counter, separate from
Navidrome's. It exists because Navidrome only ever knows about local
library songs (scrobble() stays the source of truth for those, and this
doesn't replace it); a YouTube track never earns a single play count
anywhere until it's saved into the library, which meant "Most Played"
could only ever show already-saved tracks, and even then only via a random
sample (Subsonic has no "most played" endpoint, only getTopSongs for one
artist). Recording a play here on every natural finish, for both local and
YouTube tracks alike, is what lets /api/playcount/top return a real,
exact top-N ranking across both instead of an approximation, persisted to
PLAY_COUNTS_PATH (a small JSON file, atomically rewritten, see
_save_play_counts) so it survives a container restart the same way
Navidrome's own counts do.
"""

import asyncio
import base64
import json
import logging
import os
import re
import secrets
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

import yt_dlp
from fastapi import Depends, FastAPI, Header, HTTPException, Path as PathParam, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel

logger = logging.getLogger("pitune.backend")
logging.basicConfig(level=logging.INFO)

SEARCH_RESULT_LIMIT = int(os.environ.get("SEARCH_RESULT_LIMIT", "20"))
# On by default: the frontend calls /api/save automatically once a
# YouTube-sourced track finishes playing (see app.js's maybeAutoSave). Set
# to false in .env to turn that off, or to reject direct calls to the
# endpoint entirely.
DOWNLOAD_ENABLED = os.environ.get("DOWNLOAD_ENABLED", "true").strip().lower() == "true"
# A "YouTube" subfolder INSIDE the actual scanned music library (see
# pihub/docker-compose.yml: this container is only ever given write access
# to that one subfolder, never the rest of /music), not a separate
# disposable folder. Navidrome picks up new files here on its own regular
# scan (ND_SCANSCHEDULE), no manual "add a second library" step needed. If
# MEDIA_LIBRARY_ROOT points this at a folder inside home-drive's Nextcloud,
# Nextcloud's own index does NOT learn about these files automatically;
# run `occ files:scan --all` afterward (or on a schedule). See
# ../../README.md's "Mounting a Nextcloud folder as your media library".
MUSIC_SAVE_PATH = Path(os.environ.get("MUSIC_SAVE_PATH", "/music/youtube"))
# Empty, not "*": the frontend and this API are always same-origin (served
# through the same nginx), so legitimate use never needs a cross-origin
# allowance. See require_token below for why this alone wouldn't be enough
# to protect /api/save even if it were narrowed instead of emptied.
CORS_ORIGINS = [o.strip() for o in os.environ.get("CORS_ORIGINS", "").split(",") if o.strip()]

# Protects /api/save only — /api/search and /api/stream are read-only and
# stay open (see ../../README.md's security model for that trade-off).
# Without this, a malicious webpage's background POST would trigger a real
# download to disk with no user interaction, purely because
# DOWNLOAD_ENABLED=true — CORS alone would not stop it: a plain POST with
# no custom header is a "simple request" that a browser sends cross-origin
# regardless of CORS, which only ever gates whether the attacker's JS can
# read the response.
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
# Validating this up front matters beyond input hygiene: video_id becomes
# part of a cache filename in _download_for_stream() below, and FastAPI's
# own path-parameter length bounds don't rule out something like "../../etc"
# on their own.
_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")

# Channel IDs are always "UC" + 22 URL-safe base64-ish characters. channel_id
# becomes part of a URL handed straight to yt-dlp in _channel_url() below, so
# this is validated the same defense-in-depth way as _VIDEO_ID_RE above:
# FastAPI's own PathParam length bounds narrow it first, then this regex.
_CHANNEL_ID_RE = re.compile(r"^UC[A-Za-z0-9_-]{22}$")

_EXT_MIME = {"webm": "audio/webm", "m4a": "audio/mp4", "mp3": "audio/mpeg", "opus": "audio/opus"}

# Deliberately container-local, not a bind mount or named volume (see the
# module docstring): this cache is meant to disappear on every restart.
_STREAM_CACHE_DIR = Path("/tmp/pitune-stream-cache")
_STREAM_CACHE_DIR.mkdir(parents=True, exist_ok=True)

# In-memory only, keyed by video_id: {"status": "downloading"|"processing"|
# "done"|"error", "percent": float|None, "error": str|None}. Lost on
# restart, which is fine; nothing durable depends on it, it only exists so
# /api/save/{id}/status has something to poll while a save runs. The lock
# guards against a hook running in the download's own thread racing the
# event loop's read of the same dict.
_SAVE_PROGRESS: dict = {}
_SAVE_PROGRESS_LOCK = threading.Lock()

# Holds references to fire-and-forget save tasks so asyncio can't garbage
# collect one mid-download (a real risk for a Task nothing else holds onto).
_background_tasks: set = set()

# Local library song IDs are Navidrome's own (UUID-shaped in practice, but
# that's not a documented guarantee); this is a generic, generous bound
# rather than assuming that exact shape, since nothing here needs to parse
# the ID, only store it as a dict key.
_LOCAL_TRACK_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")

# Deliberately a bind mount (see docker-compose.yml's PITUNE_DATA_PATH),
# unlike _STREAM_CACHE_DIR above: play counts are real, meaningful user data
# (the whole point is that it survives a restart the way Navidrome's own
# counts do), not a disposable cache.
PLAY_COUNTS_PATH = Path(os.environ.get("PLAY_COUNTS_PATH", "/data/play_counts.json"))
_PLAY_COUNTS_LOCK = threading.Lock()


def _load_play_counts() -> dict:
    try:
        return json.loads(PLAY_COUNTS_PATH.read_text())
    except FileNotFoundError:
        return {}
    except (json.JSONDecodeError, OSError) as exc:
        # A corrupted file (e.g. a container killed mid-write before atomic
        # writes existed, or before this feature existed at all) shouldn't
        # take the whole backend down on startup; losing accumulated counts
        # is unfortunate, not catastrophic, and they start accumulating
        # again from here.
        logger.warning("Could not read %s, starting with empty play counts: %s", PLAY_COUNTS_PATH, exc)
        return {}


# Loaded once at startup, kept in memory, and rewritten to disk on every
# change; this process is the only writer, so there's no risk of another
# process's concurrent edit being silently overwritten.
_play_counts: dict = _load_play_counts()


def _save_play_counts() -> None:
    """Write-then-rename instead of writing PLAY_COUNTS_PATH directly: a
    container killed mid-write (a Pi losing power, say) must never leave
    play_counts.json half-written and unreadable on next start. os.replace
    (via Path.replace) is a single filesystem rename, so the file is always
    either the complete old version or the complete new one, never a
    truncated in-between."""
    PLAY_COUNTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = PLAY_COUNTS_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(_play_counts))
    tmp.replace(PLAY_COUNTS_PATH)


class PlayMeta(BaseModel):
    # Only meaningful (and only ever supplied) for source="youtube": a local
    # library song's title/artist/etc. is always fetched fresh from
    # Navidrome instead (see app.js's showMostPlayed), so it's never stale
    # relative to the library itself.
    title: str | None = None
    artist: str | None = None
    thumbnail: str | None = None


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

# Flat ("in_playlist") listing, shared by search and channel uploads.
# approximate_date matters: without it yt-dlp leaves timestamp/upload_date
# unset on EVERY flat entry (an exact date would cost one extra request per
# video), so there was nothing to filter or sort by date on at all. With it,
# yt-dlp turns YouTube's own "3 weeks ago" label into an approximate
# timestamp at no extra cost. Approximate is all a "this week"/"this month"
# style filter needs anyway.
_FLAT_OPTS = {
    **_BASE_OPTS, "extract_flat": "in_playlist", "skip_download": True,
    "extractor_args": {"youtubetab": {"approximate_date": [""]}},
}

# Upper bounds on `limit`, so "load more" has a defined end: hasMore turns
# false once a bigger limit could no longer return anything new.
_SEARCH_MAX_RESULTS = 150
_CHANNEL_MAX_ENTRIES = 200


def _validate_video_id(video_id: str) -> str:
    if not _VIDEO_ID_RE.match(video_id):
        raise HTTPException(status_code=400, detail="Invalid YouTube video ID")
    return video_id


def _validate_channel_id(channel_id: str) -> str:
    if not _CHANNEL_ID_RE.match(channel_id):
        raise HTTPException(status_code=400, detail="Invalid YouTube channel ID")
    return channel_id


def _validate_track_id(source: str, track_id: str) -> str:
    if source == "youtube":
        return _validate_video_id(track_id)
    if not _LOCAL_TRACK_ID_RE.match(track_id):
        raise HTTPException(status_code=400, detail="Invalid track ID")
    return track_id


def _video_url(video_id: str) -> str:
    return f"https://www.youtube.com/watch?v={video_id}"


def _channel_url(channel_id: str) -> str:
    return f"https://www.youtube.com/channel/{channel_id}/videos"


# YouTube's own search filters, as its results page encodes them in the
# `sp` URL parameter: a base64 protobuf message, {1: sort order,
# 2: {1: upload date, 2: result type, 3: duration}}. Verified live against
# YouTube: every bucket below comes back exactly as labelled. Relevance is
# the default sort (field omitted); a sort-by-upload-date value (2) still
# parses but YouTube ignores it now, see _sort_entries.
_SP_SORT = {"views": 3}
_SP_UPLOAD_DATE = {"hour": 1, "today": 2, "week": 3, "month": 4, "year": 5}
_SP_DURATION = {"short": 1, "long": 2, "medium": 3}  # <4 min, >20 min, 4-20 min
_SP_TYPE_VIDEO = 1  # never channels/playlists, which /api/stream can't play


def _pb_varint(n: int) -> bytes:
    out = bytearray()
    while True:
        byte, n = n & 0x7F, n >> 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _search_sp(sort: str, duration: str, upload_date: str) -> str:
    filters = b""
    if upload_date in _SP_UPLOAD_DATE:
        filters += _pb_varint(1 << 3) + _pb_varint(_SP_UPLOAD_DATE[upload_date])
    filters += _pb_varint(2 << 3) + _pb_varint(_SP_TYPE_VIDEO)
    if duration in _SP_DURATION:
        filters += _pb_varint(3 << 3) + _pb_varint(_SP_DURATION[duration])
    msg = (_pb_varint(1 << 3) + _pb_varint(_SP_SORT[sort])) if sort in _SP_SORT else b""
    msg += _pb_varint(2 << 3 | 2) + _pb_varint(len(filters)) + filters  # field 2, length-delimited
    return base64.b64encode(msg).decode()


def _search_url(query: str, sp: str) -> str:
    # A results-page URL (handled by yt-dlp's YoutubeSearchURL extractor,
    # which passes sp through as-is), not the ytsearchN: pseudo-URL, which
    # has no way to carry filters at all.
    return "https://www.youtube.com/results?" + urllib.parse.urlencode({"search_query": query, "sp": sp})


def _entry_to_result(entry: dict) -> dict:
    thumbnails = entry.get("thumbnails") or []
    return {
        "id": entry.get("id"),
        "title": entry.get("title"),
        "artist": entry.get("uploader") or entry.get("channel"),
        # Lets the frontend offer "view this channel's uploads" (see
        # /api/channel/{id} below) without a second lookup; None on the rare
        # entry that doesn't carry it, which the frontend just doesn't turn
        # into a link rather than erroring.
        "channelId": entry.get("channel_id"),
        "duration": entry.get("duration"),
        "thumbnail": thumbnails[-1]["url"] if thumbnails else None,
        # Present on most flat search entries without needing a full
        # per-video extraction (which would mean one real HTTP request
        # per result instead of one for the whole search); None when
        # YouTube's own search response happens not to include it, which
        # the frontend just omits rather than showing "None views".
        "viewCount": entry.get("view_count"),
        # Approximate (see _FLAT_OPTS), epoch seconds, or None; shown as
        # "3 weeks ago" the way YouTube's own results do, so a date sort
        # or filter is visibly doing what it says.
        "uploadedAt": _entry_upload_epoch(entry),
    }


_DURATION_BUCKETS = {
    "any": None,
    "short": (0, 240),      # under 4 min
    "medium": (240, 1200),  # 4-20 min
    "long": (1200, None),   # over 20 min
}
_UPLOAD_DATE_WINDOW_SECONDS = {
    "any": None,
    "hour": 3600,
    "today": 86400,
    "week": 7 * 86400,
    "month": 30 * 86400,
    "year": 365 * 86400,
}


def _entry_upload_epoch(entry: dict) -> float | None:
    """Best-effort only: flat ("in_playlist") entries never carry an exact
    upload date, since that needs a full per-video extraction, one extra
    request each, which isn't worth paying just to filter or sort a list.
    With approximate_date on (see _FLAT_OPTS), yt-dlp resolves YouTube's
    own relative "3 weeks ago" label into timestamp; upload_date (a plain
    YYYYMMDD string) is the fallback when only that's present. Live streams
    and premieres have neither. An entry with no date is excluded from an
    upload_date-filtered channel listing rather than guessed at (see
    _matches_filters), and sorts last in a date sort."""
    ts = entry.get("timestamp") or entry.get("release_timestamp")
    if ts:
        try:
            return float(ts)
        except (TypeError, ValueError):
            return None
    upload_date = entry.get("upload_date")
    if upload_date:
        try:
            return datetime.strptime(upload_date, "%Y%m%d").replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            return None
    return None


def _is_playable(entry: dict) -> bool:
    """A live broadcast never finishes downloading: /api/stream would keep
    writing a 24/7 stream into the container-local cache for as long as it
    runs, with the request itself never completing. An upcoming premiere
    has nothing to play yet. Neither belongs in a list where every row is
    supposed to be playable, and live streams top a lot of music searches
    ("lofi hip hop radio" returns three of them first)."""
    return entry.get("live_status") not in ("is_live", "is_upcoming")


def _matches_filters(entry: dict, duration: str, upload_date: str, now: float) -> bool:
    """Client-side version of YouTube's own duration/upload-date filters,
    for channel uploads, where there's no server-side filter to hand them
    to (search uses YouTube's own instead, see _search_sp). Duration is
    exact (flat entries always carry it); upload date is approximate (see
    _entry_upload_epoch)."""
    dur_bounds = _DURATION_BUCKETS[duration]
    if dur_bounds is not None:
        d = entry.get("duration")
        if d is None:
            return False
        lo, hi = dur_bounds
        if d < lo or (hi is not None and d >= hi):
            return False
    window = _UPLOAD_DATE_WINDOW_SECONDS[upload_date]
    if window is not None:
        epoch = _entry_upload_epoch(entry)
        if epoch is None or (now - epoch) > window:
            return False
    return True


def _sort_entries(entries: list[dict], sort: str) -> list[dict]:
    """Sorting by relevance keeps YouTube's own order. "views" is already
    YouTube's own ranking for search (see _search_sp; re-sorting just
    straightens its occasional near-tie out of order) and the only way to
    get it at all for channel uploads. "date" is always a re-sort here: YouTube's search no
    longer honors a sort-by-upload-date request, and a channel's uploads tab
    is newest-first already, so this is newest-first within the fetched batch
    by approximate upload time. Stable, so ties keep YouTube's own order;
    undated entries sort last."""
    if sort == "views":
        return sorted(entries, key=lambda e: e.get("view_count") or 0, reverse=True)
    if sort == "date":
        return sorted(entries, key=lambda e: _entry_upload_epoch(e) or 0, reverse=True)
    return entries


def _search_youtube(query: str, limit: int, sort: str, duration: str, upload_date: str) -> dict:
    """Blocking (network I/O); always call via asyncio.to_thread.

    duration/upload_date (and sort=views) are applied by YouTube itself via
    sp, so exactly `limit` results are all this needs to ask for. It asks
    for one more than that purely to answer "is there more" without
    ambiguity: getting back exactly `limit` entries is consistent with both
    "that's every result there is" and "there's more, we just didn't ask
    for it". The extra entry (never returned to the caller) settles which."""
    opts = {**_FLAT_OPTS, "playlistend": limit + 1}
    url = _search_url(query, _search_sp(sort, duration, upload_date))
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False, ie_key="YoutubeSearchURL")
    raw_entries = [e for e in (info.get("entries") or []) if e]

    entries = _sort_entries([e for e in raw_entries[:limit] if _is_playable(e)], sort)
    return {
        "results": [_entry_to_result(e) for e in entries],
        # A larger limit past the cap would be clamped back down to this
        # same request, so "load more" would never show anything new.
        "hasMore": len(raw_entries) > limit and limit < _SEARCH_MAX_RESULTS,
    }


def _channel_videos(channel_id: str, limit: int, sort: str, duration: str, upload_date: str) -> dict:
    """Blocking (network I/O); always call via asyncio.to_thread.
    channel_id is already validated by the caller.

    A duration/upload_date filter can only narrow what gets fetched, so
    asking for exactly `limit` uploads and filtering after would usually
    leave far fewer than wanted; this over-fetches a bounded multiple
    instead while a filter is active. Same "+1" trick as _search_youtube
    for hasMore."""
    filters_active = duration != "any" or upload_date != "any"
    fetch_count = min(limit * 4, _CHANNEL_MAX_ENTRIES) if filters_active else limit

    opts = {**_FLAT_OPTS, "playliststart": 1, "playlistend": fetch_count + 1}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(_channel_url(channel_id), download=False)
    raw_entries = [e for e in (info.get("entries") or []) if e]

    now = time.time()
    matching = _sort_entries(
        [e for e in raw_entries[:fetch_count] if _is_playable(e) and _matches_filters(e, duration, upload_date, now)],
        sort,
    )
    return {
        "channelName": info.get("channel") or info.get("uploader") or info.get("title") or "",
        "results": [_entry_to_result(e) for e in matching[:limit]],
        # More to show if this fetch already found more matches than fit in
        # `limit`, or if a bigger limit would reach further into the channel
        # than this fetch did (it can't once fetch_count hits the cap).
        "hasMore": len(matching) > limit
        or (len(raw_entries) > fetch_count and fetch_count < _CHANNEL_MAX_ENTRIES),
    }


def _download_for_stream(video_id: str) -> Path:
    """Downloads the best audio-only format to _STREAM_CACHE_DIR (or reuses
    an already-cached copy), so /api/stream can serve a real file; needed
    for Range/seeking support; see the module docstring. video_id is already
    validated by the caller, so the glob below can't escape the cache dir."""
    # p.stem strips exactly one suffix, so this matches "<id>.webm" but not
    # an interrupted download's "<id>.webm.part" (stem "<id>.webm") or
    # "<id>.ytdl" resume-metadata sidecar left behind by a killed container
    # mid-download, either of which the plain glob below would otherwise
    # treat as a complete, cached file.
    existing = [p for p in _STREAM_CACHE_DIR.glob(f"{video_id}.*") if p.stem == video_id]
    if existing:
        return existing[0]

    opts = {
        **_BASE_OPTS,
        "format": "bestaudio/best",
        "outtmpl": str(_STREAM_CACHE_DIR / f"{video_id}.%(ext)s"),
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(_video_url(video_id), download=True)
    ext = info.get("ext", "webm")
    return _STREAM_CACHE_DIR / f"{video_id}.{ext}"


@app.get("/api/health")
async def health():
    return {"status": "ok"}


@app.get("/api/version")
async def version():
    # Lets the homepage dashboard check yt-dlp's version over plain HTTP
    # instead of `docker exec`-ing into this container — see homepage's
    # docker_monitor.py and README.md security model for why avoiding that
    # matters (exec is a meaningfully bigger capability than the read-only
    # status/start/stop the dashboard otherwise needs from the Docker API).
    return {"yt_dlp_version": yt_dlp.version.__version__}


@app.get("/api/search")
async def search(
    q: str = Query(..., min_length=1),
    limit: int = SEARCH_RESULT_LIMIT,
    sort: Literal["relevance", "date", "views"] = "relevance",
    duration: Literal["any", "short", "medium", "long"] = "any",
    upload_date: Literal["any", "hour", "today", "week", "month", "year"] = "any",
):
    # YoutubeDLError, not just its DownloadError subclass: yt-dlp raises
    # other subclasses too (e.g. a networking error for a URL it no longer
    # supports), and those used to surface as a bare, unexplained 500.
    try:
        data = await asyncio.to_thread(
            _search_youtube, q, max(1, min(limit, _SEARCH_MAX_RESULTS)), sort, duration, upload_date
        )
    except yt_dlp.utils.YoutubeDLError as exc:
        raise HTTPException(status_code=502, detail=f"YouTube search failed: {exc}")
    return data


@app.get("/api/channel/{channel_id}")
async def channel_videos(
    channel_id: str = PathParam(..., min_length=24, max_length=24),
    limit: int = 30,
    sort: Literal["relevance", "date", "views"] = "relevance",
    duration: Literal["any", "short", "medium", "long"] = "any",
    upload_date: Literal["any", "hour", "today", "week", "month", "year"] = "any",
):
    channel_id = _validate_channel_id(channel_id)
    try:
        data = await asyncio.to_thread(
            _channel_videos, channel_id, max(1, min(limit, _CHANNEL_MAX_ENTRIES)), sort, duration, upload_date
        )
    except yt_dlp.utils.YoutubeDLError as exc:
        raise HTTPException(status_code=502, detail=f"Could not load channel: {exc}")
    return data


@app.get("/api/stream/{video_id}")
async def stream(video_id: str = PathParam(..., min_length=11, max_length=11)):
    video_id = _validate_video_id(video_id)

    try:
        path = await asyncio.to_thread(_download_for_stream, video_id)
    except yt_dlp.utils.DownloadError as exc:
        raise HTTPException(status_code=404, detail=f"Video unavailable: {exc}")

    media_type = _EXT_MIME.get(path.suffix.lstrip("."), "application/octet-stream")
    # FileResponse handles Range/If-Range/Accept-Ranges itself; this is the
    # actual seeking fix; a piped subprocess (the old approach) has no bytes
    # to seek within, only ones already flushed to the socket.
    return FileResponse(path, media_type=media_type)


async def _download_to_library(video_id: str) -> None:
    """Runs in a thread (see the endpoint below). Reports progress into
    _SAVE_PROGRESS via yt-dlp's own progress_hooks so /api/save/{id}/status
    has something to poll; a plain synchronous download+return gave the
    frontend no way to show a progress bar or distinguish "still working"
    from "hung"."""
    def hook(d):
        if d.get("status") == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            downloaded = d.get("downloaded_bytes", 0)
            percent = (downloaded / total * 100) if total else None
            with _SAVE_PROGRESS_LOCK:
                _SAVE_PROGRESS[video_id] = {"status": "downloading", "percent": percent, "error": None}
        elif d.get("status") == "finished":
            # Download itself is done; FFmpegExtractAudio (mp3 re-encode)
            # still runs after this hook fires, so not "done" quite yet.
            with _SAVE_PROGRESS_LOCK:
                _SAVE_PROGRESS[video_id] = {"status": "processing", "percent": None, "error": None}

    def _download() -> str:
        opts = {
            **_BASE_OPTS,
            "format": "bestaudio/best",
            "outtmpl": str(MUSIC_SAVE_PATH / "%(uploader)s - %(title)s.%(ext)s"),
            "postprocessors": [{
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "192",
            }],
            "progress_hooks": [hook],
        }
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(_video_url(video_id), download=True)
        return info.get("title", video_id)

    try:
        title = await asyncio.to_thread(_download)
        with _SAVE_PROGRESS_LOCK:
            _SAVE_PROGRESS[video_id] = {"status": "done", "percent": 100.0, "title": title, "error": None}
    except yt_dlp.utils.DownloadError as exc:
        with _SAVE_PROGRESS_LOCK:
            _SAVE_PROGRESS[video_id] = {"status": "error", "percent": None, "error": str(exc)}


@app.post("/api/save/{video_id}", dependencies=[Depends(require_token)])
async def save_to_library(video_id: str = PathParam(..., min_length=11, max_length=11)):
    video_id = _validate_video_id(video_id)

    if not DOWNLOAD_ENABLED:
        raise HTTPException(
            status_code=403,
            detail="Saving to the library is disabled (set DOWNLOAD_ENABLED=true in .env)",
        )
    if not MUSIC_SAVE_PATH.is_dir():
        raise HTTPException(status_code=500, detail=f"{MUSIC_SAVE_PATH} is not mounted")

    with _SAVE_PROGRESS_LOCK:
        current = _SAVE_PROGRESS.get(video_id)
        if current and current["status"] in ("downloading", "processing"):
            return {"started": False, "detail": "Already downloading"}
        _SAVE_PROGRESS[video_id] = {"status": "downloading", "percent": 0.0, "error": None}

    # Fire-and-forget: the frontend polls /status for progress instead of
    # waiting on this request, so it can show a progress bar and let the
    # user keep browsing/playing while a save runs. _background_tasks holds
    # a reference so the task can't be garbage-collected mid-download (a
    # real risk for a task nothing else references; see asyncio's own
    # docs on this).
    task = asyncio.ensure_future(_download_to_library(video_id))
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)

    return {"started": True}


@app.get("/api/save/{video_id}/status")
async def save_status(video_id: str = PathParam(..., min_length=11, max_length=11)):
    video_id = _validate_video_id(video_id)
    with _SAVE_PROGRESS_LOCK:
        state = _SAVE_PROGRESS.get(video_id)
    if not state:
        return {"status": "idle", "percent": None, "error": None}
    return state


# A POST that mutates state on disk, same threat model as /api/save above
# (a malicious webpage's blind cross-origin POST, a "simple request" CORS
# does nothing to stop): gated behind the same token rather than left open
# like the read-only /api/search and /api/stream.
@app.post("/api/playcount/{source}/{track_id}", dependencies=[Depends(require_token)])
async def record_play(source: Literal["local", "youtube"], track_id: str, meta: PlayMeta | None = None):
    track_id = _validate_track_id(source, track_id)
    key = f"{source}:{track_id}"
    with _PLAY_COUNTS_LOCK:
        entry = _play_counts.get(key, {"count": 0})
        entry["count"] = entry.get("count", 0) + 1
        if source == "youtube" and meta:
            if meta.title:
                entry["title"] = meta.title
            if meta.artist:
                entry["artist"] = meta.artist
            if meta.thumbnail:
                entry["thumbnail"] = meta.thumbnail
        _play_counts[key] = entry
        _save_play_counts()
    return {"count": entry["count"]}


@app.get("/api/playcount/top")
async def top_play_counts(limit: int = 20, source: Literal["local", "youtube", "all"] = "all"):
    with _PLAY_COUNTS_LOCK:
        items = list(_play_counts.items())

    results = []
    for key, entry in items:
        entry_source, _, track_id = key.partition(":")
        if source != "all" and entry_source != source:
            continue
        results.append({
            "source": entry_source,
            "id": track_id,
            "count": entry.get("count", 0),
            "title": entry.get("title"),
            "artist": entry.get("artist"),
            "thumbnail": entry.get("thumbnail"),
        })
    results.sort(key=lambda r: r["count"], reverse=True)
    return {"results": results[: max(1, min(limit, 200))]}


# ── Discover: not implemented yet ───────────────────────────────────────
# Scaffolding only, matching frontend/src/app.js's Discover section and
# README.md's Discover section. Two real algorithms are meant to sit behind
# this, neither implemented here:
#
#   1. Raw audio analysis: run each library track through a model that
#      estimates its acoustic properties directly from the waveform (tempo,
#      key, mood/valence-arousal), the way Spotify's own audio features API
#      works. Output would be one small feature vector per track, cached
#      somewhere durable (not recomputed on every request) so this only
#      needs to run once per track, not once per page load.
#   2. Annoy (Approximate Nearest Neighbor library, from Spotify) built over
#      those feature vectors, so "songs similar to this one" becomes a
#      nearest-neighbor lookup in that vector space instead of a raw
#      metadata match (same artist/genre tag). This is what actually powers
#      a "similar tracks" or "browse by mood" experience instead of just
#      browsing by artist/album.
#
# Both are CPU-heavy enough on a Pi that they must stay something the user
# explicitly starts (POST /api/discover/analyze), never something that runs
# automatically off a library scan or a schedule; see README.md's Discover
# section for the resource-cost reasoning. Every endpoint below is a stub:
# no model is loaded, no vectors are built, no analysis runs.

@app.post("/api/discover/analyze", dependencies=[Depends(require_token)])
async def discover_start_analysis():
    """Would kick off the audio-analysis + Annoy-index-build pass over the
    whole library, as a background job (this WILL take minutes to hours on a
    Pi, so it cannot be a request/response cycle). Not implemented."""
    raise HTTPException(status_code=501, detail="Discover is not implemented yet")


@app.get("/api/discover/status")
async def discover_status():
    """Would report whether an analysis run is in progress, finished, or has
    never run, plus progress (tracks analyzed / total). Not implemented."""
    return {"state": "not_implemented", "progress": None}


@app.get("/api/discover/similar/{track_id}")
async def discover_similar(track_id: str):
    """Would return the nearest neighbors of track_id in the Annoy index
    built by discover_start_analysis. Not implemented."""
    raise HTTPException(status_code=501, detail="Discover is not implemented yet")
