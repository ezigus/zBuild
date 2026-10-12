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

The pipeline reads the vision document from the repository's zBuild settings area,
`.zbuild/vision.md`, and nowhere else (amended 2026-10-12). zBuild runs from its install on
any repository, so it does not guess at a repository's own layout: a `docs/VISION.md` or root
`VISION.md` was not written for zBuild and is not read. (Until 2026-10-12 the search also tried
`docs/VISION.md` and `VISION.md`; zBuild's own vision moved from `docs/VISION.md` to
`.zbuild/vision.md`.) If it is absent, the admission gate applies (Phase 1.1).

The vision reaches every stage as the **Intent** part of the engine's From the repo block
(ADR-067 §8), no longer as a preamble the router puts on line 1 of every prompt.

### 2. Document format

The vision document is a **Markdown file** with:

- **Optional YAML frontmatter** (`---` block at top): `version` and `updated` keys are recognized
  but not required; unrecognized keys are silently ignored.
- **Conventional sections** (H2 headings; encouraged but not enforced by the validator):
  - `## Intent` — one paragraph stating what the project does and for whom
  - `## Principles` — a list or paragraph of guiding values that constrain decisions
- **Optional sections**: `## Consistency anchors`, `## Constraints / guardrails`,
  and any repo-specific H2 additions are permitted.
- **Word cap:** body text (excluding frontmatter, headings, and blank lines) MUST NOT exceed 300 words.
  The cap keeps the document injectable as a stage prompt prefix without crowding the working context.

### 3. Validator public API (`scripts/lib/vision.sh`)

A source-only library (`[[ -n $_VISION_LOADED ]] && return 0`) exposes two functions:

```
load_vision_doc [repo_root]   → prints resolved path, rc=0; rc=1 if absent
validate_vision_doc <path>    → rc=0 if valid; rc non-zero with stderr diagnostics per violation
```

`validate_vision_doc` checks:
1. Body word count ≤ 300

**Amendment (VIS-C follow-up):** The `## Intent` and `## Principles` heading requirements
were removed. Heading presence is now advisory content guidance, not a machine-enforced
constraint. The word cap remains the only objective validator gate.

### 4. Injection point

When the vision document is present and valid, it is injected into stage prompts **through
`core/redaction/apply_scope_redaction`** (ADR-004) — no stage or plugin injects it directly.
The injection mechanism itself is Phase 1.1 scope; this ADR specifies the contract the injected
content must satisfy.

### 5. Admission-gate mode & bypass (Phase 1.1 — issue #1360)

The runner enforces this standard at pre-flight via `vision_gate_mode` (`scripts/lib/vision.sh`),
which resolves the mode with precedence:

1. `ZBUILD_VISION_GATE` environment variable (per-invocation override)
2. `.zbuild/config.yaml` key `vision.gate` (persistent per-repo setting)
3. built-in default: `enforce`

Modes: `enforce` (missing / malformed / over-length vision → `preflight_failed`, fail-closed),
`warn` (advise but proceed), `off` (skip the gate entirely — "just run" without a vision
document). An unrecognized value resolves to `enforce` (fail-closed on misconfiguration). This
lets a repo persistently opt out via config without setting an env var on every run.

## Consequences

- zBuild's own vision (now `.zbuild/vision.md`) is the **first conformant instance** of this standard.
- `scripts/lib/vision.sh` is the authoritative validator; the admission gate (Phase 1.1) will
  source it.
- The ~300-word cap is deliberately generous enough for a real intent statement but short enough
  to be injected as a prompt prefix without crowding the model context.
- `docs/wiki/mechanics/vision-document.md` documents the standard and includes a worked example.

## Implementation Notes (Phase 1.0 — issue #1359)

- `scripts/lib/vision.sh` ships in Phase 1.0 as a standalone utility; it is NOT yet wired into
  the admission gate or stage dispatch. Phase 1.1 (#1358/#1360) adds the fail-closed gate.
- zBuild's vision (then `docs/VISION.md`, now `.zbuild/vision.md`) already stays under 300 words; the frontmatter block (`version: '1.0'`,
  `updated: '2026-07-12'`) is prepended in this issue. It is not required to carry `## Intent` /
  `## Principles` headings (see the VIS-C follow-up amendment in §3) but conforms anyway as
  documentation guidance.
- `tests/unit/vision-validator-test.sh` covers behavioral contracts: valid doc passes,
  a doc missing `## Intent` or `## Principles` still passes (word-cap-only validation, VIS-C
  follow-up), over-300-word doc fails, an unterminated frontmatter fence fails, and
  `load_vision_doc` resolves the first present path in search order.
- ADR-016 `.zbuild/` precedence (the per-repo override seam) is why the vision lives in
  `.zbuild/vision.md`. Enforced by `tests/unit/vision-validator-test.sh` SPEC-5 and
  `tests/unit/vision-admission-gate-test.sh` SPEC-2 (only `.zbuild/vision.md` is read; zBuild's own
  is there and `docs/VISION.md` is gone), and `tests/unit/stage-prompt-contract-test.sh` F1, F2
  (the vision reaches every stage under From the repo).
