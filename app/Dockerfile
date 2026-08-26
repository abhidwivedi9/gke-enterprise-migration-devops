# syntax=docker/dockerfile:1.7
#
# Build context is the REPO ROOT, not app/:
#   docker build -f app/Dockerfile -t orders-api:2.4.17 .
#
# Two stages so compilers and pip caches never reach the runtime image. The
# result is a small, non-root image whose build identity is baked into the
# binary layer - which is what makes /version trustworthy in production.

# ---------------------------------------------------------------------------
# Stage 1: builder - install dependencies into an isolated virtualenv
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS builder

# Deterministic pip behaviour; no interactive prompts, no stale wheels.
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

WORKDIR /build

# Copy ONLY the requirements first. This layer is cached and only invalidated
# when dependencies actually change, so ordinary code commits rebuild in seconds
# instead of re-resolving the dependency tree every time.
COPY app/requirements.txt .

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: runtime - slim, non-root, no build toolchain
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

# Build identity. Passed by scripts/build.sh and by the GitHub Actions workflow.
# Declared AFTER the heavy layers so changing a commit SHA does not invalidate
# the dependency cache.
ARG APP_VERSION=0.0.0-dev
ARG GIT_COMMIT=unknown
ARG GIT_BRANCH=unknown
ARG BUILD_TIMESTAMP=unknown
ARG IMAGE_TAG=unknown

ENV APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT} \
    GIT_BRANCH=${GIT_BRANCH} \
    BUILD_TIMESTAMP=${BUILD_TIMESTAMP} \
    IMAGE_TAG=${IMAGE_TAG} \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

# OCI labels. `docker inspect` and Artifact Registry both surface these, so the
# image is self-describing even before you run it.
LABEL org.opencontainers.image.title="orders-api" \
      org.opencontainers.image.description="Enterprise orders API migrated to GCP/GKE" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_TIMESTAMP}" \
      org.opencontainers.image.licenses="Apache-2.0"

# Non-root user with a fixed, high UID. Fixed because the Kubernetes
# securityContext pins runAsUser: 10001 and the two must agree - if they drift,
# the container starts as a user that cannot read its own files.
RUN groupadd --gid 10001 appuser \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin appuser

COPY --from=builder /opt/venv /opt/venv

WORKDIR /srv
COPY --chown=appuser:appuser app/ /srv/app/

USER 10001

EXPOSE 8080

# A HEALTHCHECK is useful for plain `docker run` and docker-compose. Kubernetes
# ignores it entirely and uses the probes in the Deployment instead - that
# distinction is a common interview question.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status==200 else 1)"

# exec form, no shell wrapper: uvicorn becomes PID 1 and receives SIGTERM
# directly. With the shell form, sh would be PID 1, swallow the signal, and
# every rolling update would end in a 30-second SIGKILL instead of a clean drain.
CMD ["uvicorn", "app.src.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
