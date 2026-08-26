"""
orders-api - the enterprise workload being migrated to GCP/GKE.

Deliberately small, but production-shaped. Everything a DevOps engineer touches
during a migration and during post-migration support is here:

  /          service identity
  /health    liveness   - "is the process alive?"    (never checks dependencies)
  /ready     readiness  - "can it serve traffic?"    (does check dependencies)
  /startup   startup    - "has it finished booting?" (slow-start protection)
  /version   the endpoint production support lives on: version + commit + image
  /metrics   Prometheus exposition

Fault injection (used by failure-lab/, all env-driven, all default-off) lets the
same image reproduce CrashLoopBackOff, OOMKilled, readiness failure, slow start
and elevated 5xx without shipping a second "broken" image.
"""

from __future__ import annotations

import json
import logging
import os
import random
import signal
import sys
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

# ---------------------------------------------------------------------------
# Build/version identity.
#
# Baked in at DOCKER BUILD TIME via --build-arg, not at runtime. That is the
# whole point: a running container must be able to prove which commit produced
# it. See scripts/verify-version.sh and docs/VERSION_VERIFICATION.md.
# ---------------------------------------------------------------------------
APP_NAME = os.getenv("APP_NAME", "orders-api")
APP_VERSION = os.getenv("APP_VERSION", "0.0.0-dev")
GIT_COMMIT = os.getenv("GIT_COMMIT", "unknown")
GIT_BRANCH = os.getenv("GIT_BRANCH", "unknown")
BUILD_TIMESTAMP = os.getenv("BUILD_TIMESTAMP", "unknown")
IMAGE_TAG = os.getenv("IMAGE_TAG", "unknown")
IMAGE_DIGEST = os.getenv("IMAGE_DIGEST", "unknown")

# Runtime identity, injected by Kubernetes via the downward API.
POD_NAME = os.getenv("POD_NAME", "not-in-kubernetes")
POD_NAMESPACE = os.getenv("POD_NAMESPACE", "none")
NODE_NAME = os.getenv("NODE_NAME", "none")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")

# ---------------------------------------------------------------------------
# Fault-injection switches - the failure lab drives these. Default: all off.
# ---------------------------------------------------------------------------
CRASH_ON_START = os.getenv("CRASH_ON_START", "false").lower() == "true"
FAIL_READINESS = os.getenv("FAIL_READINESS", "false").lower() == "true"
FAIL_LIVENESS = os.getenv("FAIL_LIVENESS", "false").lower() == "true"
STARTUP_DELAY_SECONDS = int(os.getenv("STARTUP_DELAY_SECONDS", "0"))
ERROR_RATE_PERCENT = int(os.getenv("ERROR_RATE_PERCENT", "0"))
LATENCY_INJECT_MS = int(os.getenv("LATENCY_INJECT_MS", "0"))
MEMORY_BALLAST_MB = int(os.getenv("MEMORY_BALLAST_MB", "0"))
CPU_BURN = os.getenv("CPU_BURN", "false").lower() == "true"

# A required config value with no default, so a missing ConfigMap/Secret fails
# loudly at startup instead of silently serving wrong behaviour in production.
REQUIRED_CONFIG_KEY = os.getenv("ORDERS_DB_DSN")

SHUTDOWN_DRAIN_SECONDS = float(os.getenv("SHUTDOWN_DRAIN_SECONDS", "5"))

# ---------------------------------------------------------------------------
# Structured JSON logging. Cloud Logging parses these into real indexed fields,
# which is what makes the Logs Explorer queries in docs/LOGGING_GUIDE.md work.
# ---------------------------------------------------------------------------


