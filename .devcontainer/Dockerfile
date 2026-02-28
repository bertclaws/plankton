FROM mcr.microsoft.com/devcontainers/python:3.11

ARG TARGETARCH

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    jq \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# jaq (Rust-based jq alternative — required by all hook scripts)
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64-unknown-linux-gnu" || echo "x86_64-unknown-linux-musl") \
    && curl -fsSL "https://github.com/01mf02/jaq/releases/latest/download/jaq-${ARCH}" -o /usr/local/bin/jaq \
    && chmod +x /usr/local/bin/jaq

# shellcheck
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") \
    && curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.${ARCH}.tar.xz" \
    | tar xJ --strip-components=1 -C /usr/local/bin shellcheck-v0.10.0/shellcheck

# shfmt
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") \
    && curl -fsSL "https://github.com/mvdan/sh/releases/download/v3.9.0/shfmt_v3.9.0_linux_${ARCH}" -o /usr/local/bin/shfmt \
    && chmod +x /usr/local/bin/shfmt

# hadolint (Dockerfile linting)
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x86_64") \
    && curl -fsSL "https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-${ARCH}" -o /usr/local/bin/hadolint \
    && chmod +x /usr/local/bin/hadolint

# taplo (TOML linting)
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") \
    && curl -fsSL "https://github.com/tamasfe/taplo/releases/latest/download/taplo-linux-${ARCH}.gz" \
    | gunzip > /usr/local/bin/taplo \
    && chmod +x /usr/local/bin/taplo

# Node.js (for biome, markdownlint-cli2)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @biomejs/biome markdownlint-cli2

# Python linting tools
RUN pip install --no-cache-dir \
    ruff \
    yamllint \
    ty \
    flake8 \
    flake8-pydantic \
    flake8-async \
    pre-commit
