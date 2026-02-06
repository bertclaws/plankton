#!/bin/bash
# test_hook.sh - Test multi_linter.sh with sample input
#
# Usage: ./test_hook.sh <file_path>
#        ./test_hook.sh --self-test
#
# Simulates the JSON input that Claude Code sends to PostToolUse hooks
# Useful for debugging hook behavior without running Claude Code

set -euo pipefail

script_dir="$(dirname "$(realpath "$0" || true)")"
project_dir="$(dirname "$(dirname "${script_dir}")")"

# Self-test mode: comprehensive automated testing
run_self_test() {
  local passed=0
  local failed=0
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "${temp_dir}"' EXIT

  echo "=== Hook Self-Test Suite ==="
  echo ""

  # Test helper for temp files (creates file with content)
  # Uses HOOK_SKIP_SUBPROCESS=1 to test detection without subprocess fixing
  test_temp_file() {
    local name="$1"
    local file="$2"
    local content="$3"
    local expect_exit="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 "${script_dir}/multi_linter.sh" >/dev/null 2>&1
    local actual_exit=$?
    set -e

    if [[ "${actual_exit}" -eq "${expect_exit}" ]]; then
      echo "PASS ${name}: exit ${actual_exit} (expected ${expect_exit})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: exit ${actual_exit} (expected ${expect_exit})"
      failed=$((failed + 1))
    fi
  }

  # Test helper for existing files (does NOT modify file)
  # Uses HOOK_SKIP_SUBPROCESS=1 to test detection without subprocess fixing
  test_existing_file() {
    local name="$1"
    local file="$2"
    local expect_exit="$3"

    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 "${script_dir}/multi_linter.sh" >/dev/null 2>&1
    local actual_exit=$?
    set -e

    if [[ "${actual_exit}" -eq "${expect_exit}" ]]; then
      echo "PASS ${name}: exit ${actual_exit} (expected ${expect_exit})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: exit ${actual_exit} (expected ${expect_exit})"
      failed=$((failed + 1))
    fi
  }

  # Dockerfile pattern tests
  echo "--- Dockerfile Pattern Coverage ---"
  test_temp_file "Dockerfile (valid)" \
    "${temp_dir}/Dockerfile" \
    'FROM python:3.11-slim
LABEL maintainer="test" version="1.0"
CMD ["python"]' 0

  test_temp_file "*.dockerfile (valid)" \
    "${temp_dir}/test.dockerfile" \
    'FROM alpine:3.19
LABEL maintainer="test" version="1.0"
CMD ["echo"]' 0

  test_temp_file "*.dockerfile (invalid - missing labels)" \
    "${temp_dir}/bad.dockerfile" \
    'FROM ubuntu
RUN apt-get update' 2

  # Other file type tests
  echo ""
  echo "--- Other File Types ---"
  # Python needs proper docstrings now that D rules are enabled
  test_temp_file "Python (valid)" \
    "${temp_dir}/test.py" \
    '"""Module docstring."""


def foo():
    """Do nothing."""
    pass' 0

  test_temp_file "Shell (valid)" \
    "${temp_dir}/test.sh" \
    '#!/bin/bash
echo "hello"' 0

  test_temp_file "JSON (valid)" \
    "${temp_dir}/test.json" \
    '{"key": "value"}' 0

  test_temp_file "JSON (invalid syntax)" \
    "${temp_dir}/bad.json" \
    '{invalid}' 2

  test_temp_file "YAML (valid)" \
    "${temp_dir}/test.yaml" \
    'key: value' 0

  # Styled output format tests
  # Uses HOOK_SKIP_SUBPROCESS=1 to capture output without subprocess
  echo ""
  echo "--- Styled Output Format Tests ---"

  test_output_format() {
    local name="$1"
    local file="$2"
    local content="$3"
    local pattern="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    local output
    output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 "${script_dir}/multi_linter.sh" 2>&1)
    set -e

    if echo "${output}" | grep -qE "${pattern}"; then
      echo "PASS ${name}: pattern '${pattern}' found"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: pattern '${pattern}' NOT found"
      echo "   Output: ${output}"
      failed=$((failed + 1))
    fi
  }

  # Test violations output contains JSON_SYNTAX code
  test_output_format "JSON violations output" \
    "${temp_dir}/marked.json" \
    '{invalid}' \
    'JSON_SYNTAX'

  # Test Dockerfile violations are captured
  test_output_format "Dockerfile violations captured" \
    "${temp_dir}/blend.dockerfile" \
    'FROM ubuntu
