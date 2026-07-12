# ADR-049 — Vision-document standard

**Status:** Accepted (2026-07-12)
**Related:** ADR-016 (per-repository template resolution — `.zbuild/` search precedence),
ADR-032 (per-repo prompt overrides — `.zbuild/` as the canonical per-repo config dir),
ADR-004 (redaction chokepoint — the required integration point for vision injection into stage prompts).
Issue #1359 (VIS-A). Phase 1.1 follow-on: #1358/#1360 (admission-gate enforcement).

## Context

Every zBuild pipeline run is steered by a **vision document** — a short, human-readable statement
of a repository's intent and guiding principles. `docs/VISION.md` has existed as an informal
intent statement, and the admission-gate and redaction-chokepoint wiki pages already anticipate
a Phase 1.1 conformance check (#1358/#1360). However, there was no formal standard specifying:

- **Where** to find the vision document (resolution order across candidate locations)
- **What structure** is required (mandatory headings, optional sections)
- **How long** it may be (a ~300-word cap keeps it usable as a prompt prefix)
- **How to validate** conformance programmatically

Without a machine-verifiable contract the vision document cannot be used as a reliable
pipeline input or failure signal, and the admission-gate integration (Phase 1.1) has no spec to implement against.

## Decision

### 1. File resolution order

The pipeline resolves the vision document by checking these paths in order, relative to the repo root:

1. `.zbuild/vision.md` — per-repo override (highest precedence; same `.zbuild/` seam as ADR-016/032)
2. `docs/VISION.md` — conventional location for projects that version docs alongside source
3. `VISION.md` — flat-root fallback for minimal repos

The first path that resolves to a readable file wins. If none is present, the file is absent
(Phase 1.1 will make this a fail-closed gate; Phase 1.0 treats absence as non-fatal).

### 2. Document format

The vision document is a **Markdown file** with:

- **Optional YAML frontmatter** (`---` block at top): `version` and `updated` keys are recognized
  but not required; unrecognized keys are silently ignored.
- **Required sections** (H2 headings, exact spelling):
  - `## Intent` — one paragraph stating what the project does and for whom
  - `## Principles` — a list or paragraph of guiding values that constrain decisions
- **Optional sections** (any H2 not listed above): `## Consistency anchors`,
  `## Constraints / guardrails`, and any repo-specific additions are permitted.
- **Word cap:** body text (excluding frontmatter, headings, and blank lines) MUST NOT exceed 300 words.
  The cap keeps the document injectable as a stage prompt prefix without crowding the working context.

### 3. Validator public API (`scripts/lib/vision.sh`)

A source-only library (`[[ -n $_VISION_LOADED ]] && return 0`) exposes two functions:

```
load_vision_doc [repo_root]   → prints resolved path, rc=0; rc=1 if absent
validate_vision_doc <path>    → rc=0 if valid; rc non-zero with stderr diagnostics per violation
```

`validate_vision_doc` checks:
1. `## Intent` heading present
2. `## Principles` heading present
3. Body word count ≤ 300

### 4. Injection point

When the vision document is present and valid, it is injected into stage prompts **through
`core/redaction/apply_scope_redaction`** (ADR-004) — no stage or plugin injects it directly.
The injection mechanism itself is Phase 1.1 scope; this ADR specifies the contract the injected
content must satisfy.

## Consequences

- `docs/VISION.md` becomes the **first conformant instance** of this standard.
- `scripts/lib/vision.sh` is the authoritative validator; the admission gate (Phase 1.1) will
  source it.
- The ~300-word cap is deliberately generous enough for a real intent statement but short enough
  to be injected as a prompt prefix without crowding the model context.
- `docs/wiki/mechanics/vision-document.md` documents the standard and includes a worked example.

## Implementation Notes (Phase 1.0 — issue #1359)

- `scripts/lib/vision.sh` ships in Phase 1.0 as a standalone utility; it is NOT yet wired into
  the admission gate or stage dispatch. Phase 1.1 (#1358/#1360) adds the fail-closed gate.
- `docs/VISION.md` already satisfies the required-headings contract and stays under 300 words;
  the frontmatter block (`version: '1.0'`, `updated: '2026-07-12'`) is prepended in this issue.
- `tests/unit/vision-validator-test.sh` covers five behavioral contracts: valid doc passes,
  missing `## Intent` fails, missing `## Principles` fails, over-300-word doc fails, and
  `load_vision_doc` resolves the first present path in search order.
- ADR-016 `.zbuild/` precedence (the per-repo override seam) is the motivation for placing
  `.zbuild/vision.md` first in the search order.
