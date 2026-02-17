---
description: Fact-check a document's technical claims against current documentation and codebase
argument-hint: [file-path(s)]
allowed-tools: Read, Edit, Grep, Glob, Task, AskUserQuestion, mcp__context7__*, mcp__exa__*
model: opus
---

# Document Fact-Check

Fact-check all technical claims in one or more local documents against current
library documentation, codebase state, and web sources. Present findings grouped
by severity, collaborate with the user on edits, and apply corrections directly
to each file. Also check internal consistency (cross-references, function names,
broken links within each document).

Uses a distributed background-agent architecture: the orchestrator (you) never
reads file contents. Research and editing are delegated to background agents to
keep the orchestrator's context window clean.

---

## Phase 0: Input Parsing

**Arguments**: `$ARGUMENTS`

### Accepted File Types

- **Accepted**: `.md`, `.txt`, `.rst`, `.adoc`, `.org`, `.tex`, `.html`, `.xml`,
  `.json`, `.yaml`, `.yml`, `.toml`, `.ini`, `.cfg`, `.conf`, `.csv`, `.tsv`, `.log`,
  `.sh`, `.bash`, `.zsh`, `.py`, `.js`, `.ts`, `.jsx`, `.tsx`, `.rb`, `.go`, `.rs`,
  `.java`, `.kt`, `.swift`, `.c`, `.cpp`, `.h`, `.hpp`, `.cs`, `.php`, `.r`, `.sql`,
  `.dockerfile`, `.makefile`, `.cmake`, and any other plaintext format
- **Rejected**: Binary files, images (`.png`, `.jpg`, `.gif`, `.svg`, `.ico`),
  compiled files (`.o`, `.class`, `.pyc`), archives (`.zip`, `.tar`, `.gz`),
  PDFs (`.pdf`), office documents (`.docx`, `.xlsx`, `.pptx`)

### Parse Arguments

**If `$ARGUMENTS` is empty**, output and STOP:

```
No file path provided.

Usage: /fact-check [file-path(s)]
Example: /fact-check docs/architecture.md
Example: /fact-check README.md CHANGELOG.md
Example: /fact-check docs/*.md
```

**Step 0.1**: Split `$ARGUMENTS` on spaces to get a list of tokens.

**Step 0.2**: For each token, check if it contains glob characters (`*`, `?`, `**`).
- If it is a glob pattern: use the `Glob` tool to expand it into matching file paths
- If it is a plain path: keep it as-is

**Step 0.3**: Flatten all expanded paths into a single list. Deduplicate (remove
exact duplicates preserving first occurrence order).

**Step 0.4**: Validate each file path:
- Use `Glob` to check the file exists (match the exact path)
- Check the file extension is not a rejected type
- Collect valid files and invalid files separately

**If ALL files are invalid or not found**, output and STOP:

```
No valid files found.

Invalid paths:
- [path]: [reason — "not found" or "unsupported file type"]
```

**If some files are invalid**, show a warning but continue with valid files:

```
Warning: Skipping invalid files:
- [path]: [reason]
```

**Step 0.5**: Display the file list:

```
Fact-checking [N] file(s):
- [file-path-1]
- [file-path-2]
- ...
```

---

## Phase 1: Dispatch Research (Parallel)

For EACH valid file, launch a background `Task` agent with the following
configuration:

- `subagent_type`: `"general-purpose"`
- `model`: `"opus"`
- `run_in_background`: `true`
- `description`: `"Research [filename]"`

All research coordinator agents are launched **in parallel** — do NOT wait for
one to finish before launching the next. There is no global agent cap.

### Research Coordinator Agent Prompt

Each agent receives this prompt (with `[FILE_PATH]` substituted):

````
You are a fact-checking research coordinator. Your job is to read a document,
extract verifiable claims, research them using sub-agents, and return a
structured JSON summary.

FILE TO FACT-CHECK: [FILE_PATH]

## Step 1: Read the Document

Read the file using the Read tool.

Assess the file size. If the Read tool truncates the output or returns a warning
about file size, activate chunked mode:

**Chunking strategy — heading-based:**

