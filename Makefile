.PHONY: install lint test format install-hooks clean

install:
	uv sync --all-extras

lint:
	uv run ruff check src tests
	uv run ruff format --check src tests

test:
	uv run pytest tests/

format:
	uv run ruff format src tests
	uv run ruff check --fix src tests

install-hooks:
	uv run pre-commit install

clean:
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type d -name .pytest_cache -exec rm -rf {} +
	rm -rf dist build *.egg-info
