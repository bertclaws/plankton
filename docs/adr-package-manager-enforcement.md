# ADR: Package Manager Enforcement via PreToolUse Hook

**Status**: Proposed
**Date**: 2026-02-16
**Author**: alex fazio + Claude Code clarification interview

## Context and Problem Statement

Claude Code sessions frequently use `pip`, `npm`, `yarn`, or `pnpm` for
package management instead of the project's preferred toolchain (`uv` for
Python, `bun` for JS/TS). This creates inconsistent lockfiles, mixed
dependency trees, and slower installations. There is no enforcement
mechanism to prevent Claude from defaulting to the ecosystem-standard
tools rather than the project-preferred alternatives.

Claude defaults to widely-known package managers (`pip install`,
`npm install`) unless explicitly instructed otherwise. CLAUDE.md
instructions alone are insufficient because Claude may not always follow
soft guidance, especially in long sessions or after context compaction.
The existing hook architecture only enforces linter config protection
(PreToolUse) and code quality (PostToolUse), but has no Bash command
interception for package manager enforcement.

## Decision Drivers

- **Consistency**: One lockfile format, one dependency tree, one installer
  per ecosystem
- **Performance**: `uv` is 10-100x faster than pip; `bun` is significantly
  faster than npm
- **Existing patterns**: Follow the established PreToolUse block+message
  pattern from `protect_linter_configs.sh`
- **Configurability**: All enforcement controllable via `config.json`
  (existing configuration pattern)
- **Graceful degradation**: Enforcement can be disabled per ecosystem
- **Compound command safety**: Must catch package managers inside compound
  commands (`cd foo && pip install bar`)

## Decisions

### D1: Hook Type - PreToolUse with Bash Matcher

**Decision**: Use a PreToolUse hook with `"matcher": "Bash"` to intercept
commands before execution.

**Alternatives considered**:

| Approach | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **PreToolUse Bash** | Prevents wrong command | New settings entry | **Yes** |
| **Stop hook** | Simpler lifecycle | Damage done (lockfiles, env) | No |
| **CLAUDE.md only** | Zero effort | Soft, ignored in long sessions | No |
| **PostToolUse Bash** | Detect after | Too late, side effects done | No |

**Rationale**: The Stop hook pattern (detect-then-recover) does not fit
because by session end, `pip install` has already polluted the environment,
created wrong lockfiles, and installed into the wrong location. Prevention
is the correct strategy, matching the existing defense pattern: PreToolUse
for prevention (`protect_linter_configs.sh`), Stop for recovery
(`stop_config_guardian.sh`).

### D2: Block Mode - Block + Suggest (Not Auto-Rewrite)

**Decision**: Block the command and suggest the correct replacement in the
error message. Do not attempt to auto-rewrite the command.

**Rationale**:

1. Command flag mapping between package managers is non-trivial
   (`npm install --save-dev` flags do not 1:1 map to `bun add --dev`
   in all cases)
2. Silent rewriting could produce subtly wrong commands
3. The agent has full context to reformulate correctly after receiving
   the block message
4. Matches the existing config protection hook philosophy: "Fix the code,
   not the rules" becomes "Use the right tool, don't rewrite the wrong one"

### D3: Python Enforcement Scope

**Decision**: Block `pip`, `pip3`, `python -m pip`, `python -m venv`,
`poetry`, and `pipenv`. Allow `uv pip` passthrough since `uv pip install`
is a valid uv command (pip compatibility mode).

**Commands blocked**:

| Blocked Command | Suggested Replacement | Notes |
| --- | --- | --- |
| `pip install <pkg>` | `uv add <pkg>` | Direct replacement |
| `pip install -r reqs.txt` | `uv pip install -r reqs.txt` | uv compat |
| `pip3 install <pkg>` | `uv add <pkg>` | pip3 alias |
| `python -m pip install <pkg>` | `uv add <pkg>` | Module invocation |
| `python -m venv .venv` | `uv venv` | Significantly faster |
| `poetry <any>` | `uv` equivalents | Blanket block (all subcommands) |
| `pipenv <any>` | `uv` equivalents | Blanket block (all subcommands) |
| `pip install -e .` | `uv pip install -e .` | Editable install |
| `pip freeze` | `uv pip freeze` | Read-only (still blocked) |
| `pip list` | `uv pip list` | Read-only (still blocked) |