For Markdown/RST/ADoc files:
- Split on top-level and second-level headings (# / ## for Markdown)
- Each heading and its content until the next same-or-higher-level heading forms one chunk

For non-Markdown files:
- Split on blank-line-separated sections

Process chunks sequentially, accumulating all claims across chunks.

## Step 2: Extract Verifiable Claims

Analyze the document content. Extract **verifiable factual claims** — statements
that can be checked against documentation, code, or authoritative sources.

### External Claims (checked against outside sources)

Extract claims like:
- Library/framework version assertions ("React 18 supports...")
- API behavior claims ("The endpoint returns 404 when...")
- Configuration statements ("DuckDB requires X setting for...")
- Architecture claims ("This uses the singleton pattern from...")
- Performance assertions ("This reduces latency by...")
- Compatibility claims ("Works with Node 18+")
- Protocol/standard references ("HTTP/2 requires...")
- Tool behavior claims ("Webpack tree-shakes...")

Skip:
- Opinions and preferences ("We should consider...")
- Task descriptions ("Refactor the auth module")
- Questions ("Should we use X?")
- Narrative context ("The team discussed...")
- Decisions without factual basis ("We decided to use X")
- Code examples (unless they claim specific behavior)

### Internal Consistency Claims (checked within the document and codebase)

Also extract internal references that can be verified:
- Cross-references to other sections ("as described in Section 3")
- References to functions, classes, or files ("the processOrder() function in api/orders.ts")
- Internal links (markdown links to anchors, relative file paths)
- Statements that contradict other statements within the same document
- Referenced file paths or directory structures

For each claim, record:
- The exact quote from the document
- Its location (line number or section heading)
- The library, API, technology, or internal reference involved
- What specifically to verify
- Whether it is an external or internal claim

If no verifiable claims are found, return this JSON and STOP:

```json
{
  "file": "[FILE_PATH]",
  "claims_checked": 0,
  "findings": [],
  "reference_urls": [],
  "message": "No verifiable factual claims found. The document contains narrative, opinions, or task descriptions but no technical assertions that can be checked."
}
```

## Step 3: Research Claims (Sub-Agents)

Categorize each external claim by the best research tool and launch background
Task agents. Cap at 10 concurrent sub-agents. If more than 10 claims exist,
batch in groups of 10.

### Sub-Agent Types

**Context7 Agent** (library/framework documentation):
- One agent PER library mentioned in the claims
- Each agent handles ALL claims about its assigned library
- Agent MUST call mcp__context7__resolve-library-id first to get the library ID
- Then call mcp__context7__query-docs with specific questions for each claim
- Always check against the latest stable version of the library
- Return ONLY a summary: for each claim, state whether it is correct, incorrect,
  imprecise, or outdated, with a brief explanation and the source documentation URL

**Codebase Agent** (code-related claims):
- Uses Grep and Read tools to verify claims about the local codebase
- Searches for referenced functions, configurations, patterns, file paths
- Return ONLY a summary: claim status + evidence from codebase

**Exa Web Search Agent** (general technical claims):
- Uses mcp__exa__web_search_exa for claims not covered by Context7 or codebase
- Searches for authoritative sources (official docs, reputable tech blogs, RFCs)
- Return ONLY a summary: claim status + evidence + source URL

### Sub-Agent Prompt Template

Each sub-agent receives:

```
You are a fact-checking research agent. Verify the following technical claim(s)
from a document being fact-checked.

CLAIMS TO VERIFY:
[list of specific claims with exact quotes and line numbers]

TOOL TO USE: [Context7 / Grep+Read / Exa web search]
[For Context7: first resolve the library ID for "[library name]", then query docs]
[For Context7: always check against the LATEST stable version]
[For Exa: search for authoritative sources]
[For Codebase: search for the referenced code patterns]

INSTRUCTIONS:
- For each claim, determine: CORRECT / INCORRECT / IMPRECISE / OUTDATED
- Provide a brief explanation (2-3 sentences max) with specific evidence
- Include source URL or file path where you found the evidence
- If you cannot find evidence for a claim, do NOT include it in your response
- Return ONLY a summary — no full documentation content
```

Launch all sub-agents using Task tool with subagent_type: "general-purpose" and
model: "sonnet". Use run_in_background: true for parallel execution.

### Internal Consistency Claims — Sub-Agent

Launch a SINGLE codebase agent to verify ALL internal claims:
- Cross-references: Check that referenced sections/headings exist in the document
- Function/class references: Use Grep to verify they exist in the codebase
- File path references: Use Glob to verify they exist
- Internal links: Check that anchor targets exist
- Self-contradictions: Flag statements that contradict each other

This sub-agent counts toward the 10-agent cap.

## Step 4: Consolidate Results

Wait for all sub-agents to complete. Collect results.
Silently discard any claims where the sub-agent failed or returned no results.

For each finding that indicates a problem (INCORRECT, IMPRECISE, or OUTDATED),
construct a recommended edit: determine the exact old_string that should be
replaced and the new_string that should replace it. The old_string MUST be the
exact text as it appears in the file (copy it precisely from the Read output).

Collect all external reference URLs (documentation pages, web sources) from
sub-agent results.

## Step 5: Return Structured JSON

Return ONLY a JSON object in this exact format — no other text before or after:

```json
{
  "file": "[FILE_PATH]",
  "claims_checked": <number>,
  "findings": [
    {
      "claim": "exact quote from document",
      "location": "Line <N> / Section '<heading>'",
      "type": "external or internal",
      "severity": "INCORRECT or IMPRECISE or OUTDATED",
      "verdict": "INCORRECT or IMPRECISE or OUTDATED",
      "evidence": "2-3 sentence explanation of what is wrong and what is correct",
      "recommended_edit": {
        "old_string": "exact text to replace from the file",
        "new_string": "replacement text",
        "description": "Brief description of the change"
      },
      "reference_url": "https://... or local file path"
    }
  ],
  "reference_urls": [
    {"label": "Descriptive label", "url": "https://..."}
  ]
}
```

CRITICAL RULES:
- Return ONLY the JSON — no markdown fences, no explanation, no preamble
- The findings array contains ONLY problems (INCORRECT/IMPRECISE/OUTDATED)
- Do NOT include claims that were verified as CORRECT
- The old_string in recommended_edit MUST be the EXACT text from the file
- reference_urls contains ONLY external URLs (not local file paths)
- Keep evidence concise (2-3 sentences max per finding)
- If no problems found, return findings as an empty array []
````

Display after launching all agents:

```
Launched research for [N] file(s)...
```

---

## Phase 2: Per-File Review (Sequential, Input Order)

Process each file **in input order**. For each file:

**Step 2.1**: Wait for the file's research coordinator agent to complete. Read
its output.

**Step 2.2**: Parse the JSON response. If parsing fails or the agent returned
an error:

```
Research failed for [file-path]. Skipping.
```

Record this file as "failed" and continue to the next file.

**Step 2.3**: If `findings` is empty (no problems found):

```
[file-path]: No issues found ([claims_checked] claims verified).
[Include the "message" field if present, otherwise: "All verifiable claims checked out."]
```

Record this file as "clean" and continue to the next file.

**Step 2.4**: If findings exist, display a batch summary for this file:

```
## [file-path]: [N] issue(s) found ([claims_checked] claims checked)
```

Then display each finding grouped by severity (INCORRECT first, then IMPRECISE,
then OUTDATED):

```
### [Severity]: [Brief label from description]

**Claim**: "[exact quote from document]"
**Location**: [location]
**Type**: [type]
**Verdict**: [severity]
**Evidence**: [evidence]
**Reference**: [reference_url]
**Recommended edit**: [recommended_edit.description]
```

**Step 2.5**: Walk through each finding ONE BY ONE, ordered by severity
(INCORRECT first, then IMPRECISE, then OUTDATED).

For each finding, use `AskUserQuestion` with:

- **Question**: A clear explanation of the issue found, including:
  - The exact claim from the document and its location
  - What the evidence shows is actually correct
  - WHY this edit is recommended (impact on readers, risk of confusion)
- **Options** (always include these two):
  1. **Recommended edit** — The suggested replacement text, marked with
     "(Recommended)" in the label. Include the exact old_string → new_string
     in the description.
  2. **Keep current text** — Leave the claim unchanged. Description explains
     the risk of keeping it.

(The built-in "Other" option lets the user provide custom wording.)

**Step 2.6**: After collecting approvals for all findings in this file:

- Build the approved edits list: for each finding where the user chose the
  recommended edit or provided a custom edit, include it. For "Keep current
  text" choices, exclude the finding.
- If the user provided a custom edit (via "Other"), use their text as the
  new_string, keeping the original old_string.

**Step 2.7**: If there are approved edits, dispatch a background edit agent:

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `run_in_background`: `true`
- `description`: `"Edit [filename]"`

### Edit Agent Prompt

Each edit agent receives this prompt (with substitutions):

````
You are a fact-check edit agent. Apply approved edits to a file and update its
references section.

FILE TO EDIT: [FILE_PATH]

## Approved Edits

Apply each edit in order using the Edit tool:

```json
[APPROVED_EDITS_JSON_ARRAY]
```

For each edit:
1. Use the Edit tool with old_string and new_string exactly as provided
2. If the Edit tool fails (old_string not found — likely due to prior edits
   shifting content):
   a. Re-read the file using the Read tool
   b. Find the text that most closely matches the old_string
   c. Retry with the corrected old_string
   d. If still failing, skip this edit and note it in your response
3. Continue to the next edit

## References

After all edits are applied, update the references section.

Reference URLs to add:

```json
[REFERENCE_URLS_JSON_ARRAY]
```

If the reference_urls array is empty, skip this section entirely.

If reference URLs exist:
1. Read the file to check if a `## References` section already exists
2. If it exists:
   a. Parse all existing URLs from that section
   b. Normalize URLs for comparison: strip trailing slashes, normalize http://
      to https://, but keep path and query parameter differences as meaningful
   c. Merge old + new references into a single deduplicated list (union —
      preserve references from prior fact-checks)
   d. Delete the old ## References section (from the --- separator before it
      through the end of the list)
