.PHONY: install run test lint typecheck check docker-build docker-run

IMAGE ?= tdb-bookings:local
PORT ?= 8080

install:
	uv sync --locked

run:
	uv run python -m app.main

test:
	uv run pytest

lint:
	uv run ruff check .
	uv run ruff format --check .

typecheck:
	uv run mypy app tests .claude/hooks/guard.py

check: lint typecheck test

docker-build:
	docker build --build-arg VCS_REF=$$(git rev-parse HEAD) \
		--build-arg BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ) -t $(IMAGE) .

# Same hardening as production: read-only root filesystem, no capabilities, no privilege gain.
docker-run:
	docker run --rm --name tdb-bookings --read-only --cap-drop ALL \
		--security-opt no-new-privileges -e PORT=$(PORT) -p $(PORT):$(PORT) $(IMAGE)
