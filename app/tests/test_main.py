"""
Unit tests.

These are deliberately weighted toward the endpoints production support depends
on. A test suite that covers business logic but not /version and /ready is
testing the wrong risk for a migration project.
"""


def test_root_identifies_the_service(client):
    r = client.get("/")
    assert r.status_code == 200
    assert r.json()["service"] == "orders-api"


def test_health_is_liveness_and_does_not_check_dependencies(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"
    assert "uptime_seconds" in r.json()


def test_ready_reports_ready_after_startup(client):
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_startup_probe_endpoint(client):
    r = client.get("/startup")
    assert r.status_code == 200
    assert r.json()["status"] == "started"


def test_version_exposes_the_full_build_identity(client):
    """The contract scripts/verify-version.sh depends on. Do not weaken it."""
    r = client.get("/version")
    assert r.status_code == 200
    body = r.json()
    for field in (
        "application_version",
        "git_commit",
        "git_branch",
        "build_timestamp",
        "container_image_tag",
        "container_image_digest",
        "pod_name",
        "namespace",
        "environment",
    ):
        assert field in body, f"/version lost the {field} field"
    assert body["application_version"] == "2.4.17"
    assert body["git_commit"].startswith("abc1234")


def test_version_header_is_present_on_every_response(client):
    """Lets you confirm the serving version from a curl -I at the edge."""
    r = client.get("/api/orders")
    assert r.headers["x-app-version"] == "2.4.17"


def test_request_id_is_echoed_for_log_correlation(client):
    r = client.get("/api/orders", headers={"x-request-id": "trace-me-123"})
    assert r.headers["x-request-id"] == "trace-me-123"


def test_request_id_is_generated_when_absent(client):
    r = client.get("/api/orders")
    assert len(r.headers["x-request-id"]) == 36


def test_orders_endpoint_returns_payload(client):
    r = client.get("/api/orders")
    assert r.status_code == 200
    assert len(r.json()["orders"]) == 2


def test_metrics_exposes_prometheus_format(client):
    client.get("/api/orders")
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "http_requests_total" in r.text
    assert "app_build_info" in r.text


def test_build_info_metric_carries_the_version_label(client):
    r = client.get("/metrics")
    assert 'version="2.4.17"' in r.text


def test_metrics_use_route_template_not_raw_path(client):
    """Guards against unbounded label cardinality."""
    r = client.get("/metrics")
    assert 'path="/api/orders"' in r.text
