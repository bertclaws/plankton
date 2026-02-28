#!/bin/bash
# test_platform_shim.sh - validates Claude/Copilot input and output normalization

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_dir="$(cd "${script_dir}/../../hooks" && pwd)"
# shellcheck source=.claude/hooks/platform_shim.sh
source "${hook_dir}/platform_shim.sh"

# Ensure jaq is available for shim functions (fallback to jq in local test env).
if ! command -v jaq >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    tmp_bin="$(mktemp -d)"
    trap 'rm -rf "${tmp_bin}"' EXIT
    cat >"${tmp_bin}/jaq" <<'EOF'
#!/bin/bash
exec jq "$@"
EOF
    chmod +x "${tmp_bin}/jaq"
    export PATH="${tmp_bin}:${PATH}"
  else
    printf "SKIP: jaq (or jq fallback) not installed\n"
    exit 0
  fi
fi

passed=0
failed=0

assert_eq() {
  local name="$1"
  local got="$2"
  local expected="$3"
  if [[ "${got}" == "${expected}" ]]; then
    printf "  PASS %s\n" "${name}"
    passed=$((passed + 1))
  else
    printf "  FAIL %s: got='%s' expected='%s'\n" "${name}" "${got}" "${expected}"
    failed=$((failed + 1))
  fi
}

assert_json_field() {
  local name="$1"
  local json="$2"
  local filter="$3"
  local expected="$4"
  local got
  got=$(jaq -r "${filter}" <<<"${json}" 2>/dev/null || echo "")
  assert_eq "${name}" "${got}" "${expected}"
}

printf "=== Platform shim tests ===\n"

claude_pre='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/a.py","command":"echo hi"}}'
copilot_pre='{"timestamp":1704614600000,"cwd":"/tmp","toolName":"edit","toolArgs":"{\"file_path\":\"/tmp/b.py\",\"command\":\"rm -rf dist\"}"}'
copilot_create='{"toolName":"create","toolArgs":"{\"file_path\":\"/tmp/new.py\"}"}'
copilot_bash='{"toolName":"bash","toolArgs":"{\"command\":\"npm install\"}"}'

assert_eq "detect_claude" "$(detect_platform "${claude_pre}")" "claude"
assert_eq "detect_copilot" "$(detect_platform "${copilot_pre}")" "copilot"

assert_eq "tool_name_claude" "$(get_tool_name "${claude_pre}")" "Edit"
assert_eq "tool_name_copilot_edit" "$(get_tool_name "${copilot_pre}")" "Edit"
assert_eq "tool_name_copilot_create" "$(get_tool_name "${copilot_create}")" "Write"
assert_eq "tool_name_copilot_bash" "$(get_tool_name "${copilot_bash}")" "Bash"

assert_eq "file_path_claude" "$(get_file_path "${claude_pre}")" "/tmp/a.py"
assert_eq "file_path_copilot" "$(get_file_path "${copilot_pre}")" "/tmp/b.py"
assert_eq "command_claude" "$(get_command "${claude_pre}")" "echo hi"
assert_eq "command_copilot" "$(get_command "${copilot_pre}")" "rm -rf dist"

approve_claude="$(emit_approve claude)"
approve_copilot="$(emit_approve copilot)"
block_claude="$(emit_block claude "blocked reason")"
block_copilot="$(emit_block copilot "blocked reason")"

assert_json_field "approve_claude_decision" "${approve_claude}" ".decision" "approve"
assert_json_field "approve_copilot_decision" "${approve_copilot}" ".permissionDecision" "allow"
assert_json_field "block_claude_decision" "${block_claude}" ".decision" "block"
assert_json_field "block_claude_reason" "${block_claude}" ".reason" "blocked reason"
assert_json_field "block_copilot_decision" "${block_copilot}" ".permissionDecision" "deny"
assert_json_field "block_copilot_reason" "${block_copilot}" ".permissionDecisionReason" "blocked reason"

printf "\nPassed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]
