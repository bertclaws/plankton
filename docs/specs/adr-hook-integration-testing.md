# ADR: Hook Integration Testing via TeamCreate Agents

**Status**: Proposed
**Date**: 2026-02-20
**Author**: alex fazio + Claude Code clarification interview

**Note**: All factual claims carry a `[verify:]` marker referencing
the hook script or README section that authorizes the claim. These
markers must be resolved before this ADR moves to Accepted. Claims
without a verifiable source are marked `[verify: unresolved]`.

**Document type**: This is a hybrid ADR/test-specification. The
decisions (D1–D11) capture architectural choices; the test case
inventories (M01–M19, P01–P28, DEP01–DEP20) are the operational
specification that flows from those decisions. The document is
designed for direct consumption by an orchestrator agent that will
create an execution plan and run the test suite.

## Context and Problem Statement

The plankton hook system has no systematic real-execution
verification layer. The existing `test_hook.sh --self-test` suite
(~96 tests) validates the test harness's own logic but does not
directly exercise each hook via its stdin→stdout contract or the
live Claude Code hook lifecycle. There is no structured proof that:

1. Each hook accepts properly-formed JSON and returns the correct
   `decision` structure per the README contract
   [verify: docs/README.md §Hook Schema Reference]
2. All required dependencies are installed and reachable
   [verify: docs/README.md §Dependencies]
3. Hooks fire correctly in a live Claude Code session
   [verify: docs/README.md §Hook Invocation Behavior]
4. Every documented scenario (violations, passthroughs, compound
   commands, config modes) produces the output described in the ADRs

## Decision Drivers

- **Real contract coverage**: test_hook.sh tests the harness, not
  the hooks' stdin→stdout JSON contract directly
- **Environment assurance**: Dependencies can silently degrade
  (e.g., hadolint < 2.12.0 [verify: docs/README.md §hadolint
  Version Check]) without detection until a hook misbehaves
- **Durable audit trail**: A machine-readable JSONL log enables
  future comparisons and CI integration
- **Parallelism**: Multiple hooks can be tested concurrently via
  TeamCreate without blocking the main session
- **Self-contained fixtures**: Tests must not depend on pre-written
  files with violations — each test creates its own fixtures

## Decisions

### D1: Team Structure — Three TeamCreate Agents

**Decision**: Spawn three agents via TeamCreate:

| Agent | Hook Tested | Scope |
| --- | --- | --- |
| `ml-agent` | `multi_linter.sh` | All file types |
| `pm-agent` | `enforce_package_managers.sh` | All PM scenarios |
| `dep-agent` | Shared infrastructure | Deps + settings.json |

`protect_linter_configs.sh` and `stop_config_guardian.sh` are
excluded from dedicated agents:

- `protect_linter_configs.sh` behavior is simple path matching
  and is thoroughly covered by the existing self-test suite
  [verify: .claude/hooks/protect_linter_configs.sh §path matching]
- `stop_config_guardian.sh` cannot be tested via TeamCreate for
  two reasons: (1) the Stop lifecycle requires a session restart,
  which cannot be triggered deterministically in a non-interactive
  TeamCreate session; (2) TeamCreate teammates trigger the
  `TeammateIdle` lifecycle event, not `Stop` — the Stop event is
  architecturally unreachable from a teammate context
  [verify: docs/README.md §Testing Stop Hook §Integration test]

**Alternatives considered**:

| Option | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| All 4 hooks as agents | Complete | Stop hook not testable | No |
| 2 agents (ml + pm) | Simple | No dep audit | No |
| **3 agents (ml + pm + dep)** | Balanced | Slightly more setup | **Yes** |
| Single agent | Simplest | No parallelism | No |

**Rationale**: The dep audit agent is lightweight but catches
environment issues (wrong tool version, missing jaq, unregistered
hook) that would silently degrade behavior without triggering a
visible test failure. Keeping it separate from ml-agent prevents a
dependency failure from contaminating linter test results.

### D2: Test Fixture Strategy — Inline Heredoc

**Decision**: Each test case creates its own temp fixture file
using an inline heredoc, invokes the hook, inspects output, then
cleans up. No pre-written fixture files with violations are
committed to the repository.

**Fixture pattern** (pseudocode — actual content varies per test):

```bash
tmp=$(mktemp /tmp/hook_test_XXXXXX.py)
cat > "${tmp}" << 'EOF'
def foo():
    unused_var = 1  # F841 violation
    pass
EOF
result=$(echo "{\"tool_input\":{\"file_path\":\"${tmp}\"}}" \
  | HOOK_SKIP_SUBPROCESS=1 bash .claude/hooks/multi_linter.sh)
exit_code=$?
rm -f "${tmp}"
# ... assert exit_code == 2, result contains [hook] ...
```

