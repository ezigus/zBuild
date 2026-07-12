# vision document

Every zBuild-managed repository carries a **vision document** — a short Markdown file that
states the project's intent and guiding principles. The pipeline resolves it at run time
and (from Phase 1.1 onward) injects it into stage prompts so every AI-assisted step is
steered by the repository's stated purpose.

## Why it exists

Stage prompts that lack repository context produce generic, context-free output. A
~300-word vision document provides just enough signal — what the project does, for whom,
and by what values — to anchor model output without crowding the working context. It also
gives the admission gate something concrete to validate (Phase 1.1, #1358/#1360).

## Resolution order

The pipeline checks these paths in order and uses the first one it finds:

1. `.zbuild/vision.md` — per-repo override (same `.zbuild/` seam as ADR-016/032)
2. `docs/VISION.md` — conventional location alongside source docs
3. `VISION.md` — flat-root fallback for minimal repos

## Document format

A vision document is a **Markdown file** with:

- **Optional YAML frontmatter** (`---` block): `version` and `updated` are recognized; other keys are ignored.
- **Required sections** (exact H2 headings):
  - `## Intent` — one paragraph: what the project does and for whom.
  - `## Principles` — a list or paragraph of guiding values.
- **Optional sections**: `## Consistency anchors`, `## Constraints / guardrails`, or any repo-specific H2.
- **Word cap**: body text (excluding frontmatter, headings, and blank lines) must not exceed 300 words.

## Validation

`scripts/lib/vision.sh` provides two functions:

```bash
# Resolve: prints path and returns 0, or returns 1 if absent
source scripts/lib/vision.sh
load_vision_doc [repo_root]

# Validate: returns 0 if valid; prints diagnostics to stderr per violation
validate_vision_doc <path>
```

## Worked example

The following is a self-contained, fully conformant vision document demonstrating every section:

```markdown
---
version: '1.0'
updated: '2026-07-12'
---

# Acme Widget — Vision

> The North Star for Acme Widget.

## Intent

Acme Widget gives small engineering teams a **reliable way to ship browser
extensions consistently**. You describe your release checklist once as a
template, and every build runs through the same steps in the same order — so
the tenth release is as predictable as the first.

## Principles

- **Consistency over cleverness** — the same template, run the same way, every time.
- **Fail closed** — a missing config or failed gate stops the run with a clear message.
- **Automation serves humans** — every automated step is auditable and resumable.
- **Simple by default** — the base template covers 80% of use cases without customization.

## Consistency anchors

- One template per workflow; changes flow through it run-to-run unchanged.
- Gate semantics (pass/fail/block) stay stable unless deliberately revised.

## Constraints / guardrails

- No direct model calls from plugins; all prompts pass through the redaction chokepoint.
- Word cap: this document must stay under 300 words to remain injectable as a prompt prefix.
```

## Related

- ADR-049 — the formal decision ratifying this standard
- [[mechanics/admission-gate]] — Phase 1.1 will require a conforming vision document before a run starts
- [[mechanics/redaction-chokepoint]] — vision content is injected into prompts through this chokepoint
