# Phase Deferrals Index

This document is the authoritative index of items intentionally deferred out of
their originating phase.  Each entry links to the tracking issue and records why
the item was moved.  Consult this file when reviewing the ADR-002 pruning
protocol for any legacy sources whose keeper has a deferred trial.

## Phase 1 Deferrals

| # | Title | Originating ADR | Reason |
|---|-------|-----------------|--------|
| #287 | Manifest validator: enforce full ADR-001 schema (hooks per kind, requires.core via YAML, provides.artifact_type, state.persisted/reconstructed) | ADR-001 | Full YAML-structural validation adds coupling risk; 4-field validator is sufficient for Phase 0.5 plugin set |
| #288 | Fail-closed artifact-presence scanner (synthesize blocking finding when plugin declares outputs[].path but produces nothing) | ADR-001 | Requires artifact-schema.json (#361) to land first; no Phase 0.5 plugin yet skips writing its canonical artifact |
| #289 | Router precondition fail-closed when ZBUILD_RUN_ID or ZBUILD_EVENTS_JSONL unset + gate --skip-precondition behind operator override + audit event | ADR-004 | Narrow edge-case that does not affect single-machine Phase 0.5 runs; rescoped 2026-05-26 |
| #294 | Plugin registry: YAML-structural manifest validation (replace fragile grep for redaction requirement) | ADR-001 | Companion to #287; requires a stable manifest schema before structural validation can be written without chasing schema changes; deferred until Phase 1 contracts settle |

## Phase 2 Deferrals

| # | Title | Originating ADR | Reason |
|---|-------|-----------------|--------|
| #293 | State read fail-closed on JSON corruption — narrow lift from Phase 2 #38 | ADR-006 | **Closed** — implemented in PR #329 (2026-05-27); listed here for audit completeness |

## Phase 5 Deferrals

| # | Title | Originating ADR | Reason |
|---|-------|-----------------|--------|
| #291 | Retrofit 'Implementation Notes' appendix on ADRs 001–007 (pattern from ADR-009) | ADR-001–007 | Operator override TTL and full appendix retrofit are cosmetic; unblocked for Phase 5 cleanup |

## Notes

- Items in this index are **not blocked**; they are intentionally scheduled.
- When a deferred item lands, update this table and the originating ADR's
  Implementation Notes section.
- ADR-002's pruning protocol cross-links here: if a keeper's 5-test trial is
  blocked on a deferred issue, its `legacy/migrated/<keeper-id>.md` tombstone
  MUST cite the relevant row in this table by issue number.