RUN apt-get update' \
    'DL[0-9]+'

  # Model selection tests (new three-phase architecture)
  echo ""
  echo "--- Model Selection Tests ---"

  test_model_selection() {
    local name="$1"
    local file="$2"
    local content="$3"
    local expect_model="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    local output
    output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1 "${script_dir}/multi_linter.sh" 2>&1)
    set -e

    local actual_model
    actual_model=$(echo "${output}" | grep -oE '\[hook:model\] (haiku|sonnet|opus)' | awk '{print $2}' || echo "none")

    if [[ "${actual_model}" == "${expect_model}" ]]; then
      echo "PASS ${name}: model=${actual_model} (expected ${expect_model})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: model=${actual_model} (expected ${expect_model})"
      failed=$((failed + 1))
    fi
  }

  # Simple violation -> haiku (needs docstrings to avoid D rules triggering sonnet)
  test_model_selection "Simple (F841) -> haiku" \
    "${temp_dir}/simple.py" \
    '"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42' \
    "haiku"

  # Complexity violation -> sonnet (needs docstrings to avoid D rules stacking)
  test_model_selection "Complexity (C901) -> sonnet" \
    "${temp_dir}/complex.py" \
    '"""Module docstring."""


def f(a, b, c, d, e, f, g, h, i, j, k):
    """Handle complexity."""
    if a:
        if b:
            if c:
                if d:
                    if e:
                        if f:
                            if g:
                                if h:
                                    if i:
                                        if j:
                                            return k
    return None' \
    "sonnet"

  # >5 violations -> opus (needs docstrings, 6 F841 unused variables)
  test_model_selection ">5 violations -> opus" \
    "${temp_dir}/many.py" \
    '"""Module docstring."""


def foo():
    """Create unused variables."""
    a = 1
    b = 2
    c = 3
    d = 4
    e = 5
    f = 6
    return 42' \
    "opus"

  # Docstring violation -> sonnet
  test_model_selection "Docstring (D103) -> sonnet" \
    "${temp_dir}/nodoc.py" \
    'def missing_docstring():
    return 42' \
    "sonnet"

  # Summary
  echo ""
  echo "=== Summary ==="
  echo "Passed: ${passed}"
  echo "Failed: ${failed}"

  if [[ "${failed}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

file_path="${1:-}"

if [[ "${file_path}" == "--self-test" ]]; then
  run_self_test
fi

if [[ -z "${file_path}" ]]; then
  echo "Usage: $0 <file_path>"
  echo "       $0 --self-test    # Run comprehensive test suite"
  echo ""
  echo "Examples:"
  echo "  $0 ./my_script.sh      # Test shell linting"
  echo "  $0 ./config.yaml       # Test YAML linting"
  echo "  $0 ./main.py           # Test Python complexity"
  echo "  $0 ./Dockerfile        # Test Dockerfile linting"
  echo "  $0 ./app.dockerfile    # Test *.dockerfile extension"
  echo ""
  echo "Exit codes:"
  echo "  0 - No issues or warnings only (not fed to Claude)"
  echo "  2 - Blocking errors found (fed to Claude via stderr)"
  exit 1
fi

if [[ ! -f "${file_path}" ]]; then
  echo "Error: File not found: ${file_path}"
  exit 1
fi

# Construct JSON input like Claude Code does
json_input=$(
  cat <<EOF
{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "$(realpath "${file_path}" || true)"
  }
}
EOF
)

echo "=== Testing multi_linter.sh ==="
echo "Input file: ${file_path}"
echo "JSON input: ${json_input}"
echo ""
echo "=== Hook Output ==="

# Run the hook and capture exit code
script_dir="$(dirname "$(realpath "$0" || true)")"
set +e
echo "${json_input}" | "${script_dir}/multi_linter.sh"
exit_code=$?
set -e

echo ""
echo "=== Result ==="
echo "Exit code: ${exit_code}"
case ${exit_code} in
  0) echo "Status: OK (warnings only, not fed to Claude)" ;;
  2) echo "Status: BLOCKING (errors found, fed to Claude)" ;;
  *) echo "Status: UNKNOWN (exit code ${exit_code})" ;;
esac
