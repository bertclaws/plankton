#!/bin/bash
# Post-create setup for the devcontainer
set -euo pipefail

echo "=== Installing Node.js tools ==="
npm install -g @biomejs/biome markdownlint-cli2

echo "=== Installing semgrep ==="
pip install --no-cache-dir semgrep

echo "=== Installing Python dev deps ==="
if command -v uv &>/dev/null; then
  uv sync --frozen --all-extras 2>/dev/null || pip install -e ".[dev]"
else
  pip install -e ".[dev]"
fi

echo "=== Verifying all tools ==="
tools=(jaq ruff shellcheck shfmt yamllint hadolint taplo markdownlint-cli2 biome semgrep)
missing=0
for tool in "${tools[@]}"; do
  if command -v "$tool" &>/dev/null; then
    echo "  ✅ $tool ($(command -v "$tool"))"
  else
    echo "  ❌ $tool NOT FOUND"
    missing=$((missing + 1))
  fi
done

if [ "$missing" -eq 0 ]; then
  echo ""
  echo "All tools installed! Run tests with:"
  echo "  bash .claude/hooks/test_hook.sh --self-test"
  echo "  bash .claude/tests/hooks/test_platform_shim.sh"
else
  echo ""
  echo "⚠️  $missing tool(s) missing — some tests will be skipped"
fi