3. Append to the END of the file using the Edit tool:

```markdown

---

## References

- [Descriptive label](https://...)
- [Descriptive label](https://...)
```

## Response

Return a brief summary:

```
Edits applied: [N] of [M]
Edits skipped: [list of skipped edit descriptions, if any]
References appended: [N]
```
````

If there are NO approved edits but there ARE reference URLs from the research,
still dispatch an edit agent to handle only the references section.

If there are NO approved edits AND NO reference URLs, skip the edit agent for
this file entirely.

---

## Phase 3: Final Summary

After processing all files (Phase 2 complete for every file):

**Step 3.1**: Wait for all dispatched edit agents to complete. Read their outputs
to collect edit/reference counts.

**Step 3.2**: Display the final summary:

```
Fact-check complete.
- [file-a.md]: [N] claims checked, [A] edits applied, [R] references appended
- [file-b.md]: [N] claims checked, no issues found
- [file-c.md]: Research failed, skipped
```

---

## Error Handling

**No valid files after parsing**:

```
No valid files found in: "$ARGUMENTS"

Check paths and try again. Use relative or absolute paths, or glob patterns.
Supported: .md, .txt, .rst, .adoc, and other plaintext formats.
Not supported: PDFs, images, binaries, archives, office documents.
```

**Research coordinator failure** (per file):