**Alternatives considered**:

| Option | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Inline heredoc** | Self-contained, no repo files | Verbose | **Yes** |
| Pre-written fixture files | Reusable | Pre-poisoned files in repo | No |
| Pure stdin (no files) | No temp files | Can't test file-path hooks | No |
| Fixture factory function | DRY | Over-engineering for one run | No |

**Rationale**: Inline heredoc mirrors how `test_hook.sh --self-test`
already generates fixtures internally
[verify: .claude/hooks/test_hook.sh §self-test cases]. No fixture
maintenance burden; each test case is fully self-contained and
reproducible.

### D3: Two-Layer Test Execution

**Decision**: Each hook agent runs two test layers:

**Layer 1 — Stdin/stdout direct invocation**:

```bash
echo '{"tool_input": {"file_path": "/tmp/test.py"}}' \
  | bash .claude/hooks/multi_linter.sh
```

This IS the real execution path — Claude Code delivers input to
hooks as JSON on stdin; the hook returns JSON stdout and exit code.
[verify: docs/README.md §Input/Output Contract]

**Layer 2 — Live in-session trigger**:

The agent invokes an actual tool call (Edit for ml-agent, Bash for
pm-agent) with content known to trigger the hook, then observes
whether the hook fired via the tool result or stderr output.

In a TeamCreate session, each teammate runs in its own Claude Code
subprocess. When a teammate uses Edit/Write/Bash, the hooks
registered in `.claude/settings.json` fire for that teammate's
session [verify: .claude/settings.json §PreToolUse, §PostToolUse].
This confirms the hook lifecycle works for this project's
registration, not just the script's stdin/stdout behavior.

**What "live trigger confirmed" means**:

- ml-agent (M19): Calls `Edit` on a temp `.py` file with a
  violation. PostToolUse hook fires. Confirmed when the tool
  result contains the substring `"PostToolUse"` — either
  `"PostToolUse:Edit hook succeeded: Success"` (exit 0, subprocess
  fixed) or `"PostToolUse:Edit hook error: Failed with
  non-blocking status code 2"` (exit 2, violations remain). Both
  outcomes prove the hook lifecycle is active. Non-determinism is
  accepted: M19 does NOT use `HOOK_SKIP_SUBPROCESS` because the
  goal is lifecycle confirmation, not fix behavior testing.
  [verify: docs/README.md §Hook Invocation Behavior]
- pm-agent (P28): Issues `Bash pip install requests`. PreToolUse
  hook fires and blocks the command. Confirmed when the tool
  result contains the substring `"hook:block"` — the block reason
  from `enforce_package_managers.sh`.
  [verify: docs/README.md §Hook Invocation Behavior]

### D4: ml-agent Test Scope — All File Types

**Decision**: ml-agent tests all file types that multi_linter.sh
handles [verify: docs/README.md §Linter Behavior by File Type].

Each file type has at minimum a **clean test** (expect exit 0) and
a **violation test** (expect exit 2 with `[hook]` on stderr).

**File type coverage**:

| Type | Clean test | Violation test | Violation used |
| --- | --- | --- | --- |
| Python `.py` | M01 | M02 | F841 unused var |
| Shell `.sh` | M03 | M04 | SC2086 unquoted var |
| Markdown `.md` | M05 | M06 | MD013 line >80 chars |
| YAML `.yaml` | M07 | M08 | Wrong indentation |
| TOML `.toml` | M09 | M10 | Syntax error |
| JSON `.json` | M11 | M12 | Invalid JSON syntax |
| Dockerfile | M13 | M14 | DL3007 `ubuntu:latest` |
| TypeScript `.ts` | M15 | M16 | Unused variable |
| JavaScript `.js` | M17 | — | Clean only |
| CSS `.css` | M18 | — | Clean only |

**TypeScript/JS/CSS gate**: These tests require Biome
[verify: docs/README.md §Dependencies §Optional]. If `biome` or
`npx biome` is not found, log M15–M18 as
`pass: false, note: "BIOME_ABSENT"` and mark the suite as failed.
Biome is required (not optional) for this test run per the user's
explicit requirement. Tests M15–M18 use a `CLAUDE_PROJECT_DIR`
override pointing to a temp directory containing a `config.json`
with `typescript.enabled: true` (matching the project's current
default config).

**Subprocess control**: All violation tests use
`HOOK_SKIP_SUBPROCESS=1` for deterministic exit codes. Without it,
the hook spawns `claude -p` which may fix violations and exit 0
regardless of the input content.
[verify: docs/README.md §Testing Environment Variables]

