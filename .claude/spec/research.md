---
description: Research open questions and unresolved items against current documentation and ecosystem
argument-hint: [file-path(s)] [--auto]
allowed-tools: Read, Edit, Grep, Glob, Task, AskUserQuestion, mcp__context7__*, mcp__exa__*
model: opus
---

# Open Question Research

Research open questions and unresolved items in one or more local documents
against current library documentation, ecosystem state, and codebase. Enrich
items with evidence-backed findings and recommendations, propose status changes,
and apply approved edits directly to each file.

Complementary to `spec:fact-check` (which verifies existing claims). This command
investigates things that are *unresolved*.

Uses a distributed background-agent architecture: the orchestrator (you) never
reads file contents. Research and editing are delegated to background agents to
keep the orchestrator's context window clean.

---

## Phase 0: Input Parsing

**Arguments**: `$ARGUMENTS`

### Flag Detection

**Step 0.0**: Check if `$ARGUMENTS` contains `--auto`.
- If present: set `AUTO_MODE = true`, strip `--auto` from the arguments string
  before continuing to file parsing.
- If absent: set `AUTO_MODE = false`.

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

**If `$ARGUMENTS` is empty (or only contained `--auto` with no file paths)**, output and STOP:

```
No file path provided.

Usage: /spec:research [file-path(s)] [--auto]
Example: /spec:research docs/spec/11-open-questions.md
Example: /spec:research docs/spec/*.md
Example: /spec:research docs/spec/11-open-questions.md --auto
```

**Step 0.1**: Split the remaining arguments on spaces to get a list of tokens.

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
- [path]: [reason -- "not found" or "unsupported file type"]
```

**If some files are invalid**, show a warning but continue with valid files:

```
Warning: Skipping invalid files:
- [path]: [reason]
```

**Step 0.5**: Display the file list and mode:

```
Researching open items in [N] file(s) [--auto]:
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

All research coordinator agents are launched **in parallel** -- do NOT wait for
one to finish before launching the next. There is no global agent cap.

### Research Coordinator Agent Prompt

Each agent receives this prompt (with `[FILE_PATH]` substituted):

````
You are an open-question research coordinator. Your job is to read a document,
extract open/unresolved items, classify them, research the OPEN ones using
sub-agents, and return a structured JSON summary.

FILE TO RESEARCH: [FILE_PATH]

## Step 1: Read the Document

Read the file using the Read tool.

Assess the file size. If the Read tool truncates the output or returns a warning
about file size, activate chunked mode:

**Chunking strategy -- heading-based:**

