"""CPU, RAM, disk, temperature and uptime for the Pi itself, plus the two
update checks that don't belong in the fast poll loop: yt-dlp's version and
Docker image freshness (the latter lives in docker_monitor.py).
"""

import asyncio
import os
import re
import shutil
import time
from pathlib import Path
from typing import Optional

import httpx
import psutil

# Host /proc and the thermal zone are bind-mounted read-only (see
# ../docker-compose.yml) specifically so CPU%/RAM/uptime describe the Pi
# itself, not this container's own much-shorter-lived view. This is the
# same pattern node_exporter and similar monitoring sidecars use.
HOST_PROC = Path("/host/proc")
HOST_THERMAL = Path("/host/thermal/thermal_zone0/temp")
if HOST_PROC.is_dir():
    psutil.PROCFS_PATH = str(HOST_PROC)

MEDIA_PATH = Path(os.environ.get("MEDIA_PATH", "/media"))
# Read-only host-root mount, present only so shutil.disk_usage() can report
# boot-drive space — it never reads file contents, only filesystem-level
# stat, which keeps this narrower than it might look. See docker-compose.yml.
BOOT_PATH = Path("/hostroot")

_YTDLP_VERSION_RE = re.compile(r"^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$")


def _disk_usage(path: Path) -> Optional[dict]:
    if not path.is_dir():
        return None
    usage = shutil.disk_usage(path)
    percent = round(usage.used / usage.total * 100, 1) if usage.total else None
    return {"total": usage.total, "used": usage.used, "free": usage.free, "percent": percent}


async def get_stats() -> dict:
    cpu_temp_c = None
    if HOST_THERMAL.is_file():
        try:
            cpu_temp_c = int(HOST_THERMAL.read_text().strip()) / 1000.0
        except (ValueError, OSError):
            pass

    vm = psutil.virtual_memory()
    boot_time = psutil.boot_time()
    uptime_seconds = max(0.0, time.time() - boot_time) if boot_time else None

    # cpu_percent's interval blocks for its full duration measuring a real
    # sample — on a single-threaded event loop that would otherwise freeze
    # every other request (a start/stop click included) for 200ms on every
    # single stats poll.
    cpu_percent = await asyncio.to_thread(psutil.cpu_percent, 0.2)

    disks = {}
    media = _disk_usage(MEDIA_PATH)
    if media:
        disks["media"] = media
    boot = _disk_usage(BOOT_PATH)
    if boot:
        disks["boot"] = boot

    return {
        "cpu_percent": cpu_percent,
        "cpu_temp_c": cpu_temp_c,
        "ram": {"total": vm.total, "used": vm.used, "percent": vm.percent},
        "disks": disks,
        "uptime_seconds": uptime_seconds,
    }


# ── yt-dlp version check ──────────────────────────────────────────────────
# On-demand/cached, same reasoning as docker_monitor's image-update check:
# this calls out to PyPI, so it has no business running every 10 seconds.
_ytdlp_cache: Optional[tuple] = None
_YTDLP_CACHE_SECONDS = 3600


async def _fetch_latest_ytdlp_version() -> Optional[str]:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get("https://pypi.org/pypi/yt-dlp/json")
        resp.raise_for_status()
        return resp.json()["info"]["version"]
    except (httpx.HTTPError, KeyError, ValueError):
        return None


async def _fetch_current_ytdlp_version(health_url: str) -> Optional[str]:
    # Plain HTTP to pitune-backend's own /api/version, NOT `docker exec` —
    # deliberately, so the Docker socket this whole process talks to never
    # needs the exec capability at all (see docker-compose.yml's
    # docker-socket-proxy and its EXEC=0). Every other check here (Docker
    # state, HTTP health) is already read-only from Docker's point of view;
    # exec is a meaningfully bigger capability than any of those, and this
    # was the one thing motivating it.
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{health_url.rstrip('/')}/api/version")
        resp.raise_for_status()
        version = resp.json().get("yt_dlp_version")
        return version if version and _YTDLP_VERSION_RE.match(version) else version
    except (httpx.HTTPError, KeyError, ValueError):
        return None


async def check_ytdlp_version(health_url: str) -> dict:
    global _ytdlp_cache
    now = time.time()
    if _ytdlp_cache and now - _ytdlp_cache[0] < _YTDLP_CACHE_SECONDS:
        return {**_ytdlp_cache[1], "cached": True}

    current = await _fetch_current_ytdlp_version(health_url)
    latest = await _fetch_latest_ytdlp_version()
    result = {
        "current": current,
        "latest": latest,
        "outdated": bool(current and latest and current != latest),
    }
    _ytdlp_cache = (now, result)
    return {**result, "cached": False}