**Live trigger test (M19)**: ml-agent calls `Edit` on a temp `.py`
file with an F841 violation and observes that the PostToolUse hook
fires. This confirms hook lifecycle registration.
[verify: docs/README.md §Hook Invocation Behavior]

### D5: pm-agent Test Scope — All PM Scenarios

**Decision**: pm-agent tests all scenarios documented in
enforce_package_managers.sh
[verify: docs/specs/adr-package-manager-enforcement.md §D12].

**Payload format for all pm-agent tests**:

```bash
echo '{
  "tool_name": "Bash",
  "tool_input": {"command": "pip install requests"}
}' | bash .claude/hooks/enforce_package_managers.sh
```

[verify: .claude/hooks/enforce_package_managers.sh §input parsing,
docs/README.md §Input/Output Contract]

**Block cases** (expected: `decision: "block"`, exit 0):

| ID | Command | Expected `[hook:block]` prefix |
| --- | --- | --- |
| P01 | `pip install requests` | `pip` |
| P02 | `pip3 install flask` | `pip` |
| P03 | `python -m pip install pkg` | `python -m pip` |
| P04 | `python -m venv .venv` | `python -m venv` |
| P05 | `poetry add requests` | `poetry` |
| P06 | `pipenv install` | `pipenv` |
| P07 | `npm install lodash` | `npm` |
| P08 | `npx create-react-app` | `npx` |
| P09 | `yarn add lodash` | `yarn` |
| P10 | `pnpm install` | `pnpm` |

[verify: adr-package-manager-enforcement.md §D3, §D4]

**Approve cases** (expected: `decision: "approve"`, exit 0):

| ID | Command | Reason |
| --- | --- | --- |
| P11 | `uv add requests` | Preferred tool |
| P12 | `uv pip install -r req.txt` | uv pip passthrough |
| P13 | `bun add lodash` | Preferred tool |
| P14 | `bunx vite` | Preferred tool |
| P15 | `npm audit` | Allowlisted subcommand |
| P16 | `pip download requests` | Allowlisted subcommand |
| P17 | `yarn audit` | Allowlisted subcommand |
| P18 | `ls -la` | Non-PM command |

[verify: adr-package-manager-enforcement.md §D3, §D4, §D9]

**Compound command cases**:

| ID | Command | Expected | Source |
| --- | --- | --- | --- |
| P19 | `cd /app && pip install flask` | block (pip) | §D7 |
| P20 | `pip --version && poetry add req` | block (poetry) | Note |
| P21 | `pipenv --version && pipenv install` | block (pipenv) | Note |
| P22 | `pip --version && pipenv install` | block (pipenv) | Note G2 |
| P23 | `poetry --help && poetry add req` | block (poetry) | Note G1 |
| P24 | `npm audit && yarn add malicious` | block (yarn) | §D4 |

[verify: adr-package-manager-enforcement.md §D7, §Note on
independent blocks for poetry/pipenv]

**Config mode cases** (using `CLAUDE_PROJECT_DIR` override to a
temp directory containing a custom `config.json`).

**Config isolation guarantee**: Each config mode test creates its
own temp directory with its own `config.json` and sets
`CLAUDE_PROJECT_DIR` as a per-process environment variable on the
hook subprocess invocation. This provides process-level isolation —
pm-agent's config overrides (P25–P27) cannot affect ml-agent or
dep-agent running concurrently, because environment variable
prefixes (`CLAUDE_PROJECT_DIR=/tmp/foo bash hook.sh`) scope to
that specific subprocess only.

Test cases:

| ID | Config value | Command | Expected |
| --- | --- | --- | --- |
| P25 | `"python": false` | `pip install` | approve |
| P26 | `"python": "uv:warn"` | `pip install` | approve + advisory |
| P27 | `"javascript": false` | `npm install` | approve |

[verify: adr-package-manager-enforcement.md §D9,
.claude/hooks/enforce_package_managers.sh §parse_pm_config]

**Live trigger test (P28)**: pm-agent issues
`Bash pip install requests` via its Bash tool and confirms the
PreToolUse hook blocks the command.
[verify: docs/README.md §Hook Invocation Behavior]

### D6: dep-agent Test Scope — Dependencies and Registration

**Decision**: dep-agent audits two categories:

**Category A — Tool presence and version**
[verify: docs/README.md §Dependencies]:

| ID | Tool | Required | Check | Version Gate |
| --- | --- | --- | --- | --- |
| DEP01 | `jaq` | Yes | `command -v jaq` | — |
| DEP02 | `ruff` | Yes | `command -v ruff` | — |
| DEP03 | `uv` | Yes | `command -v uv` | — |
| DEP04 | `claude` | Yes | PATH search (4 locations) | — |
| DEP05 | `shfmt` | Optional | `command -v shfmt` | — |
| DEP06 | `shellcheck` | Optional | `command -v shellcheck` | — |
| DEP07 | `yamllint` | Optional | `command -v yamllint` | — |
| DEP08 | `hadolint` | Optional | `command -v hadolint` | — |
| DEP09 | `hadolint` version | Optional | `hadolint --version` | ≥ 2.12.0 |
| DEP10 | `taplo` | Optional | `command -v taplo` | — |
| DEP11 | `biome` | Optional | `command -v biome` | — |
| DEP12 | `semgrep` | Optional | `command -v semgrep` | — |

For Required tools: `pass: false` if absent.
For Optional tools: `pass: true` with `note: "absent"` if absent
(absence is expected and graceful).
For DEP09: `pass: false` if hadolint found but version < 2.12.0.
[verify: docs/README.md §hadolint Version Check]

**`claude` discovery order** [verify: docs/README.md
§claude Command Discovery]:

1. `claude` in PATH
2. `~/.local/bin/claude`
3. `~/.npm-global/bin/claude`
4. `/usr/local/bin/claude`

**Category B — Settings registration and config**
[verify: .claude/settings.json, docs/README.md §Configuration]:

| ID | Check | Expected |
| --- | --- | --- |
| DEP13 | `~/.claude/no-hooks-settings.json` exists | exists |
| DEP14 | PreToolUse `Edit\|Write` entry | protect_linter_configs.sh |
| DEP15 | PreToolUse `Bash` entry | enforce_package_managers.sh |
| DEP16 | PostToolUse `Edit\|Write` entry | multi_linter.sh |
| DEP17 | Stop entry | stop_config_guardian.sh |
| DEP18 | `.claude/hooks/config.json` exists | exists |
| DEP19 | `config.json` has `package_managers.python` | present |
| DEP20 | `config.json` has `package_managers.javascript` | present |

[verify: .claude/settings.json, docs/README.md §Runtime
Configuration, docs/README.md §Subprocess Hook Prevention]

### D7: Log Format — JSONL

**Decision**: Each agent writes one JSON object per line (JSONL)
to its own log file. The main agent aggregates all files after all
three agents complete.

**Schema per test record**:

```json
{
  "hook": "multi_linter.sh",
  "test_name": "python_f841_violation",
  "category": "violation",
  "input_summary": "F841 unused var in .py file",
  "expected_decision": "exit_2",
  "expected_exit": 2,
  "actual_decision": "exit_2",
  "actual_exit": 2,
  "actual_output": "[hook] 1 violation(s) remain after delegation",
  "pass": true,
  "note": ""
}
```

For pm-agent tests (JSON stdout hooks):

```json
{
  "hook": "enforce_package_managers.sh",
  "test_name": "pip_install_blocked",
  "category": "block",
  "input_summary": "pip install requests",
  "expected_decision": "block",
  "expected_exit": 0,
  "actual_decision": "block",
  "actual_exit": 0,
  "actual_output": "{\"decision\":\"block\",\"reason\":\"...\"}",
  "pass": true,
  "note": ""
}
```

For dep-agent tests:

```json
{
  "hook": "infrastructure",
  "test_name": "dep_jaq_present",
  "category": "dependency",
  "input_summary": "command -v jaq",
  "expected_decision": "present",
  "expected_exit": 0,
  "actual_decision": "present",
  "actual_exit": 0,
  "actual_output": "/opt/homebrew/bin/jaq",
  "pass": true,
  "note": ""
}
```

For live trigger tests (Layer 2):

```json
{
  "hook": "multi_linter.sh",
  "test_name": "live_trigger_edit_py",
  "category": "live_trigger",
  "input_summary": "Edit temp .py with F841 via tool",
  "expected_decision": "hook_fired",
  "expected_exit": null,
  "actual_decision": "hook_fired",
  "actual_exit": null,
  "actual_output": "PostToolUse:Edit hook succeeded: Success",
  "pass": true,
  "note": "Layer 2: confirmed hook lifecycle registration"
}
```

The `category: "live_trigger"` distinguishes Layer 2 from Layer 1
tests. Fields that don't apply to live trigger tests use `null`.
The `expected_decision: "hook_fired"` means either exit 0 or exit 2
confirms the hook ran — both are a pass.

**Alternatives considered**:

| Format | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **JSONL** | Streamable, aggregatable via jaq | Requires jaq | **Yes** |
| Markdown table | Human-readable | Hard to aggregate | No |
| JSON array | Parseable | Requires full file in memory | No |
| CSV | Simple | Type-lossy, no nesting | No |

**Rationale**: JSONL is streamable — agents write results
incrementally without buffering the entire run. The main agent
aggregates with `jaq -s '.'` after all agents complete.

### D8: Log Location — .claude/tests/hooks/results/

