"""PiHub Homepage — the unified status dashboard for every PiHub service.

Replaces PiHub's earlier dashboard/ + management-api/ pair: one lightweight
process that serves the frontend AND the API it talks to, config-driven via
config/services.yml so a future service (Immich, Pi-hole, ...) is a config
edit, never a code change.

Every check here degrades independently rather than failing the whole
request: a service whose container is stopped just gets skipped for the
HTTP health check (nothing to check), a service whose HTTP check errors
still reports the Docker-side status, and the docker socket being briefly
unreachable takes down only the docker-dependent endpoints — see
docker_monitor.py's module docstring for the security reasoning on that
socket mount.
"""

import asyncio
import logging
import os
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

import docker_monitor
import health_checker
import system_stats

logger = logging.getLogger("homepage")
logging.basicConfig(level=logging.INFO)

CORS_ORIGINS = [o.strip() for o in os.environ.get("CORS_ORIGINS", "*").split(",") if o.strip()]
CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/app/config"))
FRONTEND_DIR = Path(os.environ.get("FRONTEND_DIR", "/app/frontend"))

app = FastAPI(title="PiHub Homepage")
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Config loading ──────────────────────────────────────────────────────
# Re-read on every request rather than cached at startup: services.yml is
# meant to be edited without restarting the container (see its own header
# comment), and parsing one small YAML file is cheap enough that there's no
# real cost to doing it fresh every time.

