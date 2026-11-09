"""HTTP entry point for the bookings service."""

import uvicorn
from fastapi import FastAPI, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    GC_COLLECTOR,
    PLATFORM_COLLECTOR,
    PROCESS_COLLECTOR,
    CollectorRegistry,
    generate_latest,
)

from app import repository
from app.config import get_settings
from app.metrics import METRICS_PATH, PrometheusMiddleware, new_request_histogram
from app.models import BookingList, Health


def create_app() -> FastAPI:
    app = FastAPI(title="tdb-bookings", version="0.1.0")

    # One registry per app instance (not the process-global default), so every app built by a test
    # starts from zero and two apps never register the same metric name twice.
    registry = CollectorRegistry()
    # Same process / GC / Python-version metrics the default registry would export (CPU, RSS, fds).
    for collector in (PROCESS_COLLECTOR, GC_COLLECTOR, PLATFORM_COLLECTOR):
        registry.register(collector)
    app.state.metrics_registry = registry
    app.add_middleware(PrometheusMiddleware, histogram=new_request_histogram(registry))

    @app.get(METRICS_PATH, include_in_schema=False)
    def metrics() -> Response:
        """Prometheus scrape endpoint (text exposition format)."""
        return Response(content=generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    @app.get("/health", response_model=Health, tags=["ops"])
    def health() -> Health:
        """Liveness check. Does not touch the database, so a DB outage does not restart pods."""
        return Health(status="ok")

    @app.get("/bookings", response_model=BookingList, tags=["bookings"])
    def get_bookings() -> BookingList:
        items = repository.list_bookings()
        return BookingList(items=items, count=len(items))

    return app


app = create_app()


def run() -> None:
    """Start the server with host/port taken from the environment."""
    settings = get_settings()
    uvicorn.run(
        "app.main:app",
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level,
        proxy_headers=True,
    )


if __name__ == "__main__":
    run()