**All pip subcommands are blocked** unless prefixed by `uv` or listed in the
configurable `allowed_subcommands.pip` allowlist (see D9). By default, only
`pip download` is allowlisted because it has no `uv` equivalent
(tracked in [astral-sh/uv#3163](https://github.com/astral-sh/uv/issues/3163)).
Read-only commands like `pip freeze` and `pip list` are blocked because
`uv pip freeze` and `uv pip list` are direct replacements with identical
output.

**Poetry and pipenv are blanket-blocked**: All subcommands are blocked by
default (empty allowlist in `allowed_subcommands.poetry` and
`allowed_subcommands.pipenv`). This is simpler and more secure than
enumerating specific subcommands — `poetry show`, `poetry env use`, and
any future subcommands are all caught. Specific exceptions can be added
to the allowlist arrays in `config.json` if needed.

**Allowed (not blocked)**:

| Command | Why Allowed |
| --- | --- |
| `uv pip install` | Valid uv command (pip compatibility mode) |
| `uv add`, `uv sync`, `uv run` | Preferred toolchain |
| `source .venv/bin/activate` | Activation is fine; creation goes through uv |
| `python script.py` | Runtime, not package management |
| `pip download` | Allowlisted — no uv equivalent ([#3163](https://github.com/astral-sh/uv/issues/3163)) |

**Matching strategy**: Uses conditional bash matching — check for `uv pip`
prefix first (passthrough), then check for bare `pip`/`pip3`. Word
boundaries use POSIX ERE character classes, not PCRE `\b` (which is
unavailable in bash `=~` on macOS). See "Regex Patterns" section for
portable implementation.

### D4: JavaScript Enforcement Scope

**Decision**: Block ALL npm, npx, yarn, and pnpm commands except a
configurable allowlist of npm-registry-specific subcommands.

**Commands blocked**:

| Blocked Command | Suggested Replacement |
| --- | --- |
| `npm install` / `npm i` / `npm ci` | `bun install` or `bun add <pkg>` |
| `npm run <script>` | `bun run <script>` |
| `npm test` | `bun test` |
| `npm start` | `bun run start` |
| `npm exec` / `npx <pkg>` | `bunx <pkg>` |
| `npm init` | `bun init` |
| `npm uninstall` / `npm remove` | `bun remove` |
| `yarn <subcommand>` (except audit, info) | bun equivalents |
| `pnpm <subcommand>` (except audit, info) | bun equivalents |

**Rationale for blocking script runners** (`npm run`, `npm test`,
`npm start`): If you are standardizing on bun, partial enforcement creates
confusion about which npm commands are acceptable. `bun run`, `bun test`
are direct replacements. Consistent enforcement is simpler to reason about.

**npm registry allowlist** (configurable in `allowed_subcommands.npm`,
see D9):

| Allowed Subcommand | Bun Equivalent | Status |
| --- | --- | --- |
| `npm audit` | `bun audit` (v1.2.15) | Bun equivalent available |
| `npm view` | `bun info` / `bun pm view` | Bun equivalent available |
| `npm pack` | `bun pm pack` (v1.1.27) | Bun equivalent available |
| `npm publish` | `bun publish` | Bun equivalent available |
| `npm whoami` | `bun pm whoami` (v1.1.30) | Bun equivalent available |
| `npm login` | — | No bun equivalent |

These commands do not affect the dependency tree — they are
registry/metadata operations. Five of six now have bun equivalents
(bun pm pack since v1.1.27, bun publish since v1.1.30, bun pm whoami
since v1.1.30, bun audit since v1.2.15, bun pm view since v1.2.15),
but the allowlist is kept as-is because:
(1) bun equivalents are recent and may have edge cases, (2) allowing
registry operations doesn't violate the core enforcement goal, (3)
shrinking is easy when bun matures, expanding after a bug is disruptive.
Review allowlist when bun reaches 2.x stable.

**yarn/pnpm registry allowlist** (configurable in `allowed_subcommands.yarn`
and `allowed_subcommands.pnpm`, see D9): `yarn audit`, `yarn info`,
`pnpm audit`, and `pnpm info` are allowed by default for registry
inspection. Bare `yarn` and bare `pnpm` (no subcommand) are blocked
because they are equivalent to `yarn install` and `pnpm install`
respectively.

### D5: npx and Internal Hook Usage

**Decision**: npx is blocked for Claude's Bash tool invocations. Internal
hook usage of npx (e.g., `npx jscpd` in `multi_linter.sh`) is unaffected.

**Rationale**: Hook scripts run as bash processes outside of Claude's Bash
tool. The PreToolUse hook only fires on Claude's own Bash tool invocations
via the Claude Code hook lifecycle, not on shell commands within hook
scripts. The subprocess also uses `--settings no-hooks-settings.json`
which disables hooks entirely. Internal npx usage in hooks is inherently
safe from this enforcement.

### D6: Runtime Scope - Package Managers Only

**Decision**: Do not block `node` runtime invocations. Only block package
manager commands.

**Alternatives considered**: Blocking `node script.js` in favor of
`bun script.js` for runtime performance.

**Rationale**: `node` appears in too many legitimate contexts
(`node --version`, shebang lines, debugging). The benefit of
bun-as-runtime is speed (nice-to-have), while package manager enforcement
is about consistency (lockfile format, dependency tree - a correctness
concern). The risk-to-benefit ratio for runtime enforcement is too high.

### D7: Compound Command Handling

**Decision**: Scan the entire `tool_input.command` string using substring
matching with word boundaries. Do not only check the first command in a
pipeline or chain.

**Rationale**: Claude frequently generates compound commands like:

```bash
cd /path && pip install -r requirements.txt
if ! pip list | grep pkg; then pip install pkg; fi
npm install && npm run build
```

Checking only the first command is trivially bypassable. False positives
from substrings are handled with word boundary matching via POSIX ERE
character classes (see "Regex Patterns" section).

**Known limitations**: Full command string scanning may produce false
positives in these edge cases:

- Here-docs: `cat <<EOF\npip install foo\nEOF` — blocked even though
  `cat` is the actual command
- Comments: `# pip install foo` — blocked even though it's a comment
- Quoted strings: `echo "pip install foo"` — blocked even though it's
  a string literal
- Variable assignments: `PKG_MGR=pip` — not blocked (no word boundary
  match on `pip` as a standalone command)
- Diagnostic flags in Python compound commands:
  `pip --version && poetry add requests` — `pip --version` matches the
  diagnostic carve-out, the elif chain exits, and `poetry add` is not
  checked. Same category as the `uv pip` compound limitation (the elif
  chain is one-shot). JS tools are unaffected (independent if blocks).

These are accepted trade-offs. In practice, Claude rarely generates
commands with package manager names in comments or here-docs. The
pragmatic substring approach catches 99%+ of real cases.

**Compound command behavior**: When a command contains multiple package
manager violations (e.g., `pip install && npm install`), the hook blocks on
the first match and returns immediately. Claude retries and hits the second
violation on the next attempt. This is consistent with
`protect_linter_configs.sh` (which returns immediately on first path match)
and avoids the complexity of multi-error collection in a PreToolUse hook.

### D8: Message Style

**Decision**: Adopt the `[hook:]` message prefix style used by
`multi_linter.sh`, extending it with a new `block` severity level.

**Format**:

```text
[hook:block] pip is not allowed. Use: uv add <packages>
```

Where:

- `[hook:block]` prefix extends `[hook:]` conventions (new severity
  for PreToolUse blocks)
- The blocked tool name is stated
- The specific replacement command is provided (computed from the
  blocked command, not just the tool name)
- Message is concise (single line when possible)

**Replacement command specificity**: The block message includes the
specific replacement command computed from the blocked command. For
example:

- `pip install requests flask` -> `Use: uv add requests flask`
- `pip install -r requirements.txt` ->
  `Use: uv pip install -r requirements.txt`
- `npm install lodash` -> `Use: bun add lodash`
- `npx create-react-app` -> `Use: bunx create-react-app`

### D9: Configuration Design

**Decision**: Top-level `package_managers` key in `config.json` with
lightweight toggles (not a full command mapping).

**Schema**:

```json
{
  "package_managers": {
    "python": "uv",
    "javascript": "bun",
    "allowed_subcommands": {
      "npm": ["audit", "view", "pack", "publish", "whoami", "login"],
      "pip": ["download"],
      "yarn": ["audit", "info"],
      "pnpm": ["audit", "info"],
      "poetry": [],
      "pipenv": []
    }
  }
}
```

**Toggle behavior**:

- `"python": "uv"` — enforce uv, block pip/poetry/pipenv
- `"python": false` — disable Python package manager enforcement
- `"javascript": "bun"` — enforce bun, block npm/yarn/pnpm
- `"javascript": false` — disable JS package manager enforcement

**Allowlist behavior**: The `allowed_subcommands` object provides a
unified configurable allowlist for every blocked tool. Each key maps a
tool name to an array of allowed subcommands. An empty array (`[]`)
means blanket block (no exceptions). When a blocked tool's subcommand
appears in its allowlist, the hook approves the command. Every tool
follows the same enforcement pattern: extract subcommand → check
allowlist → block if not found.

**Unified helper function**:

```bash
is_allowed_subcommand() {
  local tool="$1" subcmd="$2"
  local allowed
  while IFS= read -r allowed; do
    [[ "${subcmd}" == "${allowed}" ]] && return 0
  done < <(jaq -r ".package_managers.allowed_subcommands.${tool} // [] | .[]" \
    "${config_file}" 2>/dev/null)
  return 1
}
```

**Rationale**: The actual blocked patterns and suggestion messages stay
hardcoded in the script (domain knowledge). Config controls enforcement
toggles and per-tool subcommand exemptions. This unifies three prior
patterns into one: npm had a configurable allowlist
(`npm_allowed_subcommands`), yarn/pnpm had hardcoded `case` statements,
and pip/poetry/pipenv had no allowlist mechanism. Now all six tools use
the same `is_allowed_subcommand()` helper with config-driven arrays.

**Design note — config value types**: The `package_managers` section uses
string values (`"uv"`, `"bun"`) rather than the boolean toggles used in
`languages` (e.g., `"python": true`). This is intentional: the string
value serves a dual purpose — it enables enforcement AND names the
replacement tool used in block messages. `false` disables enforcement.
The accessor pattern differs from `is_language_enabled()`:

```bash
get_pm_enforcement() {
  local lang="$1"
  jaq -r ".package_managers.${lang} // false" \
    "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json" 2>/dev/null
}
# Returns "uv", "bun", or "false"
```

### D10: Default State

**Decision**: Enabled by default in the template.

**Rationale**: Unlike TypeScript support (which requires Biome installation
and is opt-in), package manager enforcement has no external dependencies.
It only requires that the user has `uv` and/or `bun` installed, which is
a prerequisite for the project's intended workflow. Users who do not want
enforcement can set `"python": false` or `"javascript": false`.

The template ships with `"python": "uv"` and `"javascript": "bun"` in
`config.json`. If the `package_managers` key is absent or the config file
is missing, enforcement is disabled (fail-open via `// false` jaq
fallback), consistent with the script's fail-safe philosophy. "Enabled by
default" refers to the template's shipped configuration, not to hardcoded
script behavior.

### D11: Architecture - Separate Script File

**Decision**: Create a new file `.claude/hooks/enforce_package_managers.sh`,
registered as a separate PreToolUse entry in `.claude/settings.json` with
`"matcher": "Bash"`.

**Alternatives considered**: Combining with
`protect_linter_configs.sh` in a single script.

**Rationale**: A combined PreToolUse script will not work cleanly because
the matchers are different. `protect_linter_configs.sh` matches
`Edit|Write`; the new hook needs to match `Bash`. Separate entries in
`settings.json` are required regardless. Benefits of separation:

1. Independent testing (can test package manager logic in isolation)
2. Independent disabling (can remove one hook without affecting the other)
3. Separation of concerns (file protection vs command interception)
4. Cleaner codebase (each script has a single responsibility)

### D12: Testing Strategy

**Decision**: Full self-test coverage added to `test_hook.sh` covering
all enforcement scenarios.

**Test cases required**:

| Test | Input | Expected |
| --- | --- | --- |
| pip install blocked | `pip install requests` | block + suggest `uv add` |
| pip3 blocked | `pip3 install flask` | block |
| python -m pip blocked | `python -m pip install pkg` | block |
| python -m venv blocked | `python -m venv .venv` | block + suggest `uv venv` |
| poetry blocked | `poetry add requests` | block |
| pipenv blocked | `pipenv install` | block |
| uv pip passthrough | `uv pip install -r req.txt` | approve |
| uv add passthrough | `uv add requests` | approve |
| npm install blocked | `npm install lodash` | block + suggest `bun add` |
| npm run blocked | `npm run build` | block + suggest `bun run` |
| npx blocked | `npx create-react-app` | block + suggest `bunx` |
| yarn blocked | `yarn add lodash` | block |
| pnpm blocked | `pnpm install` | block |
| npm audit allowed | `npm audit` | approve (allowlisted) |
| npm view allowed | `npm view lodash` | approve (allowlisted) |
| compound pip | `cd /app && pip install flask` | block |
| compound npm | `npm install && npm run build` | block |
| bun passthrough | `bun add lodash` | approve |
| bunx passthrough | `bunx vite` | approve |
| python disabled | `pip install` (python: false) | approve |
| javascript disabled | `npm install` (javascript: false) | approve |
| pip freeze blocked | `pip freeze` | block + suggest `uv pip freeze` |
| pip list blocked | `pip list` | block + suggest `uv pip list` |
| pip editable blocked | `pip install -e .` | block + suggest uv pip |
| jaq missing | `pip install` (jaq unavailable) | approve (fail-open) |
| non-package cmd | `ls -la` | approve |
| bare yarn blocked | `yarn` | block (bare = install) |
| bare pnpm blocked | `pnpm` | block (bare = install) |
| yarn audit allowed | `yarn audit` | approve (allowlisted) |
| yarn info allowed | `yarn info lodash` | approve (allowlisted) |
| pnpm audit allowed | `pnpm audit` | approve (allowlisted) |
| pnpm info allowed | `pnpm info lodash` | approve (allowlisted) |
| npm audit+yarn bypass | `npm audit && yarn add lodash` | block (yarn) |
| npm flags before subcmd | `npm -g install foo` | block |
| npm --registry flag | `npm --registry=... install foo` | block |
| bare npm | `npm` | block |
| poetry show blocked | `poetry show` | block (blanket) |
| poetry env blocked | `poetry env use 3.11` | block (blanket) |
| bare poetry blocked | `poetry` | block (blanket) |
| pipenv graph blocked | `pipenv graph` | block (blanket) |
| pip download allowed | `pip download requests` | approve (allowlisted) |
| pip download -d allowed | `pip download -d ./pkgs requests` | approve |
| cross-ecosystem compound | `pip install && npm install` | block (pip first) |
| uv + pip compound | `uv pip install && pip install` | approve (elif) |
| npm --version diag | `npm --version` | approve (diagnostic) |
| pip --version diag | `pip --version` | approve (diagnostic) |
| poetry --help diag | `poetry --help` | approve (diagnostic) |
| npm --version compound | `npm --version && npm install` | block (install) |
| npm flag+allowlist | `npm --registry=url audit` | approve (flag+allowlisted) |
| npm -g install | `npm -g install foo` | block (flag+blocked subcmd) |
| pip diag+poetry compound | `pip --version && poetry add` | approve (elif) |
| uv missing warning | `pip install` (uv not in PATH) | block + stderr warning |
| bun missing warning | `npm install` (bun not in PATH) | block + warning |
| debug mode output | `pip install` (HOOK_DEBUG_PM=1) | block + stderr debug |
| HOOK_SKIP_PM bypass | `pip install` (HOOK_SKIP_PM=1) | approve |

## Settings Registration

The new hook is registered as a second PreToolUse entry in
`.claude/settings.json`.

**Note**: This is a partial snippet showing only the new PreToolUse entry
to add to the existing `PreToolUse` array. Existing `PostToolUse`
(multi_linter.sh) and `Stop` (stop_config_guardian.sh) entries remain
unchanged. See `.claude/settings.json` for the complete configuration.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/protect_linter_configs.sh",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/enforce_package_managers.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

## Script Architecture

### Script Conventions

The script must follow these conventions from the existing codebase:

- **Preamble**: `set -euo pipefail` (required, matches all existing hooks)
- **Exit code**: Always exit 0. Use JSON stdout for the decision, matching
  `protect_linter_configs.sh` convention. Do NOT use the exit-code-based
  approach (exit 2 = block) shown in some Claude Code documentation
  examples — the project standardizes on JSON stdout + exit 0
- **Hook schema convention**: Uses `{"decision": "approve|block"}` convention
  matching `protect_linter_configs.sh`, not the official Claude Code
  `permissionDecision: "allow|deny|ask"` schema. This is intentional:
  (1) cross-hook consistency within the project, (2) no `ask` use case
  for binary enforcement decisions, (3) schema migration across all hooks
  is a separate concern if needed later
- **Fail-open**: If `jaq` is missing, input JSON is malformed, or any
  parsing error occurs, output `{"decision": "approve"}` and exit 0.
  A broken hook must not block all Bash commands. This matches the
  fail-open pattern in `protect_linter_configs.sh` (lines 19-23)
- **Config loading**: Use `"${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"`
  for config file path (not relative paths). `CLAUDE_PROJECT_DIR` is set
  by Claude Code runtime to the project root
- **Debug output**: `HOOK_DEBUG_PM=1` logs matching decisions to stderr
  (consistent with `HOOK_DEBUG_MODEL` in `multi_linter.sh`). Example output:
  `[hook:debug] PM check: command='pip install flask', action='block'`
- **Auto-protection**: The new script at `.claude/hooks/enforce_package_managers.sh`
  is automatically protected from modification by the existing
  `protect_linter_configs.sh` which blocks edits to all `.claude/hooks/*` files

### Input/Output Contract

**Input** (stdin JSON from Claude Code runtime):

```json
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "pip install requests flask"
  }
}
```

**Output** (stdout JSON per PreToolUse spec — always exit 0):

```json
{"decision": "approve"}
```

or:

```json
{"decision": "block", "reason": "[hook:block] pip is not allowed. Use: uv add requests flask"}
```

### Processing Flow

```text
1. Read stdin JSON (fail-open: approve if empty or malformed)
2. Extract tool_input.command via jaq (fail-open: approve if jaq missing)
3. Load ${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json
   -> package_managers section (fail-open: use defaults if missing)
4. If python enforcement enabled (value != "false"):
   a. Check for uv prefix (passthrough if found — elif chain required)
   b. Match pip/pip3: extract subcommand, check allowed_subcommands.pip
   b2. Diagnostic flags (--version, -v, -V, --help, -h): no-op
       (elif chain exits, preventing bare-pip block)
   c. Match python -m pip / python -m venv
   d. Match poetry: extract subcommand, check allowed_subcommands.poetry
   d2. Poetry diagnostic flags: no-op
   e. Match pipenv: extract subcommand, check allowed_subcommands.pipenv
   e2. Pipenv diagnostic flags: no-op
   f. If matched and not allowlisted: block with message
   Note: Python uses elif chain (not separate if blocks) because
   "uv pip" contains substring "pip" — separate blocks would
   false-positive on uv commands. Diagnostic no-ops inside the
   elif chain mean `pip --version && poetry add` misses poetry
   (accepted limitation — see D7).
5. If javascript enforcement enabled (value != "false"):
   Each JS tool checked independently (separate if blocks, NOT elif):
   a. npm: extract subcommand, check allowed_subcommands.npm;
      then try flag+subcommand extraction (npm -g install → extract
      subcommand after flags, check allowlist); then diagnostic
      flags (no-op); then bare flag catch; then bare npm
   b. npx: diagnostic flags (no-op); then block (suggest bunx)
   c. yarn: extract subcommand, check allowed_subcommands.yarn;
      diagnostic flags (no-op); bare yarn = yarn install (block)
   d. pnpm: extract subcommand, check allowed_subcommands.pnpm;
      diagnostic flags (no-op); bare pnpm = pnpm install (block)
   Independent checks prevent allowlist bypass in compound commands
   (e.g., npm audit && yarn add bypassed the old elif chain).
   Diagnostic no-ops in JS if blocks safely continue to next tool.
6. If no match: approve
7. Always exit 0 (JSON stdout carries the decision)
```

### Regex Patterns (Bash ERE)

All patterns use POSIX Extended Regular Expressions (ERE) compatible with
bash `=~` on macOS and Linux. PCRE features (lookbehinds, lookaheads,
`\b` word boundaries) are **not used** because:

- bash `=~` uses ERE, not PCRE
- macOS ships BSD grep without `-P` (PCRE) support
- `\b` is unreliable in bash `=~` across platforms

Word boundaries use character class alternatives:
`(^|[^a-zA-Z0-9_])` for start, `([^a-zA-Z0-9_]|$)` for end.

**Python enforcement** — elif chain (required because `uv pip` contains
substring `pip`; separate if blocks would false-positive on uv commands):

```bash
WB_START='(^|[^a-zA-Z0-9_])'
WB_END='([^a-zA-Z0-9_]|$)'

# Step 1: Check for uv pip prefix -> passthrough (approve)
if [[ "${command}" =~ ${WB_START}uv[[:space:]]+pip ]]; then
  approve  # uv pip install, uv pip freeze, etc.

# Step 2: pip/pip3 -> extract subcommand, check allowlist
elif [[ "${command}" =~ ${WB_START}pip3?[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "pip" "${subcmd}" || block "pip" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}pip3?[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # pip diagnostic — no-op (elif chain exits without blocking)
elif [[ "${command}" =~ ${WB_START}pip3?${WB_END} ]]; then
  block "pip"  # bare pip

# Step 3: python -m pip -> block
elif [[ "${command}" =~ ${WB_START}python3?[[:space:]]+-m[[:space:]]+pip${WB_END} ]]; then
  block "python -m pip"

# Step 4: python -m venv -> block
elif [[ "${command}" =~ ${WB_START}python3?[[:space:]]+-m[[:space:]]+venv${WB_END} ]]; then
  block "python -m venv"

# Step 5: poetry -> blanket block with allowlist
elif [[ "${command}" =~ ${WB_START}poetry[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "poetry" "${subcmd}" || block "poetry" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}poetry[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # poetry diagnostic — no-op
elif [[ "${command}" =~ ${WB_START}poetry${WB_END} ]]; then
  block "poetry"  # bare poetry

# Step 6: pipenv -> blanket block with allowlist
elif [[ "${command}" =~ ${WB_START}pipenv[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "pipenv" "${subcmd}" || block "pipenv" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}pipenv[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # pipenv diagnostic — no-op
elif [[ "${command}" =~ ${WB_START}pipenv${WB_END} ]]; then
  block "pipenv"  # bare pipenv
fi
```

**Note on elif chain**: The Python enforcement MUST use an elif chain
(not separate if blocks) because `uv pip` contains the substring `pip`.
With separate if blocks, the bare `pip` check would false-positive on
`uv pip install`. The elif ordering (check `uv pip` first, then bare
`pip`) is essential. Two compound command edge cases are accepted as
known limitations (both are unrealistic in practice):

- `uv pip install && pip install` — `uv pip` match approves, bare
  `pip install` unchecked
- `pip --version && poetry add` — pip diagnostic no-op exits the elif
  chain, `poetry add` unchecked

**JavaScript enforcement** — independent if blocks per tool (NOT elif):

Each JS package manager is checked independently. This prevents the
allowlist bypass where `npm audit && yarn add malicious-pkg` was approved
because the npm allowlist match exited the elif chain before yarn was
checked. With independent if blocks, an allowlist hit continues to the
next tool check; only a block hit exits immediately.

```bash
# Each JS PM checked independently — block exits, allowlist continues

# npm (independent check)
if [[ "${command}" =~ ${WB_START}npm[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "npm" "${subcmd}" || block "npm" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}npm[[:space:]]+-[^[:space:]]*[[:space:]]+([a-zA-Z]+) ]]; then
  # flags before subcommand — extract subcommand after flags, check allowlist
  # npm -g install → captures "install" → not allowlisted → block
  # npm --registry=url audit → captures "audit" → allowlisted → approve
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "npm" "${subcmd}" || block "npm" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}npm[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # npm diagnostic — continue to next tool check
elif [[ "${command}" =~ ${WB_START}npm[[:space:]]+- ]]; then
  block "npm"  # unrecognized flags with no subcommand after
elif [[ "${command}" =~ ${WB_START}npm${WB_END} ]]; then
  block "npm"  # bare npm
fi

# npx (independent check)
if [[ "${command}" =~ ${WB_START}npx[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # npx diagnostic — continue to next tool check
elif [[ "${command}" =~ ${WB_START}npx${WB_END} ]]; then
  block "npx"  # suggest bunx
fi

# yarn (independent check — not elif from npm)
if [[ "${command}" =~ ${WB_START}yarn[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "yarn" "${subcmd}" || block "yarn" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}yarn[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # yarn diagnostic — continue to next tool check
elif [[ "${command}" =~ ${WB_START}yarn${WB_END} ]]; then
  block "yarn" "install"  # bare yarn = yarn install
fi

# pnpm (independent check — not elif from yarn)
if [[ "${command}" =~ ${WB_START}pnpm[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "pnpm" "${subcmd}" || block "pnpm" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}pnpm[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # pnpm diagnostic — continue to next tool check
elif [[ "${command}" =~ ${WB_START}pnpm${WB_END} ]]; then
  block "pnpm" "install"  # bare pnpm = pnpm install
fi
```

**Design note — why JS uses separate if blocks but Python uses elif**:
JavaScript tools (npm, yarn, pnpm) are independent names with no
substring aliasing — `npm` is never a substring of `yarn`. Separate if
blocks are safe and required to prevent compound command bypass. Python
tools have substring aliasing: `uv pip` contains `pip`. Separate if
blocks would false-positive `uv pip install` as a bare `pip` invocation.
The Python elif chain ordering (check `uv pip` first, then bare `pip`)
is essential. See "Note on elif chain" above.

**Design note — npm flag+subcommand extraction**: The npm block includes
a flag-then-subcommand regex (`npm -flag subcmd`) that extracts the
subcommand after flags and checks the allowlist. This prevents blocking
legitimate allowlisted commands with flag prefixes
(`npm --registry=url audit` → approve) while still catching violations
(`npm -g install` → block). The pattern `-[^[:space:]]*[[:space:]]+`
matches one flag token (dash + non-spaces + space) before the subcommand.
Diagnostic flags (`--version`, `--help`) are handled by a separate
no-op branch that fires before the blanket flag catch.

### Replacement Command Computation

The script extracts the packages/arguments from the blocked command and
constructs the replacement:

| Pattern | Extraction | Replacement |
| --- | --- | --- |
| `pip install <pkgs>` | `<pkgs>` | `uv add <pkgs>` |
| `pip install -r <file>` | `-r <file>` | `uv pip install -r <file>` |
| `pip install -e .` | `-e .` | `uv pip install -e .` |
| `pip uninstall <pkgs>` | `<pkgs>` | `uv remove <pkgs>` |
| `pip freeze` | - | `uv pip freeze` |
| `pip list` | - | `uv pip list` |
| `python -m venv <dir>` | `<dir>` | `uv venv <dir>` (or `uv venv`) |
| `npm install <pkg>` | `<pkg>` | `bun add <pkg>` |
| `npm install` (no args) | - | `bun install` |
| `npm run <script>` | `<script>` | `bun run <script>` |
| `npm test` | - | `bun test` |
| `npx <pkg>` | `<pkg>` | `bunx <pkg>` |

For compound commands where extraction is ambiguous, the message suggests
the general replacement tool without attempting to rewrite the full
compound command.

### Replacement Tool Existence Check

When blocking a command and suggesting a replacement, the hook checks (once
per session) whether the replacement tool is installed. If the replacement
tool is missing, the hook still blocks the command but appends a warning to
stderr on first occurrence:

```bash
# Session-scoped warning for missing replacement tool
if ! command -v uv >/dev/null 2>&1; then
  local marker="/tmp/.pm_warn_uv_${HOOK_GUARD_PID:-${PPID}}"
  if [[ ! -f "${marker}" ]]; then
    echo "[hook:warning] uv not found — pip blocked but replacement unavailable. Install: brew install uv" >&2
    touch "${marker}"
  fi
fi
```

**Rationale**: Without this check, Claude receives a block message saying
"use uv instead" but has no way to know uv is not installed. The result is a
frustrating loop: Claude tries `uv`, gets "command not found", and has no
remediation path. The warning provides actionable feedback. The command is
still blocked regardless — policy enforcement is unconditional. This follows
the established pattern from `multi_linter.sh` (hadolint version warning).

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| False positive on substring | Low | Low | ERE word boundary classes |
| Compound cmd false positives | Low | Med | Documented known limitations |
| npm allowlist too restrictive | Low | Low | Configurable via config.json |
| New package managers emerge | Low | Low | Designed for extension |
| jaq unavailable on system | Low | Med | Fail-open: approve all |
| Here-doc/comment false match | Low | Low | Accepted trade-off (see D7) |

**Note**: PCRE portability is **not** a risk — all patterns use POSIX ERE
natively in bash `=~`. This was a deliberate design choice (see "Regex
Patterns" section). The risk was eliminated by design rather than mitigated.

## Scope Boundaries

**In scope**:

- Package manager enforcement (pip, npm, yarn, pnpm, poetry, pipenv)
- Configurable per-ecosystem toggles
- npm registry allowlist
- Compound command detection
- Full test coverage in test_hook.sh

**Out of scope**:

- Runtime enforcement (blocking `node` in favor of `bun`)
- Build tool enforcement (blocking `webpack` in favor of `vite`)
- Other ecosystem tools (conda, brew, cargo, gem, go get) — conda
  operates its own environment and dependency resolution system orthogonal
  to pip/uv; replacing it requires a different toolchain migration (e.g.,
  to pixi/rattler), not a simple command substitution. brew/cargo/gem/go
  are unrelated ecosystems
- Lock file migration tooling
- CLAUDE.md documentation updates (this ADR serves as documentation)

## Rollback and Emergency Disable

Three methods for disabling enforcement, ordered by granularity:

1. **Per-ecosystem toggle** (config.json): Set `"python": false` or
   `"javascript": false` in the `package_managers` section. Requires no
   session restart — config is loaded on each hook invocation.

2. **Full hook removal** (settings.json): Remove the `Bash` matcher entry
   from the `PreToolUse` array in `.claude/settings.json`. Requires session
   restart. The `Edit|Write` PreToolUse hook (config protection) is
   unaffected.

3. **Session override** (environment variable): Run
   `HOOK_SKIP_PM=1 claude ...` to bypass enforcement for a single session.
   This matches the `HOOK_SKIP_SUBPROCESS` pattern in `multi_linter.sh`.
   The hook checks this variable at startup and exits with
   `{"decision": "approve"}` immediately if set.

## Implementation Checklist

- [ ] Create `.claude/hooks/enforce_package_managers.sh`
- [ ] Add `package_managers` section to `.claude/hooks/config.json`
- [ ] Register new PreToolUse entry in `.claude/settings.json`
  (Bash matcher)
- [ ] Add self-test cases to `.claude/hooks/test_hook.sh`
- [ ] Update `.claude/hooks/README.md` with new hook documentation
- [ ] Add `[hook:block]` to README.md severity table (new prefix for
  PreToolUse blocks, extending existing `[hook:error/warning/advisory]`)
- [ ] Verify all existing tests still pass after changes

---

## References

- [uv GitHub repository (10-100x faster claim)](https://github.com/astral-sh/uv)
- [Bun v1.2.15 release notes (bun audit, bun pm view)](https://bun.com/blog/bun-v1.2.15)
- [Bun audit official documentation](https://bun.com/docs/install/audit)
- [DigitalOcean uv guide](https://www.digitalocean.com/community/conceptual-articles/uv-python-package-manager)
- [Stack Overflow: bash word boundary regex portability](https://stackoverflow.com/questions/9792702/does-bash-support-word-boundary-regular-expressions)
- [Stack Overflow: macOS grep -P not supported](https://stackoverflow.com/questions/77662026/grep-invalid-option-p-error-when-doing-regex-in-bash-script)
- [bun add documentation (--dev flag)](https://bun.com/docs/pm/cli/add)
- [uv issue #3163 - pip download equivalent (still open)](https://github.com/astral-sh/uv/issues/3163)
- [Bun v1.2.19 release notes (--quiet flag for bun pm pack)](https://bun.com/blog/bun-v1.2.19)
- [Bun v1.1.27 release notes (bun pm pack)](https://bun.com/blog/bun-v1.1.27)
- [Bun v1.1.30 release notes (bun publish, bun pm whoami)](https://bun.com/blog/bun-v1.1.30)
- [Stack Overflow - bash =~ uses ERE, not PCRE](https://stackoverflow.com/questions/27476347/matching-word-boundary-with-bash-regex)
- [bun audit documentation](https://bun.com/docs/pm/cli/audit)
- [bun info / bun pm view documentation](https://bun.com/docs/pm/cli/info)
