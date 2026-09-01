"""PiMonitor: the dashboard's monitoring section, beyond the always-on
system stats in system_stats.py.

Two tiers, matching the frontend's default/advanced split:
  - Drive: mounted media drive usage/health. Cheap, always safe to poll.
  - File activity + user activity ("advanced"): walks the media library and
    calls out to Navidrome/Jellyfin's own APIs. Heavier and mildly
    sensitive (filenames, usernames), so callers go through require_token
    the same way service logs already do; see main.py.

Every check here degrades independently, same philosophy as the rest of
this backend: a service that isn't configured or isn't running just reports
"not configured"/"unreachable", never a 500 that takes the rest of the
dashboard down with it.
"""

import asyncio
import hashlib
import os
import random
import string
import time
from pathlib import Path
from typing import Optional

import httpx

LIBRARY_PATH = Path(os.environ.get("LIBRARY_PATH", "/library"))

# ── Drive ──────────────────────────────────────────────────────────────
# Deliberately no SMART data here: reading it needs privileged access to
# the raw block device (CAP_SYS_RAWIO plus the device node itself), a much
# bigger grant than anything else this container asks for. Check it
# directly on the host instead: `sudo smartctl -a /dev/sdX`.


def get_drive_health() -> dict:
    if not LIBRARY_PATH.is_dir():
        return {"available": False, "path": str(LIBRARY_PATH)}
    usage = os.statvfs(LIBRARY_PATH)
    total = usage.f_frsize * usage.f_blocks
    free = usage.f_frsize * usage.f_bavail
    used = total - free
    return {
        "available": True,
        "path": str(LIBRARY_PATH),
        "total": total,
        "used": used,
        "free": free,
        "percent": round(used / total * 100, 1) if total else None,
    }


# ── File activity ─────────────────────────────────────────────────────
# A snapshot (current sizes/counts, most-recently-modified files), not a
# stateful add/remove diff across runs: that needs durable state to
# survive a container restart, which is more machinery than "what's been
# happening in the library lately" needs to justify. Time- and count-boxed
# so a multi-terabyte library can't turn one dashboard poll into a
# multi-minute walk.
_SCAN_MAX_FILES = int(os.environ.get("MONITOR_SCAN_MAX_FILES", "200000"))
_SCAN_TIMEOUT_SECONDS = float(os.environ.get("MONITOR_SCAN_TIMEOUT", "20"))
_RECENT_COUNT = 15
_CACHE_SECONDS = int(os.environ.get("MONITOR_SCAN_CACHE_SECONDS", "600"))

_file_activity_cache: Optional[tuple] = None  # (timestamp, result)


def _scan_library() -> dict:
    start = time.monotonic()
    per_folder: dict = {}
    recent: list = []
    scanned = 0
    truncated = False

    if not LIBRARY_PATH.is_dir():
        return {"available": False, "path": str(LIBRARY_PATH)}

    for root, dirs, files in os.walk(LIBRARY_PATH):
        if time.monotonic() - start > _SCAN_TIMEOUT_SECONDS or scanned >= _SCAN_MAX_FILES:
            truncated = True
            break
        rel_root = Path(root).relative_to(LIBRARY_PATH)
        top = rel_root.parts[0] if rel_root.parts else None

        for name in files:
            if scanned >= _SCAN_MAX_FILES:
                truncated = True
                break
            path = Path(root) / name
            try:
                st = path.stat()
            except OSError:
                continue
            scanned += 1

            if top:
                bucket = per_folder.setdefault(top, {"files": 0, "bytes": 0})
                bucket["files"] += 1
                bucket["bytes"] += st.st_size

            rel_path = str((rel_root / name)) if rel_root.parts else name
            recent.append((st.st_mtime, rel_path, st.st_size))

    # Only the most recent _RECENT_COUNT need to survive; sorting the whole
    # (potentially 200k-entry) list every scan is wasted work beyond that.
    recent.sort(key=lambda t: t[0], reverse=True)
    recent = recent[:_RECENT_COUNT]

    return {
        "available": True,
        "path": str(LIBRARY_PATH),
        "scanned_files": scanned,
        "truncated": truncated,
        "by_folder": per_folder,
        "recent": [
            {"path": p, "modified": m, "size": s} for m, p, s in recent
        ],
        "scan_seconds": round(time.monotonic() - start, 2),
    }