**Decision**: Log files are written to
`.claude/tests/hooks/results/` in the project root, named
`<agent-name>-<timestamp>.jsonl`.

```text
.claude/tests/hooks/results/
├── ml-agent-20260220T143022Z.jsonl
├── pm-agent-20260220T143022Z.jsonl
└── dep-agent-20260220T143022Z.jsonl
```

This directory must be created before agent execution
(`mkdir -p .claude/tests/hooks/results/`).

**Alternatives considered**:

| Location | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| `/tmp/` | No commit risk | Lost on reboot | No |
| `tests/hooks/results/` | Standard layout | New top-level dir | No |
| **`.claude/tests/hooks/results/`** | Near hook infra | — | **Yes** |
| `docs/specs/` | Near other specs | Wrong file type | No |

**Rationale**: Grouping under `.claude/` keeps test results
alongside the hook scripts and configuration they test. The
`.jsonl` extension is not linted by markdownlint-cli2.

### D9: Pass/Fail Criteria

**Decision**: A test case passes when ALL of the following hold:

1. **Exit code matches**: `actual_exit == expected_exit`
2. **Decision field matches**: For hooks that return JSON stdout
   (PreToolUse, Stop), `actual_decision == expected_decision`
   [verify: docs/README.md §Hook Schema Reference]
3. **Prefix present** (for block/violation cases): `actual_output`
   contains the expected `[hook:block]`, `[hook]`,
   `[hook:advisory]`, or `[hook:warning]` prefix as appropriate
   [verify: docs/README.md §Message Styling]

A test is **skipped** (not failed) when:

- An optional tool is absent AND the test gates on its presence
  (e.g., yamllint violation test skipped if yamllint absent)
- Exception: Biome absence is a **failure**, not a skip (per D4)

A test **fails** when:

- Any pass condition above is not met
- The hook script itself exits non-zero unexpectedly
  (set -e firing due to an unhandled error)
- The hook hangs and is killed by a timeout

**Suite-level pass**: The full run passes when `pass: true` for all
non-skipped records across all three JSONL files.

### D10: Teardown Policy

**Decision**:

- **All pass**: Main agent sends `shutdown_request` to all three
  teammates and calls `TeamDelete` to clean up the team session.
- **Any failure**: Team is left open for inspection. Main agent
  reports failures in chat with actionable items. `TeamDelete` is
  NOT called. User can re-examine agent state or rerun individual
  agents.

**Alternatives considered**:

| Policy | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| Always teardown | Clean sessions | Lose debug context on failure | No |
| Never teardown | Always debuggable | Orphaned sessions accumulate | No |
| **Clean→teardown, fail→keep** | Balanced | Slightly more logic | **Yes** |

**Rationale**: Auto-teardown on clean runs is CI-friendly and
avoids orphaned team sessions. Preserving the team on failure
allows the user to inspect which agent failed and why, without
requiring a full rerun.

### D11: Verification Marker Policy

**Decision**: Every factual claim in this ADR (and in the agent
implementation scripts) that asserts hook behavior, an
input/output contract, or an expected output value carries a
`[verify:]` marker referencing its authoritative source.

**Format**:

```text
[verify: <source>]
```

Where `<source>` is one of:

- A file and section: `docs/README.md §Dependencies`
- A script path: `.claude/hooks/multi_linter.sh §phase2`
- A spec reference: `adr-package-manager-enforcement.md §D12`
- `[verify: unresolved]` for claims that need investigation

**Policy**: No test case may be implemented without a `[verify:]`
marker that resolves to an actual line or section. Markers are the
bridge between this spec and the implementation. Resolving all
`[verify: unresolved]` markers is a gate for moving this ADR from
Proposed to Accepted. Resolved markers remain permanently in the
document as inline traceability links — when a referenced contract
changes, `grep '[verify:.*§Contract Name]'` finds all ADR claims
that depend on it. Resolution check: `grep '\[verify: unresolved\]'`
must return zero matches before acceptance.

## Complete Test Case Inventory

### ml-agent Test Cases (22 total)

All violation tests use `HOOK_SKIP_SUBPROCESS=1`
[verify: docs/README.md §Testing Environment Variables].
All rows verify against [verify: docs/README.md §Linter Behavior
by File Type]. M01–M02 also use [verify: docs/README.md
§Testing Hooks Manually]. M19 verifies
[verify: docs/README.md §Hook Invocation Behavior].

