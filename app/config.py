"""Runtime configuration, read only from environment variables.

The same container image runs in every environment; only these values change.
"""

from functools import lru_cache

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Service settings. Every field maps to an upper-case environment variable."""

    model_config = SettingsConfigDict(env_file=None, extra="ignore", frozen=True)

    app_env: str = Field(default="local", description="Environment name, e.g. local, dev, prod.")
    host: str = Field(default="0.0.0.0", description="Interface the HTTP server binds to.")  # noqa: S104
    port: int = Field(default=8080, ge=1, le=65535, description="Port the HTTP server listens on.")
    database_url: SecretStr | None = Field(
        default=None,
        description="PostgreSQL connection URL. Secret: never logged or returned by the API.",
    )
    log_level: str = Field(default="info", description="Uvicorn log level.")


@lru_cache
def get_settings() -> Settings:
    """Return the process-wide settings, read once from the environment."""
    return Settings()
