"""HTTP entry point for the bookings service."""

import uvicorn
from fastapi import FastAPI

from app import repository
from app.config import get_settings
from app.models import BookingList, Health


def create_app() -> FastAPI:
    app = FastAPI(title="tdb-bookings", version="0.1.0")

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