For Markdown/RST/ADoc files:
- Split on top-level and second-level headings (# / ## for Markdown)
- Each heading and its content until the next same-or-higher-level heading forms one chunk

For non-Markdown files:
- Split on blank-line-separated sections

Process chunks sequentially, accumulating all items across chunks.

## Step 2: Extract Open Items (Two-Tier)

Analyze the document content. Extract items using two tiers:

### Tier 1: Structured Open Questions

Look for formally structured open questions with these patterns:
- Headings matching `### OQ-X.Y` or `### OQ-X.Y:` (e.g., `### OQ-7.4: @fly/sprites SDK Under Bun Compatibility [P2]`)
- Each OQ heading followed by context paragraphs and sub-question bullets (`- Should we...`, `- How does...`, `- What if...`)
- Status tags in heading: `[P1]`, `[P2]`, `[P3]`, `[RESOLVED]`, `[MIGRATED]`, `[PENDING MIGRATION]`

For each structured OQ, extract:
- The OQ ID (e.g., `OQ-7.4`)
- The full heading text
- The status tag if present
- All sub-question bullets (each is a researchable item)
- The section number (from the parent ## heading)
- The exact line number of the heading

### Tier 2: Tagged Open Items

Also detect explicitly tagged unresolved items across the document:
- `TODO` or `TODO:` markers
- `TBD` or `TBD:` markers
- `[OPEN]` tags
- `needs investigation` or `needs research` phrases
- Headings ending with `?` (question-mark headings)
- `<!-- TODO: ... -->` HTML comment markers

For each tagged item, extract:
- The exact text of the item
- Its location (line number and nearest heading)
- The marker type (TODO, TBD, etc.)

### Skip These

Do NOT extract:
- Resolved decisions with clear answers already in the text
- Rhetorical questions in prose
- Code comments that are implementation-level TODOs (not design-level)
- Items that are clearly task descriptions ("Implement X") rather than open questions

## Step 3: Classify Each Item (LLM Assessment)

For EACH extracted item, assess its current state semantically -- do NOT rely
solely on status label strings. Read the full content of each item and classify:

- **OPEN**: The item has no answer, no decision, no resolution. It genuinely
  needs research. Sub-questions without `**Finding**:` sub-bullets are OPEN.
- **SETTLED**: The item has an answer or decision present in its body, even if
  it lacks a formal `[RESOLVED]` label. Items with existing `**Finding**:`
  sub-bullets from a previous research run are SETTLED.
- **BLOCKED**: The item explicitly depends on an external event, another team's
  decision, or a prerequisite that hasn't happened yet.

Classification rules:
- An item tagged `[RESOLVED]` or `[MIGRATED]` is SETTLED (but verify the body
  actually contains a resolution -- if the label is there but the body is empty,
  classify as OPEN).
- An item tagged `[PENDING MIGRATION]` is SETTLED (design decided, just not moved).
- An item with `**Finding** [...]` sub-bullets under ALL its sub-questions is
  SETTLED (previous research run covered it).
- An item with `**Finding**` sub-bullets under SOME but not all sub-questions:
  only the sub-questions WITHOUT findings are OPEN.

## Step 4: Research OPEN Items (Sub-Agents)

Only research items classified as OPEN. Skip SETTLED and BLOCKED items.

For each OPEN item, determine the best research source:

**Context7** (library/SDK/framework questions):
- Questions about specific library APIs, SDK behavior, framework features
- Version compatibility questions
- Configuration and setup questions
- Examples: "@fly/sprites under Bun", "Agent SDK canUseTool callback", "Discord.js modal limitations"

**Exa Web Search** (ecosystem/architecture/best-practice questions):
- Architecture pattern questions
- Current ecosystem state
- Best practices and recommendations
- Comparison questions ("X vs Y")
- Examples: "Discord bot hosting patterns", "microVM orchestration approaches"

**Codebase Search** (implementation questions):
- Questions about current codebase state
- "Does X exist in our code?"
- Configuration and setup verification
- Examples: "Is rate limiting implemented?", "How is auth handled currently?"

Group OPEN items by research source. Launch background Task sub-agents:
- One Context7 agent PER library/SDK mentioned
- One Exa agent for all ecosystem/architecture questions
- One codebase agent for all implementation questions

Cap at 10 concurrent sub-agents. If more than 10, batch in groups of 10.

### Sub-Agent Prompt Template

Each sub-agent receives:

```
You are a research agent investigating open questions from a technical
specification document.

OPEN QUESTIONS TO RESEARCH:
[list of specific questions with their OQ IDs, exact text, and line numbers]

TOOL TO USE: [Context7 / Exa web search / Grep+Read]
[For Context7: first resolve the library ID for "[library name]", then query docs]
[For Context7: always check against the LATEST stable version]
[For Exa: search for authoritative, current sources]
[For Codebase: search for referenced code, patterns, configurations]

INSTRUCTIONS:
- For each question, provide:
  - A concise evidence summary (2-3 sentences) with specific findings
  - A recommendation based on the evidence (1-2 sentences)
  - A confidence level: HIGH (strong evidence, clear answer), MEDIUM (partial
    evidence, likely answer), or LOW (weak/tangential evidence, speculative)
  - Source URL or file path
- If you cannot find relevant evidence for a question, do NOT include it
- Return ONLY a summary -- no full documentation content
- Focus on ANSWERING the question, not just describing the topic
```

Launch all sub-agents using Task tool with subagent_type: "general-purpose" and
model: "sonnet". Use run_in_background: true for parallel execution.

## Step 5: Consolidate Results

Wait for all sub-agents to complete. Collect results.
Silently discard any questions where the sub-agent failed or returned no results.

For each finding, construct the inline enrichment:
- For Tier 1 items: determine the exact sub-question bullet text (old_string)
  and construct the enriched version with the finding appended as an indented
  sub-bullet (new_string). The finding format is:
  `  - **Finding** [CONFIDENCE]: evidence summary ([source](url)). **Recommendation**: recommendation text.`
- For Tier 2 items: construct a NEW OQ entry to be appended to 11-open-questions.md,
  and a breadcrumb annotation `(-> OQ-X.Y)` for the source location.

For items where evidence strongly indicates the question is answered/resolved,
flag for status change proposal (e.g., suggest `[P2]` -> `[RESOLVED]`).

## Step 6: Return Structured JSON

Return ONLY a JSON object in this exact format -- no other text before or after:

```json
{
  "file": "[FILE_PATH]",
  "classification": {
    "open": <number>,
    "settled": <number>,
    "blocked": <number>,
    "total": <number>
  },
  "settled_items": [
    {
      "id": "OQ-X.Y or descriptive label for Tier 2",
      "reason": "Brief reason why classified as settled"
    }
  ],
  "blocked_items": [
    {
      "id": "OQ-X.Y or descriptive label for Tier 2",
      "reason": "Brief reason why classified as blocked",
      "blocker": "What external event/decision it depends on"
    }
  ],
  "findings": [
    {
      "item_id": "OQ-X.Y or descriptive label for Tier 2",
      "item_heading": "Full heading text",
      "sub_question": "The specific sub-question researched (exact text from file)",
      "tier": 1 or 2,
      "location": "Line <N> / Section '<heading>'",
      "confidence": "HIGH or MEDIUM or LOW",
      "evidence": "2-3 sentence evidence summary",
      "recommendation": "1-2 sentence recommended answer/direction",
      "source_url": "https://... or local file path",
      "enrichment": {
        "old_string": "exact text from the file to find",
        "new_string": "replacement text with finding appended",
        "description": "Brief description of the enrichment"
      },
      "status_proposal": null or {
        "current": "[P2]",
        "proposed": "[RESOLVED]",
        "reason": "Evidence strongly indicates this is answered"
      }
    }
  ],
  "tier2_new_oqs": [
    {
      "source_file": "[FILE_PATH]",
      "source_location": "Line <N>",
      "source_text": "The original TODO/TBD text",
      "proposed_section": "Section number in 11-open-questions.md (e.g., 7 for SDK items)",
      "proposed_oq_body": "Full markdown body for the new OQ entry",
      "breadcrumb": {
        "old_string": "exact text at source location",
        "new_string": "same text with (-> OQ-X.Y) appended"
      }
    }
  ],
  "no_findings": [
    {
      "item_id": "OQ-X.Y",
      "item_heading": "Full heading text",
      "reason": "No actionable findings -- requires human deliberation / hands-on experimentation"
    }
  ],
  "reference_urls": [
    {"label": "Descriptive label", "url": "https://..."}
  ]
}
```

CRITICAL RULES:
- Return ONLY the JSON -- no markdown fences, no explanation, no preamble
- The findings array contains ONLY items with actionable research results
- Items with no findings go in the no_findings array
- The old_string in enrichment MUST be the EXACT text from the file
- The new_string MUST preserve the original text and ADD the finding as a new
  indented sub-bullet below it -- never replace the original question
- reference_urls contains ONLY external URLs (not local file paths)
- Keep evidence concise (2-3 sentences max per finding)
- Keep recommendations concise (1-2 sentences max per finding)
- Tier 2 items go in tier2_new_oqs, NOT in findings (unless they're in a file
  that already uses OQ format, in which case treat as Tier 1)
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

**Step 2.3**: Display the pre-research classification summary (informational
only -- no confirmation gate, proceed immediately):

```
## [file-path]: Classification Summary

| Status  | Count | Items |
|---------|-------|-------|
| OPEN    | N     | OQ-1.1, OQ-3.1, ... |
| SETTLED | M     | OQ-2.1 (migrated), OQ-7.1 (resolved), ... |
| BLOCKED | K     | OQ-X.Y (waiting on Z), ... |

Researching [N] OPEN items...
```

If `settled_items` is non-empty, list each with its reason.
If `blocked_items` is non-empty, list each with its blocker.

**Step 2.4**: If `findings` is empty AND `tier2_new_oqs` is empty:

```
[file-path]: No actionable findings for [N] OPEN items.
```

If `no_findings` is non-empty, list each:

```
Items with no findings (require human deliberation):
- [item_id]: [item_heading] -- [reason]
```

Record this file and continue to the next file.

**Step 2.5**: Display findings summary grouped by confidence (HIGH first, then
MEDIUM, then LOW):

```
### Findings: [N] items with research results

#### HIGH Confidence
- **[item_id]** ([sub_question excerpt]): [recommendation excerpt]

#### MEDIUM Confidence
- **[item_id]** ([sub_question excerpt]): [recommendation excerpt]

#### LOW Confidence
- **[item_id]** ([sub_question excerpt]): [recommendation excerpt]
```

If `no_findings` is non-empty, append:

```
#### No Findings
- **[item_id]**: [reason]
```

### Step 2.6: Approval Flow

**If AUTO_MODE is true:**

Auto-apply all HIGH and MEDIUM confidence findings without asking. Collect all
LOW confidence findings into a separate list.

After auto-applying HIGH+MEDIUM, if LOW confidence findings exist, use
`AskUserQuestion` ONCE:

- **Question**: "N LOW confidence findings were held back. These are speculative
  or based on tangential sources. Apply them?"
- **Options**:
  1. **Apply all LOW findings** -- "Apply all N LOW confidence findings. You can
     review them inline later."
  2. **Skip all LOW findings** -- "Discard LOW confidence findings. Only
     HIGH+MEDIUM findings were applied."
  3. **Cherry-pick** -- "Review each LOW confidence finding individually."

If user chooses "Cherry-pick", walk through each LOW finding one by one using
AskUserQuestion (same format as normal mode below).

**If AUTO_MODE is false:**

Walk through findings **grouped by OQ** (batch per OQ). For each OQ that has
findings:

Use `AskUserQuestion` with:

- **Question**: Present ALL findings for this OQ together:
  - The OQ heading and current status
  - For each finding: the sub-question, evidence, recommendation, confidence,
    and source
  - If a status change is proposed, include it
- **Options**:
  1. **Apply all findings for this OQ (Recommended)** -- "Apply [N] findings
     as inline sub-bullets under their respective sub-questions.
     [If status proposal: Also update status to [PROPOSED]."]"
  2. **Cherry-pick findings** -- "Review each finding for this OQ individually
     to approve or skip each one."
  3. **Skip this OQ** -- "Do not apply any findings for [OQ-X.Y]. Move to next."

If user chooses "Cherry-pick", walk through each finding for that OQ one by one:

- **Question**: The specific finding with evidence and recommendation
- **Options**:
  1. **Apply this finding (Recommended)** -- The enrichment text that will be
     added as a sub-bullet
  2. **Skip this finding** -- "Do not add this finding. Continue to next."

(The built-in "Other" option lets the user provide custom finding text.)

For status change proposals (when present in a finding), include as a separate
question after the findings for that OQ:

- **Question**: "Research suggests [OQ-X.Y] is resolved. Update status?"
- **Options**:
  1. **Update to [RESOLVED] (Recommended)** -- "Change heading tag from
     [CURRENT] to [RESOLVED]. Evidence: [brief reason]."
  2. **Keep current status** -- "Leave as [CURRENT]. The evidence may not be
     conclusive enough for resolution."

### Step 2.7: Tier 2 New OQ Proposals

If `tier2_new_oqs` is non-empty, process them after Tier 1 findings.

For each proposed new OQ, use `AskUserQuestion`:

- **Question**: "Found unresolved item in [source_file] at line [N]:
  '[source_text]'. Propose creating a new OQ in 11-open-questions.md."
- **Options**:
  1. **Create OQ (Recommended)** -- "Create [proposed OQ ID] in section [N] of
     11-open-questions.md and add breadcrumb at source. [Shows proposed body excerpt]"
  2. **Skip** -- "Do not create an OQ for this item."

(The built-in "Other" option lets the user provide custom OQ text.)

### Step 2.8: Dispatch Edit Agent

After collecting all approvals for this file, build the approved edits list:

- Tier 1 approved findings: enrichment edits (old_string/new_string)
- Tier 1 approved status changes: heading tag replacements
- Tier 2 approved new OQs: append to 11-open-questions.md + breadcrumbs at source

If there are approved edits, dispatch a background edit agent:

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `run_in_background`: `true`
- `description`: `"Edit [filename]"`

### Edit Agent Prompt

Each edit agent receives this prompt (with substitutions):

````
You are a research edit agent. Apply approved research findings to a file and
update its references section.

FILE TO EDIT: [FILE_PATH]

## Approved Edits

Apply each edit in order using the Edit tool:

```json
[APPROVED_EDITS_JSON_ARRAY]
```

For each edit:
1. Use the Edit tool with old_string and new_string exactly as provided
2. If the Edit tool fails (old_string not found -- likely due to prior edits
   shifting content):
   a. Re-read the file using the Read tool
   b. Find the text that most closely matches the old_string
   c. Retry with the corrected old_string
   d. If still failing, skip this edit and note it in your response
3. Continue to the next edit

## Tier 2 New OQs (if any)

New OQ entries to append to 11-open-questions.md:

```json
[TIER2_NEW_OQS_JSON_ARRAY]
```

For each new OQ:
1. Read 11-open-questions.md to find the correct section
2. Find the last OQ entry in the proposed section
3. Append the new OQ body after the last entry in that section
4. Apply the breadcrumb edit at the source file location

## Status Changes (if any)

Status tag replacements:

```json
[STATUS_CHANGES_JSON_ARRAY]
```

For each status change:
1. Use the Edit tool to replace the old heading tag with the new one
2. The old_string should be the exact heading text with old tag
3. The new_string should be the same heading with the new tag

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
   c. Merge old + new references into a single deduplicated list (union --
      preserve references from prior runs)
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
New OQs created: [N]
Status changes: [N]
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
Research complete.
- [file-a.md]: [O] OPEN items, [F] findings applied, [S] status changes, [R] references appended
- [file-b.md]: [O] OPEN items, no actionable findings
- [file-c.md]: Research failed, skipped
```

If any items had no findings across all files:

```
Items requiring human deliberation:
- [item_id]: [item_heading]
- ...
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
or system problems. No research findings to report.
```

---

## Design Principles

- **Investigative, not verificatory**: Finds answers to open questions instead of checking existing claims
- **Two-tier extraction**: Structured OQs (Tier 1) and tagged items (Tier 2) in any document
- **Semantic classification**: LLM assesses OPEN/SETTLED/BLOCKED status, not rigid label matching
- **Evidence + recommendation**: Every finding includes evidence and a recommended direction with confidence level
- **Auto-select sources**: Routes questions to Context7, Exa, or codebase search based on question type
- **Idempotent**: Detects previous research findings and skips already-enriched items
- **Inline enrichment**: Findings added as sub-bullets under the specific sub-question they answer
- **Tier 2 promotion**: Tagged items from spec files become formal OQs in 11-open-questions.md
- **Status proposals**: Suggests resolution when evidence is strong enough
- **--auto mode**: AUTO_MODE auto-applies HIGH+MEDIUM, holds LOW for batch review
- **Distributed architecture**: Research and editing delegated to background agents
- **Context-clean orchestrator**: Orchestrator NEVER reads file contents
- **Batch approval**: Findings presented per-OQ, not per-finding (unless cherry-picking)
- **No-findings tracking**: Items without results noted in summary as needing human deliberation
- **Reference URLs**: Appends deduplicated source URLs to file's References section
- **Parallel research**: All files researched simultaneously
- **Sequential review**: Files presented in input order for predictable UX
- **Confidence-gated auto-apply**: LOW confidence findings never auto-applied without review
