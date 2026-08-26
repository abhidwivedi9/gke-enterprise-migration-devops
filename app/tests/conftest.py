"""
Test fixtures.

Environment must be set BEFORE app.src.main is imported, because the module
reads its build identity and config at import time - exactly as it does in the
container. Setting it here also proves the "fail fast on missing config"
behaviour is real: remove ORDERS_DB_DSN and the app refuses to start.
"""

import os

os.environ.setdefault("ORDERS_DB_DSN", "postgresql://test:test@localhost:5432/orders")
os.environ.setdefault("APP_VERSION", "2.4.17")
os.environ.setdefault("GIT_COMMIT", "abc1234567890def1234567890abcdef12345678")
os.environ.setdefault("GIT_BRANCH", "main")
os.environ.setdefault("BUILD_TIMESTAMP", "2026-01-15T10:30:00Z")
os.environ.setdefault("IMAGE_TAG", "2.4.17")
os.environ.setdefault("IMAGE_DIGEST", "sha256:deadbeef")
os.environ.setdefault("ENVIRONMENT", "test")

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.src.main import app  # noqa: E402


@pytest.fixture(scope="session")
def client():
    # The context manager form runs lifespan, so startup/readiness is exercised.
    with TestClient(app) as c:
        yield c
