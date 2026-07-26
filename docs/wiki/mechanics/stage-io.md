# stage-io

In plain terms: every time a stage runs, zBuild prints an INPUT banner before the action and an OUTPUT banner after, so an operator always knows exactly what went in and what came back.

**Per-stage INPUT/OUTPUT banners emitted through a single chokepoint** (`_stage_io_compose_banner` in `core/output/stage-io.sh`).

## persona: field

The INPUT banner optionally carries a `persona:` field that reflects which persona the engine applied to the stage. The field has three states:

- **`persona: <id>`** — a named persona was resolved and applied (e.g. `persona: plan-writer`).
- **`persona: none (fallback)`** — a persona was configured for the stage but its manifest was absent; the engine fell back to no persona.
- **omitted** — the stage has no persona concept (e.g. command or computed stages); the field is not printed.

### Effective, not configured

The `persona:` field reports what persona resolution **actually returned**, not whatever was configured. The value is engine-rendered at the single chokepoint (`_stage_io_compose_banner()`); no stage or lens code prints `persona:` directly. An operator reading the INPUT banner knows the effective applied identity, not just the requested one.

## Environment variables

- **`ZBUILD_STAGE_IO_FD`** — the file descriptor banners are written to (default: `2`). Must not be `0` (stdin) or `1` (stdout); validated at module load.
- **`ZBUILD_STAGE_IO_PERSONA`** — set by the engine before calling `stage_io_begin`. Absent when the stage has no persona; set to `<id>:fallback` when the persona manifest was missing.

## Ordering contract

The INPUT banner is emitted **before** the action runs and the OUTPUT banner **after** it returns. This ordering is defined in ADR-015 §v4 (input-before-action contract, issue #491).

See [[mechanics/redaction-chokepoint]], ADR-015.
