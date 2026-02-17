---
description: Verify and fix document-level separation of concerns in spec files
argument-hint: [file-path(s)]
allowed-tools: AskUserQuestion, Read, Glob, Grep, Task, Edit, Write
---

# Spec Document Separation of Concerns Review

You are conducting a document-level separation of concerns review. Your goal is to analyze whether specification documents are properly scoped, free of cross-cutting content, and structurally sound — then propose and apply concrete restructuring when needed.

**Critical**: You are reviewing the **structure of the documents themselves**, NOT the technical design they describe. A perfectly valid architecture can live in poorly structured documentation. Focus exclusively on document organization.

## Phase 1: Input & Discovery

### Read Input Files

$ARGUMENTS

If file path(s) were provided above, read them all immediately. If no argument was provided, ask the user to provide one or more file paths. Do not accept descriptions or fuzzy input — require explicit file paths.

### Auto-Discover Connected Documents

After reading the input file(s), scan their contents for references to other documents:
- Markdown links (`[text](./path.md)`, `[text](../path.md)`)
- Relative path mentions in prose (e.g., "see `docs/api-spec.md`")
- Explicit document references (e.g., "as described in the Architecture Overview")

For each discovered reference, resolve the path relative to the input file and read it. **Discovery is 1 level deep only** — read files directly referenced by the input files, but do NOT follow references found in those discovered files.

Build a complete picture of all documents in the analysis set before proceeding. Track which files were input vs. discovered, and note the relationship between them.

## Phase 2: Internal Analysis

Perform the following analysis **entirely in your internal thinking**. Do NOT output any of this reasoning to the user.

### Self-Questioning Framework

For each document in the analysis set, ask yourself these questions:

**Scope & Identity**
- What is this document supposed to be about? What is its stated or implied purpose?
- Does the title/filename accurately reflect the actual content?
- If I had to write a one-sentence scope statement for this doc, would all the content fit within it?

**Cross-Cutting Content Detection**
- Does this document contain information that is a concern of multiple other components or documents?
- Example: "This file is supposed to be an overview of component X but contains highly detailed tech stack choices that apply to the entire system — should we extract the tech stack into a separate shared document?"
- Example: "This component spec defines authentication patterns that are reused by 4 other services — this belongs in a shared auth spec, not buried here."
- Is there content here that someone editing a *different* document would need to find and keep in sync?

**Scope Creep Detection**
- Has this document grown beyond its original purpose?
- Example: "This API spec also contains deployment instructions, monitoring setup, and incident response procedures — that is scope creep beyond what an API spec should cover."
- Are there sections that feel bolted on rather than integral to the document's core purpose?
- Would a new reader be surprised to find certain sections in a document with this title?

**Duplication Detection**
- Is the same information (or near-identical information) present in multiple documents in the analysis set?
- Example: "This same database schema description appears in 3 different files — should it be extracted to a single shared reference?"
- Are there paragraphs or sections that are copy-pasted or lightly rephrased across documents?
- Would changing this information require updating multiple files?

**Granularity Mismatch Detection**
- Does the level of detail match the document's purpose?
- Example: "This component overview dives into line-level implementation details with code snippets — that is a granularity mismatch for an overview document."
- Example: "This detailed API specification wastes its first two pages on high-level system context that belongs in an architecture overview."
- Is there a mismatch between what the document title promises and the depth of content it delivers?

### Categorize Findings

Group all findings into **concerns** — logical units of restructuring where each concern represents one separation-of-concerns violation and its complete fix. A concern may span multiple files.

For each concern, determine:
1. **Violation type**: Cross-cutting content, scope creep, duplication, or granularity mismatch
2. **Severity**: How much does this hurt document usability and maintainability?
3. **Affected files**: Which files need changes?
4. **Proposed fix**: Exactly what content moves where, what new files are created, what cross-references are added
5. **New file names** (if any): Propose sensible names based on the extracted content

Sort concerns by severity (highest impact first).

If no violations are found, skip to the "No Issues Found" section below.

## Phase 3: Proposal Presentation

Present each concern to the user as a separate `AskUserQuestion`, in order of severity. For each concern:

1. **Explain the concern**: What violation was found, in which file(s), and why it is a problem for document maintainability
2. **Describe the proposed fix**: List every specific change — which sections move, which files get edited, what new files are created, what the new file would be named
3. **State your recommendation**: Whether to accept and why

Use `AskUserQuestion` with these options for each concern:
- **Accept as proposed**: Apply all changes for this concern exactly as described
- **Skip this concern**: Leave the documents unchanged for this issue

The user can always choose "Other" to request modifications to the proposal.

**Wait for the user's response to each concern before presenting the next one.** Each concern is independent — the user's decision on one does not affect others unless there is a structural dependency (in which case, note it).

### Proposal Format

When describing a concern to the user in the AskUserQuestion, structure the question clearly:

```
**[Violation Type]: [Brief Title]**

[1-2 sentence explanation of what was found and why it's a problem]

**Proposed changes:**
- [File A]: Remove section "X" (lines describing Y), replace with link to new file
- [File B]: Remove duplicate section "X"
- [NEW] `proposed-filename.md`: Contains extracted content about Y

**Recommendation:** Accept — [brief reasoning why this improves document structure]
```

## Phase 4: Apply Approved Changes

For each concern the user accepted:

1. **Create new files first** using `Write` — if the concern involves extracting content into a new file, create that file before editing the originals
2. **Edit original files** using `Edit` — remove the extracted content and replace it with a markdown link in this format:
   ```
   See [Topic Name](./relative-path-to-new-file.md) for details.
   ```
3. **Fix cross-references** — if other files referenced the moved content by section heading or anchor, update those references to point to the new location

Apply changes in dependency order: new files first, then edits to originals, then cross-reference fixes.

**Non-destructive guarantee**: NEVER delete entire files. Only create new files and edit existing ones.

## No Issues Found

If the analysis finds no separation-of-concerns violations, tell the user directly:

- State that the documents were reviewed and no structural issues were found
- Briefly explain what was checked (scope alignment, cross-cutting content, duplication, granularity)
- Note what makes the current structure sound (2-4 sentences of reasoning)

## Rules

- Always read ALL files (input + discovered) before any analysis
- Auto-discovery is 1 level deep only
- The entire Phase 2 analysis happens in internal thinking — never show the self-questioning to the user
- No final summary report — the interactive concern-by-concern flow IS the output
- Pattern-agnostic — do not assume any documentation framework (C4, arc42, ADR, etc.)
- Non-destructive — never delete entire files
- When replacing extracted content with cross-references, use markdown link format
- Propose new file names as part of each concern (user approves as part of accepting the concern)
- Each invocation is stateless — no memory of previous reviews

Begin by reading the input file(s), discovering connected documents, reading all discovered files, and then conducting your internal analysis.
