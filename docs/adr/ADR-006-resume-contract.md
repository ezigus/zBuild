# ADR-006: Resume Contract

**Status:** Accepted
**Date:** 2026-05-24

## Context

The legacy resume semantics are partially documented. `resume_state` in `legacy/scripts/lib/pipeline-state.sh:876-1075` restores stage statuses and `SELF_HEAL_COUNT` but **does not** read back `CURRENT_ITERATION` — verified at line 269 (written) and confirmed absent in lines 987-1026 (read). On resume, plugins relying on iteration count receive the *initial* value (often 0), causing the loop to re-do iterations.

Other state that doesn't survive resume:
- `loop-state.md` (gitignored; per-iteration debug state; regenerated each run).
- Runtime caches (computed git diffs, environment snapshots, router recommendations).
- Scope-violation diagnostic logs (if `persist_artifacts` failed mid-write).

This isn't a bug per se; it's a contract that was never written down. Plugins inherit different assumptions: some assume iteration is durable; some assume it's reconstructed; some don't think about it at all. The result is brittle resume behavior.

## Decision

zBuild's resume contract is explicit. Two tiers: **persisted** (engine guarantees survival) and **reconstructed** (engine or plugin recomputes on `init` after resume).

### Persisted (engine-managed, atomic_write + .bak rotation)

| Key | Owner | Type | Notes |
|---|---|---|---|
| `stage_statuses[]` | core/state | enum per stage | `pending`/`in_progress`/`complete`/`failed`/`skipped` |
| `current_iteration` | core/state | int | **NEW in zBuild** — fixes legacy resume gap |
| `self_heal_count` | core/state | int | per-stage retry counter |
| `scope_manifest_hash` | core/redaction | sha256 | detects scope-manifest mutation across resume |
| `cost_ledger_pointer` | core/cost | offset into ledger | enables resume to continue cost tracking |
| `plugin_state[plugin_id]` | per-plugin | opaque blob | plugin-declared state (see below) |
| `claim_lease_id` | core/locks | string | required for claim-coordinator's `heartbeat` after resume |
| `events_db` | core/event-bus | SQLite file | full event history; durable mirror of JSONL |

All persisted state is written via `core/state/atomic_write`, which:
1. Disk-space precheck.
2. `flock` on a sidecar `.lock` file.
3. `mktemp` + write + `fsync`.
4. `mv` (atomic on POSIX).
5. Rotate previous to `.bak`.

Reads use `validate_json`; corruption triggers `.bak` recovery. (KEEPERS §C additions 1–2 lift these into the hot path.)

### Reconstructed (computed on init after resume)

| Key | Owner | How |
|---|---|---|
| `git_diff` | per-stage | `git diff` against baseline |
| `repo_hash` | core/state | hash of `git rev-parse HEAD` |
| `env_snapshot` | per-stage | captured at `init` |
| `router_recommendations` | core/router | recomputed from cost ledger + outcomes |
| `scope_violations_history` | per-stage | replayed from event bus |
| `loop_state_md` | debug | regenerated each iteration |

### Plugin responsibilities

Every plugin's `manifest.yaml` MUST declare:

```yaml
state:
  persisted: [findings, last_cycle_score]    # keys to write via core/state
  reconstructed: [git_diff, repo_hash]        # keys to recompute on init
```

The engine validates:
1. Every key in `persisted` has a corresponding `core/state/write_plugin_state <plugin_id> <key> <value>` call in `plugin.sh` (greppable; loose but catches obvious omissions).
2. Every key in `reconstructed` is set in `init` before any `run` invocation. Asserted at runtime: missing keys → plugin refuses to run.

### Resume sequence

```
1. core/state load(pipeline-state.json) → on error: try .bak; on .bak error: refuse to resume
2. core/state restore persisted state into runtime
3. For each plugin in dependency order:
   a. call plugin.init (with hint: "resume" mode)
   b. plugin reads persisted state via core/state/read_plugin_state
   c. plugin recomputes reconstructed state
   d. plugin refuses to continue if any reconstructed key is missing
4. Engine emits "pipeline.resume" event
5. Continue from last in_progress stage
```

### Best-effort contract

Resume is best-effort, not transparent. The engine guarantees:
- All `persisted` keys survive.
- All `reconstructed` keys are recomputed before any plugin observes them.
- If recomputation fails, the engine refuses to resume and exits with a clear error (no silent half-resume).

The engine does NOT guarantee:
- Identical behavior to an uninterrupted run (LLM nondeterminism makes this impossible).
- Cost equivalence (resume re-runs `init` and may re-route models).
- Wall-clock continuity (the resume adds startup latency).

## Consequences

**Good:**
- Fixes the legacy `CURRENT_ITERATION` resume gap explicitly.
- Plugin authors have a checklist: declare persisted, declare reconstructed, write tests.
- Resume failures are loud and explicit; no silent half-state.
- `kill -9` → restart works for any well-behaved plugin.

**Bad:**
- Manifest authorship friction (one more section to declare).
- Reconstructed state can be expensive to recompute (e.g., large git diffs). Mitigation: plugins can cache reconstructed state into persisted state if they declare both.
- The "every persisted key has a write_plugin_state call" check is grep-based, not type-checked. Accepted as a soft guardrail.

## References

- [KEEPERS.md §C correction: CURRENT_ITERATION lost on resume](../KEEPERS.md#section-c--reliability--safety-expanded)
- [KEEPERS.md §C addition 8: resume best-effort contract](../KEEPERS.md#additions-hidden-safety-primitives-the-original-spec-missed)
- [ARCHITECTURE.md §4](../ARCHITECTURE.md#4-state-model) — full state model.
- `legacy/scripts/lib/pipeline-state.sh:269` (write) vs `:987-1026` (read) — the gap this ADR closes.
