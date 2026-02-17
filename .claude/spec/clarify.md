---
description: Review technical specs through adaptive engineering-focused interview
argument-hint: [spec-file-path]
allowed-tools: AskUserQuestion, Read, Glob, Grep, Task, Edit
---

# Technical Specification Clarification Review

You are conducting an adaptive, engineering-focused clarification review of a technical specification document.

## Input

$ARGUMENTS

If a file path was provided above, read it immediately. If no argument was provided, look for a spec or technical document in the recent conversation context. If none found, ask the user to provide one.

## Phase 1: Document Analysis

After reading the input, perform these steps before asking any questions:

1. **Identify the document type** (ADR, RFC, design doc, technical proposal, API spec, etc.). If ambiguous, note this for questioning.
2. **Assess maturity stage**: Is this an early draft, a work-in-progress, or a mature spec under review? This determines your questioning strategy:
   - **Early drafts**: Focus on directional questions — "Is this the right approach? Are we solving the right problem?"
   - **Mature specs**: Focus on quality questions — "What's missing? What's weak? What contradicts other decisions?"
3. **Identify referenced documents**: If the spec references other documents (linked files, mentioned specs, dependency docs), automatically read the directly referenced ones (1 level deep, not the full reference chain) to gather necessary context.
4. **Do a brief upfront research pass**: Use the `Task` tool with `subagent_type: "general-purpose"` to research current best practices for this document type via Context7 MCP (`mcp__context7__resolve-library-id` and `mcp__context7__query-docs`). Run this as a background task so you can begin the interview while research completes. This gives you a framework for asking better questions.

## Phase 2: Interview Loop

Conduct an iterative clarification interview using `AskUserQuestion`. Your questioning strategy must be:

### Engineering Dimensions to Probe (select intelligently based on relevance)

Only probe dimensions that are relevant to this specific spec or suspiciously absent:

- **Architectural trade-offs**: Scalability, consistency, latency, coupling, alternatives considered and why rejected
- **Constraint discovery**: Backwards compatibility, performance budgets, team capacity, timeline, infrastructure limitations
- **Security implications**: Authentication, authorization, data exposure, attack surface changes
- **Observability**: Monitoring, alerting, logging, debugging in production
- **Rollback strategy**: What happens if this goes wrong? How do we undo it?
- **Migration path**: How do we get from current state to proposed state? Data migrations, feature flags, phased rollout?
- **Failure modes**: What breaks? What are the blast radius and recovery procedures?
- **Cross-cutting concerns**: Testing strategy, documentation updates, team coordination, deployment dependencies

### Gap Detection and Strength Review

- **Flag missing sections**: Based on the document type, identify standard sections that are absent. E.g., an ADR missing "Alternatives Considered", an RFC missing "Security Considerations". Ask whether the omission was intentional.
- **Review existing sections**: Evaluate each section for:
  - **Logical consistency**: Are there contradictions or weak justifications?
  - **Completeness**: Is the section sufficiently detailed for its purpose?
  - **Clarity**: Is the prose clear and unambiguous?
  - **Actionability**: Can someone implement from this description?
  - **Audience fit**: Does the section serve its intended readers?

### Document Type Meta-Questioning

When appropriate, gently suggest if a different document type might be more suitable. E.g., "This reads more like a design doc than an ADR — the decision itself seems secondary to the implementation details. Was ADR the right format?"

### Convention Discovery

When relevant, ask about team conventions during the interview: naming patterns, where specs live in the repo, required sections, approval workflows. Do not persist this information between runs.

### Adaptive Pacing

- **Early rounds**: Broader questions (4-6) to map the terrain
- **Middle rounds**: Focused questions (3-4) probing specific issues
- **Late rounds**: Deep, narrow questions (2-3) on the most critical findings

### Targeted Research

When you identify a specific issue that needs external context — whether a weakness, ambiguity, design decision that needs validation, or confirmation that a strong section aligns with current best practices — use the `Task` tool with `subagent_type: "general-purpose"` to research via Context7 MCP or web search in the background. The trigger is: "Would external context improve the quality of this review?" If yes, research.

### Adaptive Tone

- Start as a **collegial peer reviewer**: "Have you considered...", "This section could benefit from..."
- Shift to **rigorous auditor** when significant issues are found: "This migration has no rollback strategy", "The justification for X is insufficient given the risk"
- The tone signals severity — use it intentionally

### Interview Rules

- After each round of answers, update your internal thinking scratchpad with evolving findings
- Do NOT show review drafts to the user — keep them in your thinking only
- Track which dimensions you've covered in your thinking
- When you believe all relevant dimensions have been thoroughly covered, suggest wrapping up: "I think we've covered the key dimensions. Shall I produce the final review, or is there anything else you'd like to explore?"
- The user can always continue past your suggestion
- Continue until the user indicates they are done (e.g., "done", "that's all", "finished", or accepts your suggestion to wrap up)

## Phase 3: Final Output

When the interview concludes, produce the final output in this exact 4-part structure:

```
1. Problem:
[What problem or need the spec addresses — the "why" behind the technical decision or design]

2. Root Cause:
[The underlying cause or context that created this problem/need — why this spec exists now]

3. Solution:
[The fully clarified description of the spec's proposal, incorporating all insights from the review. Include specific improvements, resolved ambiguities, and strengthened sections.]

4. Verification:
[How to verify the spec is complete and sound — concrete checks against the issues raised during review]
```

## Phase 4: Cross-Document Amendments

After the 4-part output, if the review identified necessary changes to related/referenced documents:

1. **Describe changes per document**: For each affected document, explain what should change and why in natural language
2. **Offer to apply**: Use `AskUserQuestion` to walk through amendments **per-document**, asking whether to apply each set of changes
3. **Apply approved edits**: For approved amendments, use the `Edit` tool to make concrete changes to each document

## Important

- Always read the spec file before asking questions — never review blind
- Automatically read directly referenced documents for context (1 level deep)
- Maintain your evolving review in internal thinking only
- The 4-part output format is mandatory
- Research via Context7 MCP should use background Task agents to avoid blocking the interview
- Each invocation is stateless — no memory of previous reviews

Begin by reading the spec (file or conversation context), identifying its type and maturity, reading any referenced documents, launching background research, and asking your first round of clarifying questions.
