"""PiHub management API — start/stop/restart PiHub's service groups and
report basic system stats, via the Docker Engine API.

Security note on the docker socket: mounting it `read_only: true` in compose
(see ../../docker-compose.yml) only stops this container from deleting or
replacing the socket FILE — it does not restrict what you can do over the
connection once opened. There is no "read-only mode" for the Docker API
itself; full access to the socket is equivalent to root on the host. The
actual boundary here is at the application layer instead: every operation
below is looked up against SERVICES, a fixed, hardcoded allow-list, by a
short `id` string — this API never accepts a raw container name, image, or
shell command from a caller. If this ever needs to serve more than one
trusted person on a home LAN, put a filtering proxy such as
tecnativa/docker-socket-proxy in front of the socket instead of trusting this
allow-list alone.
"""

import logging
import os
import shutil
import time
from pathlib import Path
from typing import Optional

import docker
import psutil
from docker.errors import APIError, NotFound
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

logger = logging.getLogger("pihub.management-api")
logging.basicConfig(level=logging.INFO)

CORS_ORIGINS = [o.strip() for o in os.environ.get("CORS_ORIGINS", "*").split(",") if o.strip()]
MEDIA_PATH = Path(os.environ.get("MEDIA_PATH", "/media"))

# Host /proc and the thermal zone are bind-mounted read-only (see
# docker-compose.yml) specifically so CPU%, RAM and uptime describe the Pi
# itself rather than this container's own, much shorter-lived, view. Without
# this, psutil would read the container's own /proc — this is the same
# pattern node_exporter and similar monitoring sidecars use.
HOST_PROC = Path("/host/proc")
HOST_THERMAL = Path("/host/thermal/thermal_zone0/temp")
if HOST_PROC.is_dir():
    psutil.PROCFS_PATH = str(HOST_PROC)

# The fixed set of things this API will ever touch. Adding a future service
# (Immich, Pi-hole, Uptime Kuma, ...) means adding one entry here and one
# profile block in docker-compose.yml — nothing else in this file changes.
SERVICES = [
    {
        "id": "pitune",
        "label": "PiTune",
        "description": "Local music library (Navidrome) + YouTube audio streaming",
        "containers": ["pihub-navidrome", "pihub-pitune-backend", "pihub-pitune-frontend"],
        "url": "/pitune/",
        "manageable": True,
    },
    {
        "id": "jellyfin",
        "label": "Jellyfin",
        "description": "Video, movie and TV show library",
        "containers": ["pihub-jellyfin"],
        "url": "/jellyfin/",
        "manageable": True,
    },
    {
        "id": "core",
        "label": "PiHub core",
        "description": "Reverse proxy, dashboard and this API — always on, not stoppable from here",
        "containers": ["pihub-nginx", "pihub-dashboard", "pihub-management-api", "pihub-autoheal"],
        "url": "/dashboard/",
        "manageable": False,
    },
]
_SERVICES_BY_ID = {s["id"]: s for s in SERVICES}