```
Research failed for [file-path]. Skipping.
```

Continue with remaining files. Do NOT retry.

**Edit agent failure** (per file):

```
Edit agent failed for [file-path]. Edits may not have been applied.
Check the file manually.
```

**All research coordinators failed**:

```
All research agents failed. This may indicate network issues
or system problems. No fact-check findings to report.
```

---

## Design Principles

- **No Linear dependency**: Works with any local text file
- **Distributed architecture**: Research and editing delegated to background agents
- **Context-clean orchestrator**: Orchestrator NEVER reads file contents
- **Multi-file support**: Accepts multiple paths and glob patterns
- **Parallel research**: All files researched simultaneously, no global cap
- **Sequential review**: Files presented in input order for predictable UX
- **Structured JSON**: Research coordinators return structured JSON for reliable parsing
- **Concise agent output**: Agents return ONLY summaries to minimize context consumption
- **Per-file research coordinator**: One Opus agent per file spawns up to 10 Sonnet sub-agents
- **Internal + external**: Checks both factual claims and document self-consistency
- **Severity-first**: Present worst problems first
- **Evidence-based**: Every recommendation includes proof and source
- **User in control**: Every change requires explicit approval via AskUserQuestion
- **Background editing**: Edit agents apply approved changes without clogging orchestrator
- **Silent sub-agent failures**: Individual research sub-agent failures silently discarded
- **File-level failure notification**: Research coordinator failures reported to user
- **Chunked processing**: Large files split by headings, handled by coordinator internally
- **References only**: Appends only external source URLs, no change log
- **Latest versions**: Always checks library claims against latest stable versions
