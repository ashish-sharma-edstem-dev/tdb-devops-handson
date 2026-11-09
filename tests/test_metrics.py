"""The /metrics endpoint and the request histogram that the SLO alert rules are built on."""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from prometheus_client import CollectorRegistry

from app.main import create_app
from app.metrics import status_class

METRIC = "http_request_duration_seconds"


class BoomError(RuntimeError):
    pass


@pytest.fixture
def app() -> FastAPI:
    app = create_app()

    @app.get("/test/boom")
    def boom() -> None:
        raise BoomError("unhandled on purpose")

    return app


@pytest.fixture
def client(app: FastAPI) -> TestClient:
    # raise_server_exceptions=False: behave like a real server and answer 500 instead of re-raising.
    return TestClient(app, raise_server_exceptions=False)


def sample(app: FastAPI, suffix: str, **labels: str) -> float:
    registry: CollectorRegistry = app.state.metrics_registry
    return registry.get_sample_value(f"{METRIC}{suffix}", labels) or 0.0


def test_metrics_endpoint_exposes_histogram(client: TestClient) -> None:
    client.get("/bookings")

    response = client.get("/metrics")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain; version=")
    assert f"# TYPE {METRIC} histogram" in response.text
    assert f'{METRIC}_bucket{{le="1.0",method="GET",route="/bookings",status_class="2xx"}}' in (
        response.text
    )


def test_bookings_request_is_counted_as_good(app: FastAPI, client: TestClient) -> None:
    labels = {"method": "GET", "route": "/bookings", "status_class": "2xx"}

    client.get("/bookings")
    client.get("/bookings")

    assert sample(app, "_count", **labels) == 2
    assert sample(app, "_bucket", le="1.0", **labels) == 2
    assert sample(app, "_sum", **labels) > 0


def test_unknown_path_uses_fixed_route_label(app: FastAPI, client: TestClient) -> None:
    response = client.get("/bookings/does-not-exist/../../etc")

    assert response.status_code == 404
    assert sample(app, "_count", method="GET", route="unmatched", status_class="4xx") == 1
    assert "does-not-exist" not in client.get("/metrics").text


def test_unhandled_exception_is_counted_as_5xx(app: FastAPI, client: TestClient) -> None:
    response = client.get("/test/boom")

    assert response.status_code == 500
    assert sample(app, "_count", method="GET", route="/test/boom", status_class="5xx") == 1


def test_unhandled_exception_is_reraised(app: FastAPI) -> None:
    with pytest.raises(BoomError):
        TestClient(app).get("/test/boom")

    assert sample(app, "_count", method="GET", route="/test/boom", status_class="5xx") == 1


def test_metrics_scrapes_are_not_counted(app: FastAPI, client: TestClient) -> None:
    client.get("/metrics")
    body = client.get("/metrics").text

    assert 'route="/metrics"' not in body
    assert sample(app, "_count", method="GET", route="/metrics", status_class="2xx") == 0


def test_each_app_has_its_own_registry() -> None:
    first, second = create_app(), create_app()
    TestClient(first).get("/bookings")

    labels = {"method": "GET", "route": "/bookings", "status_class": "2xx"}
    assert sample(first, "_count", **labels) == 1
    assert sample(second, "_count", **labels) == 0


@pytest.mark.parametrize(
    ("code", "expected"), [(200, "2xx"), (204, "2xx"), (301, "3xx"), (404, "4xx"), (503, "5xx")]
)
def test_status_class(code: int, expected: str) -> None:
    assert status_class(code) == expected