app = FastAPI(title="PiHub management API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Created lazily, not at import time: if the docker socket isn't reachable
# yet (any hiccup in the bind mount, an unlucky restart order), this API
# server should still come up and answer /api/health and /api/system/stats —
# only the docker-dependent endpoints need to fail, not the whole process.
_docker_client = None


def _docker() -> docker.DockerClient:
    global _docker_client
    if _docker_client is None:
        try:
            _docker_client = docker.from_env()
        except docker.errors.DockerException as exc:
            raise HTTPException(status_code=503, detail=f"Docker socket unavailable: {exc}")
    return _docker_client


def _lookup(service_id: str) -> dict:
    service = _SERVICES_BY_ID.get(service_id)
    if not service:
        raise HTTPException(status_code=404, detail=f"Unknown service '{service_id}'")
    return service


def _container_status(name: str) -> dict:
    try:
        c = _docker().containers.get(name)
    except NotFound:
        # Exactly what happens when the media drive was missing at
        # `docker compose up` time (create_host_path: false refuses to start
        # the container at all) or the service has simply never been
        # started. Surfaced as ordinary data, not a 500, so the dashboard
        # shows "not found" instead of the request itself failing.
        return {"container": name, "state": "not_found", "health": None}
    except APIError as exc:
        return {"container": name, "state": "error", "health": None, "detail": str(exc)}

    state = c.attrs.get("State", {})
    health = state.get("Health", {}).get("Status")
    return {"container": name, "state": state.get("Status", "unknown"), "health": health}


def _aggregate(statuses: list) -> str:
    states = {s["state"] for s in statuses}
    if states == {"running"}:
        return "degraded" if any(s["health"] == "unhealthy" for s in statuses) else "running"
    if "error" in states or "not_found" in states:
        return "error"
    if states <= {"exited", "created"}:
        return "stopped"
    return "partial"


@app.get("/api/health")
async def health():
    return {"status": "ok"}


@app.get("/api/services")
async def list_services():
    out = []
    for service in SERVICES:
        statuses = [_container_status(name) for name in service["containers"]]
        out.append({
            "id": service["id"],
            "label": service["label"],
            "description": service["description"],
            "url": service["url"],
            "manageable": service["manageable"],
            "status": _aggregate(statuses),
            "containers": statuses,
        })
    return {"services": out}


def _act(service_id: str, action: str) -> dict:
    service = _lookup(service_id)
    if not service["manageable"]:
        raise HTTPException(
            status_code=403,
            detail=f"'{service_id}' is core infrastructure and can't be controlled from here",
        )

    results = []
    for name in service["containers"]:
        try:
            container = _docker().containers.get(name)
            getattr(container, action)()
            results.append({"container": name, "ok": True})
        except NotFound:
            results.append({"container": name, "ok": False, "detail": "container not found"})
        except APIError as exc:
            results.append({"container": name, "ok": False, "detail": str(exc)})
    return {"service": service_id, "action": action, "results": results}


@app.post("/api/services/{service_id}/start")
async def start_service(service_id: str):
    return _act(service_id, "start")


@app.post("/api/services/{service_id}/stop")
async def stop_service(service_id: str):
    return _act(service_id, "stop")


@app.post("/api/services/{service_id}/restart")
async def restart_service(service_id: str):
    return _act(service_id, "restart")


@app.get("/api/services/{service_id}/logs")
async def service_logs(
    service_id: str,
    lines: int = Query(200, ge=1, le=2000),
    container: Optional[str] = None,
):
    service = _lookup(service_id)
    name = container if container in service["containers"] else service["containers"][0]
    try:
        c = _docker().containers.get(name)
        log_bytes = c.logs(tail=lines, timestamps=True)
    except NotFound:
        raise HTTPException(status_code=404, detail=f"Container '{name}' not found")
    except APIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    return {"container": name, "lines": log_bytes.decode("utf-8", errors="replace").splitlines()}


@app.get("/api/system/stats")
async def system_stats():
    cpu_temp_c = None
    if HOST_THERMAL.is_file():
        try:
            cpu_temp_c = int(HOST_THERMAL.read_text().strip()) / 1000.0
        except (ValueError, OSError):
            pass

    vm = psutil.virtual_memory()
    boot_time = psutil.boot_time()
    uptime_seconds = max(0.0, time.time() - boot_time) if boot_time else None

    # Deliberately scoped to the media drive, not the whole host filesystem:
    # "is my library drive full" is the number that actually matters here,
    # and it doesn't require bind-mounting host / into this container just to
    # report a percentage.
    disk_media = None
    if MEDIA_PATH.is_dir():
        usage = shutil.disk_usage(MEDIA_PATH)
        disk_media = {"total": usage.total, "used": usage.used, "free": usage.free}

    return {
        "cpu_temp_c": cpu_temp_c,
        "cpu_percent": psutil.cpu_percent(interval=0.2),
        "ram": {"total": vm.total, "used": vm.used, "percent": vm.percent},
        "disk_media": disk_media,
        "uptime_seconds": uptime_seconds,
    }