def _load_yaml(path: Path) -> dict:
    if not path.is_file():
        return {}
    with path.open(encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def load_services() -> list:
    raw = _load_yaml(CONFIG_DIR / "services.yml").get("services") or {}
    services = []
    for service_id, entry in raw.items():
        containers = entry.get("containers")
        if not containers:
            single = entry.get("compose_service")
            containers = [single] if single else []
        services.append({
            "id": service_id,
            "name": entry.get("name", service_id),
            "description": entry.get("description", ""),
            "icon": entry.get("icon", "app"),
            "containers": containers,
            "health_url": entry.get("health_url"),
            "health_endpoint": entry.get("health_endpoint", "/"),
            "launch_url": entry.get("launch_url", "#"),
            "manageable": entry.get("manageable", True),
        })
    return services


def load_settings() -> dict:
    defaults = {
        "title": "PiHub",
        "theme_default": "dark",
        "services_poll_seconds": 12,
        "stats_poll_seconds": 5,
        "thresholds": {
            "cpu_temp_warn_c": 70, "cpu_temp_crit_c": 80,
            "disk_warn_percent": 75, "disk_crit_percent": 90,
            "ram_warn_percent": 85, "ram_crit_percent": 95,
        },
    }
    return {**defaults, **_load_yaml(CONFIG_DIR / "settings.yml")}


def _find_service(services: list, service_id: str) -> dict:
    for s in services:
        if s["id"] == service_id:
            return s
    raise HTTPException(status_code=404, detail=f"Unknown service '{service_id}'")


def _port_from_url(url: Optional[str]) -> Optional[int]:
    if not url:
        return None
    try:
        return urllib.parse.urlparse(url).port
    except ValueError:
        return None


def _uptime_seconds(started_at: Optional[str]) -> Optional[float]:
    if not started_at:
        return None
    try:
        # Docker's StartedAt is RFC3339 with nanosecond precision
        # (".123456789Z"), which %f (max 6 digits) can't parse directly —
        # truncate to microseconds first.
        if "." in started_at:
            head, frac = started_at.split(".", 1)
            frac = frac.rstrip("Z")[:6]
            started_at = f"{head}.{frac}+00:00"
        else:
            started_at = started_at.rstrip("Z") + "+00:00"
        dt = datetime.fromisoformat(started_at)
        return max(0.0, (datetime.now(timezone.utc) - dt).total_seconds())
    except (ValueError, TypeError):
        return None


@app.get("/api/health")
async def health():
    return {"status": "ok"}


@app.get("/api/config/settings")
async def get_settings():
    return load_settings()


@app.get("/api/services")
async def list_services():
    services = load_services()
    out = []
    for service in services:
        statuses = (
            list(await asyncio.gather(*(docker_monitor.container_status(c) for c in service["containers"])))
            if service["containers"] else []
        )
        docker_state = docker_monitor.aggregate_states(statuses) if statuses else "error"

        http_result = None
        # Only bother checking the actual endpoint if Docker thinks
        # something is running to answer it — an HTTP check against a
        # stopped service would just time out for no useful information,
        # and would misreport an intentional stop as "unreachable".
        if service["health_url"] and docker_state in ("running", "degraded", "partial"):
            url = service["health_url"].rstrip("/") + service["health_endpoint"]
            http_result = await health_checker.check_http(service["id"], url)

        if docker_state == "stopped":
            status = "stopped"
        elif docker_state in ("error",):
            status = "error"
        elif http_result is not None and not http_result["ok"]:
            status = "unhealthy"
        elif docker_state == "degraded":
            status = "degraded"
        elif docker_state == "partial":
            status = "partial"
        else:
            status = "running"

        primary = statuses[0] if statuses else {}
        out.append({
            "id": service["id"],
            "name": service["name"],
            "description": service["description"],
            "icon": service["icon"],
            "launch_url": service["launch_url"],
            "manageable": service["manageable"],
            "status": status,
            "port": _port_from_url(service["health_url"]),
            "uptime_seconds": _uptime_seconds(primary.get("started_at")),
            "containers": statuses,
            "health": http_result,
        })
    return {"services": out}


def _act_endpoint(service_id: str, action: str):
    services = load_services()
    service = _find_service(services, service_id)
    if not service["manageable"]:
        raise HTTPException(status_code=403, detail=f"'{service_id}' is not managed from here")
    return service


@app.post("/api/services/{service_id}/start")
async def start_service(service_id: str):
    service = _act_endpoint(service_id, "start")
    results = await docker_monitor.act(service["containers"], "start")
    return {"service": service_id, "action": "start", "results": results}


@app.post("/api/services/{service_id}/stop")
async def stop_service(service_id: str):
    service = _act_endpoint(service_id, "stop")
    results = await docker_monitor.act(service["containers"], "stop")
    return {"service": service_id, "action": "stop", "results": results}


@app.post("/api/services/{service_id}/restart")
async def restart_service(service_id: str):
    service = _act_endpoint(service_id, "restart")
    results = await docker_monitor.act(service["containers"], "restart")
    return {"service": service_id, "action": "restart", "results": results}


@app.post("/api/services/start-all")
async def start_all():
    services = [s for s in load_services() if s["manageable"]]
    out = {}
    for service in services:
        out[service["id"]] = await docker_monitor.act(service["containers"], "start")
    return {"results": out}


@app.post("/api/services/stop-all")
async def stop_all():
    services = [s for s in load_services() if s["manageable"]]
    out = {}
    for service in services:
        out[service["id"]] = await docker_monitor.act(service["containers"], "stop")
    return {"results": out}


@app.get("/api/services/{service_id}/logs")
async def service_logs(service_id: str, lines: int = Query(200, ge=1, le=2000), container: Optional[str] = None):
    services = load_services()
    service = _find_service(services, service_id)
    name = container if container in service["containers"] else (service["containers"][0] if service["containers"] else None)
    if not name:
        raise HTTPException(status_code=404, detail=f"'{service_id}' has no containers configured")
    try:
        lines_out = await docker_monitor.get_logs(name, lines)
    except Exception as exc:  # noqa: BLE001 — surfaced to the caller either way
        raise HTTPException(status_code=502, detail=str(exc))
    return {"container": name, "lines": lines_out}


@app.get("/api/system/stats")
async def stats():
    return await system_stats.get_stats()


@app.get("/api/system/updates")
async def updates():
    """On-demand only (see docker_monitor/system_stats caching) — never
    part of the fast poll loop."""
    services = load_services()
    image_checks = {}
    for service in services:
        for container_name in service["containers"]:
            image_ref = await docker_monitor.get_container_image(container_name)
            if image_ref:
                image_checks[container_name] = await docker_monitor.check_update(image_ref)

    ytdlp = None
    if any(c == "pitune-backend" for s in services for c in s["containers"]):
        ytdlp = await system_stats.check_ytdlp_version("pitune-backend")

    return {"images": image_checks, "ytdlp": ytdlp}


# Registered LAST so it only catches whatever the API routes above didn't —
# Starlette matches in registration order, and a StaticFiles mount at "/"
# would otherwise shadow everything.
if FRONTEND_DIR.is_dir():
    app.mount("/", StaticFiles(directory=str(FRONTEND_DIR), html=True), name="frontend")
