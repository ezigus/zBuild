# ADR-041: flock as the serialization chokepoint

**Status:** Accepted (2026-06-28)
**Issue:** #1154 (EPIC #1129)
**Related:** ADR-004 (redaction chokepoint — the precedent pattern), ADR-005 (claim-coordinator: flock for label leases, and the required-tool justification), ADR-035 (orchestrator run-state isolation), ADR-039 (parallel stage groups — concurrent emitters)

## Context

zBuild has several places that must serialize concurrent access to a shared
resource: the claim-coordinator's label leases (ADR-005), the event-bus
`events.jsonl` append, the event-bus SQLite mirror (#1153), and state-file
read-modify-write (`core/state/atomic.sh` `locked_state_update`). EPIC #1129's
parallel stage groups (ADR-039) add genuinely concurrent event emitters, raising
the cost of getting this wrong.

`flock` is already the primitive zBuild uses for this, and it is a **required**
installed tool (install.sh hard-requires it; ADR-005 explains why). But there was
no policy making it *the* sanctioned mechanism, so serialization risked being
reinvented ad-hoc — fixed `sleep`s, bare lockfiles without `flock`, or leaning on
a tool's *internal* locking (e.g. SQLite `busy_timeout`, where the tool — sqlite3
— is merely *optional*, and the lock contention manifested as the flaky tail
latency in #1153/#1149).

## Decision

**`flock` is the serialization chokepoint.** Any critical section or concurrent
write to a shared resource MUST be serialized with `flock` (guarded by
`zbuild_has_flock` with a best-effort fallback), not with `sleep`-based timing,
unsynchronized writes, or reliance on an *optional* tool's internal locking when
`flock` can serialize deterministically.

Corollaries:
- Independent resources use **distinct lock files** so an optional/best-effort
  writer never blocks an authoritative one (e.g. the event-bus SQLite mirror
  uses `events.db.lock`, separate from `events.jsonl.lock`, so the mirror can
  never stall the source-of-truth jsonl append — #1153).
- A **best-effort** writer (e.g. the unread event-bus SQLite mirror) acquires
  its lock NON-BLOCKING (`flock -n`) and SKIPS the write on contention rather
  than waiting — so a high-frequency emitter (parallel members, kill-timing
  tests) pays zero added latency and a dropped row is harmless (#1153). An
  **authoritative** writer may use a bounded wait (`flock -w N`) and must fail
  soft on timeout (never abort the caller).

## Consequences

- Serialization is deterministic and uses a required tool, rather than
  probabilistic (a tool's internal busy-retry) or timing-based (`sleep`).
- One discoverable convention; new code has a clear answer for "how do I make
  this safe under concurrency."
- Authoritative serialization is deterministic (no probabilistic busy-retry);
  best-effort writers use non-blocking acquire so they add no latency under
  contention (they skip instead) — important for high-emit-rate paths (#1153).
- `flock` remains a hard install prerequisite (ADR-005); the best-effort
  fallback keeps non-flock environments functional but unserialized.

## Implementation Notes (EPIC #1129, executed in #1153)

- Call sites following this policy: ADR-005 label leases; `eb_emit_event` jsonl
  append and SQLite mirror (`core/event-bus/event-bus.sh`, #1153); state writes
  (`core/state/atomic.sh`); the parallel orchestrator's parent-serial state
  writes (ADR-039 / #1131).
- Anti-patterns to reject in review: synchronizing via `sleep`; concurrent
  unsynchronized appends/writes to a shared file or DB; depending on
  `sqlite3 busy_timeout` for write serialization where a `flock` is available.

## References

- [ADR-004 — redaction chokepoint](ADR-004-redaction-chokepoint.md)
- [ADR-005 — claim-coordinator](ADR-005-claim-coordinator.md)
- [ADR-035 — orchestrator run-state isolation](ADR-035-orchestrator-run-state-isolation.md)
- [ADR-039 — parallel stage groups](ADR-039-parallel-stage-groups.md)