**Config-toggle tests (M20–M22)**: These tests use separate
`CLAUDE_PROJECT_DIR` overrides (one temp dir per test) to exercise
config-dependent code paths in `multi_linter.sh`. Each test creates a
`config.json` with the specified setting enabled. All use clean `.ts`
fixtures and expect exit 0 — the goal is verifying the config-reading
branch executes without error.
M20 verifies [verify: .claude/hooks/multi_linter.sh §_lint_typescript
`biome_unsafe_autofix` branch, §rerun_phase1 `_unsafe` flag].
M21 verifies [verify: .claude/hooks/multi_linter.sh §_lint_typescript
`oxlint_tsgolint` Biome --skip logic].
M22 is a defensive smoke test for deferred settings (tsgo, knip) that
have no implementation yet — confirms enabling them doesn't crash.

| ID | Name | Fixture | Expected |
| --- | --- | --- | --- |
| M01 | python_clean | Clean `.py` | exit 0 |
| M02 | python_f841 | Unused var | exit 2, `[hook]` |
| M03 | shell_clean | Clean `.sh` | exit 0 |
| M04 | shell_sc2086 | Unquoted `$VAR` | exit 2, `[hook]` |
| M05 | markdown_clean | Clean `.md` | exit 0 |
| M06 | markdown_md013 | Line >80 chars | exit 2, `[hook]` |
| M07 | yaml_clean | Clean `.yaml` | exit 0 |
| M08 | yaml_indent | Wrong indentation | exit 2, `[hook]` |
| M09 | toml_clean | Clean `.toml` | exit 0 |
| M10 | toml_invalid | Syntax error | exit 2, `[hook]` |
| M11 | json_clean | Valid `.json` | exit 0 |
| M12 | json_invalid | Malformed JSON | exit 2, `[hook]` |
| M13 | dockerfile_clean | Clean Dockerfile | exit 0 |
| M14 | dockerfile_dl3007 | `FROM ubuntu:latest` | exit 2, `[hook]` |
| M15 | ts_clean | Clean `.ts` | exit 0 |
| M16 | ts_unused_var | Unused variable | exit 2, `[hook]` |
| M17 | js_clean | Clean `.js` | exit 0 |
| M18 | css_clean | Clean `.css` | exit 0 |
| M19 | live_trigger | Edit `.py` via tool | hook fires |
| M20 | biome_unsafe_on | Clean `.ts` + `biome_unsafe_autofix: true` | exit 0 |
| M21 | oxlint_skip_rules | Clean `.ts` + `oxlint_tsgolint: true` | exit 0 |
| M22 | deferred_safe | Clean `.ts` + `tsgo: true, knip: true` | exit 0 |

### pm-agent Test Cases (28 total)

ADR-PM = `docs/specs/adr-package-manager-enforcement.md`

Block/approve cases verify [verify: ADR-PM §D3, §D4].
Allowlist cases verify [verify: ADR-PM §D9].
Compound cases verify [verify: ADR-PM §D7, §Note on independent
blocks for poetry/pipenv]. Config mode cases verify
[verify: ADR-PM §D9, §D2]. P18 verifies
[verify: .claude/hooks/enforce_package_managers.sh §exit].
P28 verifies [verify: docs/README.md §Hook Invocation Behavior].

| ID | Name | Command | Expected |
| --- | --- | --- | --- |
| P01 | pip_blocked | `pip install requests` | block |
| P02 | pip3_blocked | `pip3 install flask` | block |
| P03 | python_m_pip | `python -m pip install pkg` | block |
| P04 | python_m_venv | `python -m venv .venv` | block |
| P05 | poetry_blocked | `poetry add requests` | block |
| P06 | pipenv_blocked | `pipenv install` | block |
| P07 | npm_blocked | `npm install lodash` | block |
| P08 | npx_blocked | `npx create-react-app` | block |
| P09 | yarn_blocked | `yarn add lodash` | block |
| P10 | pnpm_blocked | `pnpm install` | block |
| P11 | uv_approve | `uv add requests` | approve |
| P12 | uv_pip_approve | `uv pip install -r req.txt` | approve |
| P13 | bun_approve | `bun add lodash` | approve |
| P14 | bunx_approve | `bunx vite` | approve |
| P15 | npm_audit_allowed | `npm audit` | approve |
| P16 | pip_download_allowed | `pip download requests` | approve |
| P17 | yarn_audit_allowed | `yarn audit` | approve |
| P18 | ls_passthrough | `ls -la` | approve |
| P19 | compound_pip_cd | `cd /app && pip install flask` | block |
| P20 | cpd_pip_poetry | `pip -V && poetry add req` | block |
| P21 | cpd_pipenv_diag | `pipenv -V && pipenv install` | block |
| P22 | cpd_pip_pipenv | `pip -V && pipenv install` | block |
| P23 | cpd_poet_diag | `poetry -h && poetry add req` | block |
| P24 | cpd_npm_yarn | `npm audit && yarn add pkg` | block |
| P25 | cfg_py_off | `pip install` + `python: false` | approve |
| P26 | cfg_py_warn | `pip install` + `"uv:warn"` | approve+adv |
| P27 | cfg_js_off | `npm install` + `js: false` | approve |
| P28 | live_trigger | `Bash pip install` via tool | hook blocks |

