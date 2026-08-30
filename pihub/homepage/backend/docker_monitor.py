"""Docker Engine API access — container status, start/stop/restart, logs,
and a best-effort "is a newer image available" check.

Security note on Docker access: this module never touches the raw socket at
all. DOCKER_HOST (see ../docker-compose.yml) points docker-py at
docker-proxy, a tecnativa/docker-socket-proxy sidecar that holds the actual
mounted socket and only forwards the specific endpoints this file needs
(container list/inspect/start/stop/restart/logs, image inspect, registry
manifest lookups) — EXEC is explicitly off, since nothing here calls it
(pitune-backend exposes its own yt-dlp version over HTTP instead — see
system_stats.py). That's the real boundary against a bug or a compromised
dependency in this process turning into arbitrary access to the host: even
full control of this container only gets you what the proxy forwards, not
the whole Docker API.

A second, narrower boundary still applies on top: every function below
takes a container name that main.py has already resolved against
config/services.yml's fixed registry — this module never accepts an
arbitrary name typed into an HTTP request, regardless of what the proxy
would otherwise allow.
"""

import asyncio
import logging
import time
from typing import Optional

import docker
from docker.errors import DockerException, ImageNotFound, NotFound
from requests.exceptions import RequestException

logger = logging.getLogger("homepage.docker_monitor")

# Created lazily, not at import time: if the docker socket isn't reachable
# yet, this process should still come up and answer everything that doesn't
# need it (system stats, serving the frontend) — only the docker-dependent
# calls need to fail.
_client: Optional[docker.DockerClient] = None


def _get_client() -> docker.DockerClient:
    global _client
    if _client is None:
        try:
            _client = docker.from_env()
        except DockerException as exc:
            raise RuntimeError(f"Docker socket unavailable: {exc}") from exc
    return _client


def _status_sync(name: str) -> dict:
    try:
        c = _get_client().containers.get(name)
    except NotFound:
        # Exactly what you get when a bind mount refused to start the
        # container (a missing media drive, say) or it's simply never been
        # started — surfaced as data, not an error, so the dashboard shows
        # "not found" instead of failing the whole request.
        return {"container": name, "state": "not_found", "health": None, "started_at": None}
    except (RuntimeError, RequestException) as exc:
        return {"container": name, "state": "error", "health": None, "started_at": None, "detail": str(exc)}

    state = c.attrs.get("State", {})
    health = state.get("Health", {}).get("Status")
    return {
        "container": name,
        "state": state.get("Status", "unknown"),
        "health": health,
        "started_at": state.get("StartedAt"),
    }


async def container_status(name: str) -> dict:
    # docker-py is fully synchronous (it's `requests` underneath) — every
    # call blocks, so it always runs off the event loop. A hard timeout on
    # top means one hung docker call can't freeze this endpoint forever.
    try:
        return await asyncio.wait_for(asyncio.to_thread(_status_sync, name), timeout=5.0)
    except asyncio.TimeoutError:
        return {"container": name, "state": "error", "health": None, "started_at": None, "detail": "docker call timed out"}


def aggregate_states(statuses: list) -> str:
    states = {s["state"] for s in statuses}
    if states == {"running"}:
        return "degraded" if any(s["health"] == "unhealthy" for s in statuses) else "running"
    if "error" in states or "not_found" in states:
        return "error"
    if states <= {"exited", "created"}:
        # A container a human (or the CLI) deliberately stopped looks
        # exactly like this — Docker doesn't distinguish "stopped on
        # purpose" from "crashed and gave up retrying" in its state string,
        # so neither do we. See main.py for how HTTP health results are
        # layered on top without confusing the two.
        return "stopped"
    return "partial"


def _act_one_sync(name: str, action: str) -> dict:
    try:
        container = _get_client().containers.get(name)
        getattr(container, action)()
        return {"container": name, "ok": True}
    except NotFound:
        return {"container": name, "ok": False, "detail": "container not found"}
    except (RuntimeError, RequestException) as exc:
        return {"container": name, "ok": False, "detail": str(exc)}


async def act(containers: list, action: str) -> list:
    # Independent containers act in parallel, not one after another —
    # matters most for PiTune's three-container start/stop/restart.
    return list(await asyncio.gather(
        *(asyncio.to_thread(_act_one_sync, name, action) for name in containers)
    ))


def _logs_sync(name: str, lines: int) -> bytes:
    c = _get_client().containers.get(name)
    return c.logs(tail=lines, timestamps=True)


async def get_logs(name: str, lines: int = 200) -> list:
    log_bytes = await asyncio.to_thread(_logs_sync, name, lines)
    return log_bytes.decode("utf-8", errors="replace").splitlines()


def _get_container_image_sync(name: str) -> Optional[str]:
    try:
        container = _get_client().containers.get(name)
    except NotFound:
        return None
    except (RuntimeError, RequestException):
        return None
    # The tag the container was actually created from (e.g.
    # "deluan/navidrome:latest") — what get_registry_data() needs, not the
    # resolved image ID.
    tags = container.attrs.get("Config", {}).get("Image")
    return tags or None


async def get_container_image(name: str) -> Optional[str]:
    return await asyncio.to_thread(_get_container_image_sync, name)


# ── Image update check ────────────────────────────────────────────────────
# On-demand only — never part of the fast poll loop — and cached for an
# hour, since this hits the actual image registry over the network for
# every service checked. Fine occasionally; would get you rate-limited by
# Docker Hub if it ran on the same 10-15s cadence as everything else.
_update_cache: dict = {}
_UPDATE_CACHE_SECONDS = 3600


def _check_update_sync(image_ref: str) -> dict:
    client = _get_client()
    try:
        local = client.images.get(image_ref)
    except ImageNotFound:
        return {"checked": False, "detail": f"local image {image_ref} not found"}
    except RequestException as exc:
        return {"checked": False, "detail": str(exc)}

    try:
        remote = client.images.get_registry_data(image_ref)
    except (DockerException, RequestException) as exc:
        return {"checked": False, "detail": f"registry unreachable: {exc}"}

    local_digests = local.attrs.get("RepoDigests") or []
    # remote.id is the manifest digest the registry advertises for this tag
    # right now — comparing it against what's already pulled answers
    # "is latest actually still what I'm running" without a real `docker
    # pull` (and without needing to store any history ourselves).
    up_to_date = any(remote.id in d for d in local_digests) if local_digests else None
    return {"checked": True, "up_to_date": up_to_date, "remote_digest": remote.id}


async def check_update(image_ref: str) -> dict:
    now = time.time()
    cached = _update_cache.get(image_ref)
    if cached and now - cached[0] < _UPDATE_CACHE_SECONDS:
        return {**cached[1], "cached": True}
    result = await asyncio.to_thread(_check_update_sync, image_ref)
    _update_cache[image_ref] = (now, result)
    return {**result, "cached": False}
