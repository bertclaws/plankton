FROM python:3.11-slim AS base

LABEL maintainer="developer"
LABEL version="0.1.0"

RUN groupadd --gid 1000 app \
    && useradd --uid 1000 --gid app --shell /bin/bash --create-home app

WORKDIR /app

FROM base AS builder

COPY pyproject.toml uv.lock ./
RUN pip install --no-cache-dir uv \
    && uv sync --frozen --no-dev

FROM base AS runtime

COPY --from=builder /app/.venv /app/.venv
COPY src/ ./src/

ENV PATH="/app/.venv/bin:$PATH"
USER app

CMD ["python", "-m", "app"]