async def get_file_activity(force_rescan: bool = False) -> dict:
    global _file_activity_cache
    now = time.time()
    if not force_rescan and _file_activity_cache and now - _file_activity_cache[0] < _CACHE_SECONDS:
        return {**_file_activity_cache[1], "cached": True}

    # os.walk + stat is blocking I/O; keep it off the event loop the same
    # way system_stats.get_stats() does for psutil.cpu_percent's sample.
    result = await asyncio.to_thread(_scan_library)
    _file_activity_cache = (now, result)
    return {**result, "cached": False}


# ── User activity ────────────────────────────────────────────────────
# Jellyfin: an API key (Dashboard → API Keys) authorizes /Sessions, which
# lists current playback across every user. Navidrome: Subsonic's own
# getNowPlaying.view, authenticated the same salted-token way the PiTune
# frontend already does (see pitune/frontend/src/app.js's Subsonic client).
# A dedicated, non-admin Navidrome account is the intended credential here,
# not your own login.

JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "http://jellyfin:8096")
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "").strip()
NAVIDROME_URL = os.environ.get("NAVIDROME_URL", "http://navidrome:4533")
NAVIDROME_MONITOR_USER = os.environ.get("NAVIDROME_MONITOR_USER", "").strip()
NAVIDROME_MONITOR_PASSWORD = os.environ.get("NAVIDROME_MONITOR_PASSWORD", "").strip()


async def _jellyfin_sessions() -> dict:
    if not JELLYFIN_API_KEY:
        return {"configured": False}
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                f"{JELLYFIN_URL}/Sessions",
                headers={"X-Emby-Token": JELLYFIN_API_KEY},
            )
        resp.raise_for_status()
        sessions = resp.json()
    except (httpx.HTTPError, ValueError):
        return {"configured": True, "reachable": False}

    playing = []
    for s in sessions:
        item = s.get("NowPlayingItem")
        if not item:
            continue
        playing.append({
            "user": s.get("UserName"),
            "client": s.get("Client"),
            "device": s.get("DeviceName"),
            "title": item.get("Name"),
            "type": item.get("Type"),
        })
    return {"configured": True, "reachable": True, "now_playing": playing}


def _subsonic_auth_params() -> dict:
    salt = "".join(random.choices(string.ascii_lowercase + string.digits, k=8))
    token = hashlib.md5((NAVIDROME_MONITOR_PASSWORD + salt).encode("utf-8")).hexdigest()
    return {
        "u": NAVIDROME_MONITOR_USER, "t": token, "s": salt,
        "v": "1.16.1", "c": "pimonitor", "f": "json",
    }


async def _navidrome_now_playing() -> dict:
    if not (NAVIDROME_MONITOR_USER and NAVIDROME_MONITOR_PASSWORD):
        return {"configured": False}
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                f"{NAVIDROME_URL}/rest/getNowPlaying.view",
                params=_subsonic_auth_params(),
            )
        resp.raise_for_status()
        body = resp.json().get("subsonic-response", {})
    except (httpx.HTTPError, ValueError):
        return {"configured": True, "reachable": False}

    if body.get("status") != "ok":
        # Wrong credentials, most likely; surfaced as unreachable rather
        # than raising, same "degrade, don't 500" rule as everything else
        # in this module.
        return {"configured": True, "reachable": False}

    entries = (body.get("nowPlaying") or {}).get("entry") or []
    playing = [
        {"user": e.get("username"), "title": e.get("title"), "artist": e.get("artist")}
        for e in entries
    ]
    return {"configured": True, "reachable": True, "now_playing": playing}


async def get_user_activity() -> dict:
    jellyfin, navidrome = await asyncio.gather(_jellyfin_sessions(), _navidrome_now_playing())
    return {"jellyfin": jellyfin, "navidrome": navidrome}