class CloudLoggingFormatter(logging.Formatter):
    """Emit one JSON object per line, using Cloud Logging's field names."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created))
            + f".{int(record.msecs):03d}Z",
            "logger": record.name,
            "service": APP_NAME,
            "version": APP_VERSION,
            "commit": GIT_COMMIT[:12],
            "pod": POD_NAME,
            "namespace": POD_NAMESPACE,
        }
        for key in ("request_id", "path", "status", "latency_ms", "method"):
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(CloudLoggingFormatter())
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), handlers=[_handler], force=True)
log = logging.getLogger(APP_NAME)

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests.",
    ["method", "path", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)
BUILD_INFO = Gauge(
    "app_build_info",
    "Build identity of the running container. Always 1; the labels carry the data.",
    ["version", "commit", "image_tag", "environment"],
)
READY = Gauge("app_ready", "1 when the service reports ready, else 0.")
START_TIME = Gauge("app_start_time_seconds", "Unix time the process started.")

BUILD_INFO.labels(
    version=APP_VERSION,
    commit=GIT_COMMIT[:12],
    image_tag=IMAGE_TAG,
    environment=ENVIRONMENT,
).set(1)

_state: dict[str, Any] = {"ready": False, "started_at": time.time(), "ballast": None}


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Startup and graceful shutdown."""
    START_TIME.set(_state["started_at"])

    if CRASH_ON_START:
        # Failure lab 01: CrashLoopBackOff. Exit non-zero before serving anything.
        log.error("CRASH_ON_START is set - exiting 1 to simulate a boot failure")
        sys.exit(1)

    if REQUIRED_CONFIG_KEY is None:
        # Failure lab 08: missing Secret/ConfigMap. Fail fast, and say exactly what.
        log.error(
            "required env ORDERS_DB_DSN is not set - check the ConfigMap and Secret "
            "referenced by the Deployment (envFrom)"
        )
        sys.exit(2)

    if MEMORY_BALLAST_MB > 0:
        # Failure lab 04: OOMKilled. Allocates real, non-freeable resident memory.
        log.warning("allocating %d MB ballast", MEMORY_BALLAST_MB)
        _state["ballast"] = bytearray(MEMORY_BALLAST_MB * 1024 * 1024)

    if STARTUP_DELAY_SECONDS > 0:
        # Failure lab 07: startupProbe. Boot slower than the probe tolerates.
        log.warning("simulating slow start: sleeping %ds", STARTUP_DELAY_SECONDS)
        time.sleep(STARTUP_DELAY_SECONDS)

    _state["ready"] = True
    READY.set(1)
    log.info(
        "%s started: version=%s commit=%s image=%s env=%s",
        APP_NAME,
        APP_VERSION,
        GIT_COMMIT[:12],
        IMAGE_TAG,
        ENVIRONMENT,
    )

    yield

    # Graceful shutdown: flip readiness off FIRST so the endpoints controller
    # pulls this pod out of the Service, then drain in-flight work. Skipping
    # this is the single most common cause of 502s during a rolling update.
    _state["ready"] = False
    READY.set(0)
    log.info("SIGTERM received - readiness off, draining for %.1fs", SHUTDOWN_DRAIN_SECONDS)
    time.sleep(min(SHUTDOWN_DRAIN_SECONDS, 10))
    log.info("shutdown complete")


app = FastAPI(
    title=APP_NAME,
    version=APP_VERSION,
    lifespan=lifespan,
    docs_url="/docs" if ENVIRONMENT != "prod" else None,
    redoc_url=None,
)


@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    """Assign a request ID, record metrics, emit one structured access log line."""
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    started = time.perf_counter()
    probe_paths = ("/health", "/ready", "/metrics", "/startup")

    if LATENCY_INJECT_MS > 0 and request.url.path not in probe_paths:
        time.sleep(LATENCY_INJECT_MS / 1000.0)

    try:
        if (
            ERROR_RATE_PERCENT > 0
            and request.url.path not in probe_paths + ("/version",)
            # Fault-injection sampling, not a security decision. Nothing here
            # gates access or generates a token, so a CSPRNG would only make the
            # failure lab slower. (Bandit parses everything after `nosec` as
            # test IDs, so the justification has to live above it.)
            and random.randint(1, 100) <= ERROR_RATE_PERCENT  # nosec B311
        ):
            # Failure lab 15: elevated 5xx. Mirrors docs/INCIDENT_HTTP_500.md -
            # every pod Ready, every probe green, and users still see errors.
            raise RuntimeError("injected downstream dependency failure")
        response = await call_next(request)
    except Exception:
        log.exception(
            "unhandled error",
            extra={
                "request_id": request_id,
                "path": request.url.path,
                "method": request.method,
                "status": 500,
            },
        )
        response = JSONResponse(
            status_code=500,
            content={"error": "internal_server_error", "request_id": request_id},
        )

    elapsed = time.perf_counter() - started
    # Label with the route template, never the raw path, so metric cardinality
    # stays bounded. Unbounded label values are how you DoS your own Prometheus.
    route = request.scope.get("route")
    path_label = getattr(route, "path", "unmatched")

    REQUESTS.labels(request.method, path_label, str(response.status_code)).inc()
    LATENCY.labels(request.method, path_label).observe(elapsed)
    response.headers["x-request-id"] = request_id
    response.headers["x-app-version"] = APP_VERSION

    if request.url.path not in probe_paths:
        log.info(
            "%s %s %d",
            request.method,
            request.url.path,
            response.status_code,
            extra={
                "request_id": request_id,
                "path": request.url.path,
                "method": request.method,
                "status": response.status_code,
                "latency_ms": round(elapsed * 1000, 2),
            },
        )
    return response