### dep-agent Test Cases (20 total)

README = `docs/README.md`

Required-tool checks (DEP01–DEP04) verify
[verify: README §Dependencies, README §claude Command Discovery].
Optional-tool checks (DEP05–DEP12) verify
[verify: README §Dependencies]. DEP09 additionally checks the
minimum version [verify: README §hadolint Version Check].
DEP13 verifies the no-hooks settings file
[verify: README §Subprocess Hook Prevention]. Settings keys
(DEP14–DEP17) verify [verify: .claude/settings.json].
Config keys (DEP18–DEP20) verify
[verify: README §Runtime Configuration,
README §Package Manager Enforcement].

| ID | Name | Check | Expected |
| --- | --- | --- | --- |
| DEP01 | jaq_present | `command -v jaq` | present |
| DEP02 | ruff_present | `command -v ruff` | present |
| DEP03 | uv_present | `command -v uv` | present |
| DEP04 | claude_present | PATH search | present |
| DEP05 | shfmt_opt | `command -v shfmt` | yes/no |
| DEP06 | shellcheck_opt | `command -v shellcheck` | yes/no |
| DEP07 | yamllint_opt | `command -v yamllint` | yes/no |
| DEP08 | hadolint_opt | `command -v hadolint` | yes/no |
| DEP09 | hadolint_ver | `hadolint --version` | ≥ 2.12.0 |
| DEP10 | taplo_opt | `command -v taplo` | yes/no |
| DEP11 | biome_opt | `command -v biome` | yes/no |
| DEP12 | semgrep_opt | `command -v semgrep` | yes/no |
| DEP13 | no_hooks | `no-hooks-settings.json` | exists |
| DEP14 | set_pre_edit | `settings.json` | `Edit\|Write` |
| DEP15 | set_pre_bash | `settings.json` | `Bash` |
| DEP16 | set_post | `settings.json` | `PostToolUse` |
| DEP17 | set_stop | `settings.json` | `Stop` present |
| DEP18 | cfg_json | `hooks/config.json` | exists |
| DEP19 | cfg_py_key | `config.json` | `pkg_mgrs.python` |
| DEP20 | cfg_js_key | `config.json` | `pkg_mgrs.js` |

## Main Agent Aggregation Logic

After all three agents write their JSONL logs, the main agent:

1. Reads all three JSONL files with `jaq -s '.'`
2. Counts `pass: true` and `pass: false` records
3. Lists all failing test names with their `note` field
4. Applies the D10 teardown policy
5. Returns a findings report with actionable items for any failures

**Aggregation command** (run by main agent after agents complete):

```bash
jaq -s '. as $all |
  ($all | map(select(.pass == false)) | length) as $fails |
  ($all | map(select(.pass == true)) | length) as $pass |
  {
    passed: $pass,
    failed: $fails,
    failures: (
      $all | map(select(.pass == false)) |
      map({hook, test_name, note})
    )
  }' \
  .claude/tests/hooks/results/*.jsonl
```

## Test Timeouts

Each test invocation uses a per-test timeout to prevent a single
hung test from blocking the entire suite.

| Layer | Timeout | Rationale |
| --- | --- | --- |
| Layer 1 (stdin/stdout) | 30s | Hooks run Phase 1+2 without subprocess; 30s is generous |
| Layer 2 (M19 live Edit) | 120s | PostToolUse may spawn subprocess (~25-30s typical) |
| Layer 2 (P28 live Bash) | 30s | PreToolUse blocks immediately, no subprocess |
| Suite-level backstop | 15 min | 70 tests × worst case; prevents runaway orchestration |

**Timeout mechanism**: Layer 1 tests use `timeout 30 bash
.claude/hooks/hook.sh`. Layer 2 timeouts are enforced by the
orchestrator's task management.

**Timeout behavior**: On timeout, mark the test as
`pass: false, note: "TIMEOUT_30s"` (or `TIMEOUT_120s`) and
continue to the next test. Do NOT abort the suite — collect
partial results.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Biome absent | Low | High | D4: fail TS tests explicitly |
| jaq absent | Low | High | DEP01 detects this first |
| hadolint version < 2.12.0 | Low | Med | DEP09 version check |
| config.json missing | Low | Med | DEP18 checks existence |
| HOOK_SKIP_SUBPROCESS not honored | Low | Med | Self-mitigating: all violation tests use this variable and expect exit 2 — if unhonored, every violation test fails [verify: docs/README.md §Testing Environment Variables] |
| TeamCreate session orphaned | Low | Low | D10 keep-on-failure policy |
| JSONL write race condition | Very Low | Low | One file per agent |

