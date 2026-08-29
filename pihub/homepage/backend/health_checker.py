"""HTTP health checks against each service's own endpoint, plus a small
in-memory history of when it last went down and how fast it's answering.

Deliberately no database or on-disk store here (the project keeps its whole
config as one YAML file, see ../README.md) — this history exists to answer
"has this been flapping the last few minutes", not to be a permanent audit
log, so losing it on a restart is an acceptable, deliberate trade.
"""

import time
from collections import deque
from typing import Optional

import httpx

# ~last 20 checks: at the default 12s poll interval that's about 4 minutes
# of recent history — enough to answer "is this flapping right now".
_HISTORY_LEN = 20


class ServiceHistory:
    __slots__ = ("response_times", "last_ok", "down_since", "last_down_duration")

    def __init__(self):
        self.response_times: deque = deque(maxlen=_HISTORY_LEN)
        self.last_ok: Optional[float] = None
        self.down_since: Optional[float] = None
        self.last_down_duration: Optional[float] = None


_history: dict = {}


def _get_history(service_id: str) -> ServiceHistory:
    if service_id not in _history:
        _history[service_id] = ServiceHistory()
    return _history[service_id]


async def check_http(service_id: str, url: str, timeout: float = 3.0) -> dict:
    """One HTTP check, recorded into this service's history as a side
    effect — called once per service per poll, so "once per poll" is also
    "once per history sample"."""
    hist = _get_history(service_id)
    t0 = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            resp = await client.get(url)
        elapsed_ms = (time.monotonic() - t0) * 1000
        # 4xx still means something answered (e.g. an endpoint that wants
        # auth we don't have) — only 5xx/no-response counts as "down" for
        # history-tracking purposes. The exact status is still returned so
        # a caller can tell the difference.
        ok = resp.status_code < 500
        result = {"ok": ok, "status_code": resp.status_code, "response_time_ms": elapsed_ms, "error": None}
    except httpx.HTTPError as exc:
        elapsed_ms = (time.monotonic() - t0) * 1000
        result = {"ok": False, "status_code": None, "response_time_ms": elapsed_ms, "error": str(exc)}

    now = time.time()
    if result["ok"]:
        hist.response_times.append(result["response_time_ms"])
        hist.last_ok = now
        if hist.down_since is not None:
            hist.last_down_duration = now - hist.down_since
            hist.down_since = None
    elif hist.down_since is None:
        hist.down_since = now

    result["avg_response_time_ms"] = (
        sum(hist.response_times) / len(hist.response_times) if hist.response_times else None
    )
    result["last_ok"] = hist.last_ok
    result["down_since"] = hist.down_since
    result["last_down_duration_seconds"] = hist.last_down_duration
    return result
