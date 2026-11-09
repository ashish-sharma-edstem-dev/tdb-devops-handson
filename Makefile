.PHONY: install run test lint typecheck check docker-build docker-run

IMAGE ?= tdb-bookings:local
PORT ?= 8080

install:
	uv sync --frozen

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
	docker build -t $(IMAGE) .

# Same hardening as production: read-only root filesystem, no capabilities, no privilege gain.
docker-run:
	docker run --rm --name tdb-bookings --read-only --cap-drop ALL \
		--security-opt no-new-privileges -e PORT=$(PORT) -p $(PORT):$(PORT) $(IMAGE)