## Scope Boundaries

**In scope**:

- `multi_linter.sh` functional testing (all file types, M01–M19)
- `enforce_package_managers.sh` functional testing (P01–P28)
- Dependency presence and version auditing (DEP01–DEP20)
- Settings.json registration verification
- JSONL log production and main agent aggregation

**Out of scope**:

- `protect_linter_configs.sh` — covered by existing self-test
- `stop_config_guardian.sh` — requires interactive session restart
- CI integration of this test run (separate concern)
- Performance benchmarking (hook latency measurement)
- Test coverage of the test_hook.sh harness itself

## Config Coverage Analysis

The following table documents which `config.json` settings have
real code paths in `multi_linter.sh` and are therefore meaningful
to test:

| Setting | Config Path | Implemented? | Tested? |
| --- | --- | --- | --- |
| `biome_unsafe_autofix` | `languages.typescript.biome_unsafe_autofix` | **Yes** (2 branch points) | M20 |
| `oxlint_tsgolint` | `languages.typescript.oxlint_tsgolint` | **Partial** (Biome --skip only) | M21 |
| `tsgo` | `languages.typescript.tsgo` | **No** (deferred) | M22 (smoke) |
| `knip` | `languages.typescript.knip` | **No** (deferred) | M22 (smoke) |
| `jscpd.advisory_only` | `jscpd.advisory_only` | **Dead config** | — |

**Dead config finding**: `jscpd.advisory_only` is documented in
`docs/README.md` (line 890) as configurable, but `multi_linter.sh`
never reads this value. The jscpd advisory behavior is hardcoded —
both the Python path and the TypeScript path emit
`[hook:advisory]` messages without checking the config flag. Changing
this setting to `false` has zero effect. This should be either wired
into the code or removed from the config to avoid confusion.

## Consequences

### Positive

- Structured proof that all hooks work end-to-end (70 test cases)
- Machine-readable JSONL audit trail enables future CI integration
- Dependency health monitoring catches silent degradation
- Parallel execution via TeamCreate keeps total runtime manageable
- Verification markers provide traceability between spec and
  implementation

### Negative

- Maintenance burden: 70 test cases must be updated when hook
  behavior changes (mitigated by `[verify:]` markers that flag
  which tests depend on which contracts)
- TeamCreate dependency: test suite requires experimental agent
  teams feature (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`)
- Coupling: test case expectations are tightly coupled to hook
  output formats — format changes require test updates

### Neutral

- Does not replace `test_hook.sh --self-test` — the two suites
  are complementary (harness logic vs. integration behavior)
- JSONL logs accumulate in `.claude/tests/hooks/results/` and
  require periodic cleanup

## Implementation Checklist

- [ ] Create `.claude/tests/hooks/results/` directory
- [ ] Implement ml-agent (test cases M01–M19)
- [ ] Implement pm-agent (test cases P01–P28)
- [ ] Implement dep-agent (test cases DEP01–DEP20)
- [ ] Implement main agent aggregation and teardown logic
- [ ] Implement config-toggle tests M20–M22 (separate CLAUDE_PROJECT_DIR per test)
- [ ] Resolve all `[verify: unresolved]` markers before Accepted
- [ ] Confirm all 70 test cases produce JSONL records (including
  live trigger tests with `category: "live_trigger"` and config-toggle
  tests M20–M22)
- [ ] Confirm teardown/keep behavior per D10

---

## References

- [docs/README.md](../README.md) — Hook architecture and
  testing documentation
- [.claude/hooks/multi_linter.sh](../../.claude/hooks/multi_linter.sh)
  — PostToolUse hook implementation
- [.claude/hooks/enforce_package_managers.sh](../../.claude/hooks/enforce_package_managers.sh)
  — PreToolUse Bash hook implementation
- [.claude/hooks/test_hook.sh](../../.claude/hooks/test_hook.sh)
  — Existing self-test suite (~96 tests)
- [.claude/settings.json](../../.claude/settings.json)
  — Hook registration
- [adr-package-manager-enforcement.md](adr-package-manager-enforcement.md)
  — PM enforcement decisions referenced as ADR-PM
- [adr-hook-schema-convention.md](adr-hook-schema-convention.md)
  — JSON schema convention for all hooks
- [jaq GitHub repository (jq alternative used in aggregation)](https://github.com/01mf02/jaq)
- [jq 1.8 Manual (current)](https://jqlang.org/manual/)
- [hadolint DL3007 rule source](https://github.com/hadolint/hadolint/blob/master/src/Hadolint/Rule/DL3007.hs)
