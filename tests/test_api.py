from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

client = TestClient(create_app())


def test_health_returns_ok() -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_bookings_returns_sample_list() -> None:
    response = client.get("/bookings")

    assert response.status_code == 200
    body = response.json()
    assert body["count"] == len(body["items"]) > 0
    assert {"id", "guest_name", "check_in", "check_out", "status"} <= body["items"][0].keys()


def test_settings_read_from_environment(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setenv("PORT", "9090")
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@db:5432/bookings")

    settings = Settings()

    assert settings.port == 9090
    assert settings.database_url is not None
    assert "p@db" not in repr(settings), "the database URL must not leak into logs"
