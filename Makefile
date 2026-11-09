.PHONY: install run test lint typecheck check

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