@app.get("/")
def root() -> dict[str, str]:
    return {
        "service": APP_NAME,
        "version": APP_VERSION,
        "environment": ENVIRONMENT,
        "message": "orders-api is serving",
    }


@app.get("/health")
def health() -> Response:
    """
    LIVENESS. Answers exactly one question: should kubelet restart this container?

    It must NOT check databases or downstream services. If it did, a transient
    dependency outage would restart every pod at once and turn a partial outage
    into a total one. That mistake is failure-lab scenario 06.
    """
    if FAIL_LIVENESS:
        return JSONResponse(status_code=500, content={"status": "unhealthy"})
    return JSONResponse(
        status_code=200,
        content={"status": "ok", "uptime_seconds": round(time.time() - _state["started_at"], 1)},
    )


@app.get("/ready")
def ready() -> Response:
    """
    READINESS. Answers: should the Service send traffic here right now?

    Unlike liveness, this SHOULD reflect dependencies. Failing readiness removes
    the pod from Endpoints without killing it - the correct response to a
    dependency being briefly unavailable.
    """
    if FAIL_READINESS or not _state["ready"]:
        return JSONResponse(
            status_code=503,
            content={
                "status": "not_ready",
                "reason": "dependency_check_failed" if FAIL_READINESS else "still_starting",
            },
        )
    return JSONResponse(status_code=200, content={"status": "ready"})


@app.get("/startup")
def startup() -> Response:
    """STARTUP probe target - protects a slow boot from the liveness probe."""
    if not _state["ready"]:
        return JSONResponse(status_code=503, content={"status": "starting"})
    return JSONResponse(status_code=200, content={"status": "started"})


@app.get("/version")
def version() -> dict[str, str]:
    """
    The endpoint every production version check ends at.

    A Helm release can report "deployed", a Deployment can report 3/3 available,
    and this can still return the previous version - because the tag was mutable,
    or imagePullPolicy left a cached layer in place. This is the ground truth.
    """
    return {
        "application_version": APP_VERSION,
        "git_commit": GIT_COMMIT,
        "git_branch": GIT_BRANCH,
        "build_timestamp": BUILD_TIMESTAMP,
        "container_image_tag": IMAGE_TAG,
        "container_image_digest": IMAGE_DIGEST,
        "pod_name": POD_NAME,
        "namespace": POD_NAMESPACE,
        "node": NODE_NAME,
        "environment": ENVIRONMENT,
    }


@app.get("/api/orders")
def list_orders() -> dict[str, Any]:
    """A trivial business endpoint, so there is real traffic to observe."""
    if CPU_BURN:
        deadline = time.perf_counter() + 0.25
        while time.perf_counter() < deadline:
            _ = sum(i * i for i in range(10_000))
    return {
        "orders": [
            {"id": "ORD-1001", "status": "SHIPPED", "total": 149.99},
            {"id": "ORD-1002", "status": "PENDING", "total": 32.50},
        ],
        "served_by": POD_NAME,
        "version": APP_VERSION,
    }


@app.get("/metrics")
def metrics() -> Response:
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


def _handle_sigterm(signum, _frame):  # pragma: no cover - exercised by k8s only
    log.info("signal %s received", signum)
    _state["ready"] = False
    READY.set(0)


signal.signal(signal.SIGTERM, _handle_sigterm)
