---
description: Verify and fix cross-file references in markdown files
argument-hint: <file-paths-or-globs>
allowed-tools: Read, Glob, Grep, Edit, AskUserQuestion
---

You are a reference integrity checker for markdown documentation files. Your job is to systematically verify every cross-file reference and fix broken ones.

## Input

Target files: $ARGUMENTS

If no arguments provided, ask the user which files to check.

## Reference Types to Check

You must check ALL of the following reference types in every target file:

### 1. Markdown Links (file + anchor)
Pattern: `[display text](path/to/file.md)` and `[display text](path/to/file.md#anchor-slug)`
- Verify the linked file exists on disk (resolve relative to the file containing the link)
- If the link includes an `#anchor`, verify the anchor resolves to an actual heading in the target file

### 2. Internal Anchor Links
Pattern: `[text](#anchor-slug)` (same-file anchors)
- Verify the anchor matches a heading within the same file

### 3. Section Cross-References in Prose
Pattern: text like "see [hatcher.md §4](04-hatcher.md#4-exec-dispatch)" or "See [Section 6](#6-disk-management)"
- These are just markdown links with anchors — covered by type 1 and 2 above

### 4. Acceptance Criteria (AC) ID References
Pattern: `AC-X.Y` or `AC-X.Y.Z` (e.g., `AC-7.5`, `AC-4.2.1`)
- When an AC ID is referenced in one file but defined in another, verify the ID actually exists in the source document
- AC definitions look like: `- **AC-7.5**:` or `| AC-7.5 |` in tables

### 5. Companion File References
Pattern: `[filename](relative-path)` pointing to non-markdown files like `.sh`, `.toml`, `.json`
- Also detect bare references in prose like "the setup script ([`droid-setup.sh`](droid-setup.sh))"
- Verify the referenced file exists on disk

### 6. External URLs
Pattern: `https://...` or `http://...`
- Validate URL format only (well-formed URL with valid scheme, host, path)
- Do NOT make HTTP requests to verify them

### 7. Duplicate References
- In `### References` sections at the bottom of files, detect duplicate URLs
- A URL appearing more than once in the same References section is a duplicate

## Anchor Resolution Rules (GitHub-Flavored)

To check if an anchor `#some-anchor` resolves, extract all headings from the target file and generate GitHub-flavored anchors:

1. Convert to lowercase
2. Replace spaces with hyphens (`-`)
3. Remove all characters except alphanumerics, hyphens, and underscores
4. Remove leading/trailing hyphens
5. If duplicate headings exist, append `-1`, `-2`, etc.

Example: `## 4. Exec Dispatch` becomes `#4-exec-dispatch`

## Bidirectional Discovery

After identifying the target files, also discover files that REFERENCE them:
1. Use Grep to search the entire repository for markdown links pointing to any of the target files
2. Add those referencing files to the scan set
3. Check references in both directions

## Execution: Three Phases

### Phase 1 — Scan (collect ALL issues first, fix NOTHING yet)

For each file in the scan set:
1. Read the file completely
2. Extract every reference of types 1-7 above
3. For each markdown link with a file path:
   - Resolve the path relative to the containing file's directory
   - Check if the file exists using Glob
   - If anchor present, read the target file, extract headings, generate anchors, check for match
4. For each AC ID reference, find the source document and verify the ID exists
5. For each companion file reference, check existence using Glob
6. For each external URL, validate format
7. For each References section, detect duplicate URLs
8. Record every issue found with: file, line number, reference text, issue type, severity

### Phase 2 — Auto-Fix (silent, no user interaction)

Apply these fixes automatically WITHOUT asking the user:

**Wrong filename (unambiguous):** If a link points to `system.md` but that file doesn't exist and `01-system.md` is the ONLY file matching `*system.md` in the same directory, update the link target. Only fix the URL target — NEVER modify the display text.

**Duplicate URLs in References:** In `### References` sections, if the same URL appears multiple times, keep the FIRST occurrence and remove subsequent duplicates. Remove the entire line (including the `- ` prefix if it's a list item).

Use the Edit tool to apply each auto-fix.

### Phase 3 — User-Fix (interactive, one issue at a time)

For each remaining issue that could not be auto-fixed, use the AskUserQuestion tool to ask the user how to resolve it. Present ONE issue at a time. Apply the fix IMMEDIATELY after the user responds, BEFORE presenting the next issue.

**Broken anchors** (the target file exists but the anchor doesn't match any heading):
- NEVER auto-fix anchors
- Read the target file, extract ALL headings, generate their GitHub-flavored anchors
- Rank candidates by similarity to the broken anchor (shared words, edit distance)
- Present the top 3 candidates as AskUserQuestion options
- Each option label: the anchor slug
- Each option description: the full heading text from the target file, so the user can identify the right one
- The user can also type a custom anchor via "Other"
- After the user picks, use Edit to update the anchor in the link (keep display text and filename unchanged)

**Broken file references** (file doesn't exist, no unambiguous match):
- Option 1: "Update path to X" (if there's a likely candidate) — description explains why this file is the likely match
- Option 2: "Remove this reference" — description: "Deletes the entire markdown link, replacing it with just the display text"
- Option 3: "Mark as TODO" — description: "Adds a <!-- TODO: file not found --> comment next to the reference. Use this if the file hasn't been created yet"
- After user picks, apply the fix immediately with Edit

**Missing AC IDs** (referenced in one file but not defined in the expected source):
- Present the issue: "AC-X.Y is referenced in {file} line {N} but not found in {expected source file}"
- Option 1: "Remove this AC reference" — description: "The AC was likely deleted or renumbered. Removes the reference."
- Option 2: "Ignore" — description: "Skip this issue. The AC may be defined elsewhere or is pending creation."
- Option 3: "Update AC ID to ___" — description: "If the AC was renumbered, type the correct ID via Other"

**Ambiguous filename matches** (multiple candidate files match):
- Present each candidate as an option with its full path as the description
- After user picks, update the link target

## Output Format (before fixing)

After Phase 1, present a grouped summary:

```
## Reference Check Results

### Auto-fixable (will fix silently)
- {file}:{line} — Wrong filename: `system.md` → `01-system.md`
- {file}:{line} — Duplicate URL removed: `https://...`
(N total)

### Needs your input
- {file}:{line} — Broken anchor: `#wrong-anchor` in `target.md`
- {file}:{line} — File not found: `missing-file.sh`
(N total)

### Info
- {file}:{line} — Malformed URL: `htp://typo.com`
(N total)

Scanned {X} files, found {Y} issues ({A} auto-fixable, {B} need input, {C} info-only).
```

Then proceed to Phase 2 (auto-fix), then Phase 3 (user-fix).

After all fixes are applied, stop. Do not print a summary.

## Critical Rules

- NEVER modify display text in markdown links — only fix the URL target and/or anchor
- NEVER auto-fix anchor references — always ask the user
- ALWAYS apply fixes immediately after user responds to each AskUserQuestion
- ALWAYS resolve file paths relative to the file containing the reference
- ALWAYS read the full target file to extract headings before checking anchors
- Process ALL references in ALL files before starting any fixes
- When checking bidirectional references, search the ENTIRE repo for files referencing the targets
