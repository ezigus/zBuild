# ADR-006: Resume Contract — Pipeline-Resume Memory

**Status:** Accepted
**Date:** 2026-05-24

> **Memory type:** This ADR governs **pipeline-resume memory** — the operational
> state needed to continue an interrupted pipeline from where it stopped (which
> stage failed, which iteration counter, which checkpoint, scope manifest hash,
> plugin state, claim lease). It is one of zBuild's **two distinct memory models**:
>
> | Memory type | Purpose | Where defined | Backend |
> |---|---|---|---|
> | **Pipeline-resume memory** | Continue an interrupted pipeline at the failure point | ADR-006 (this), transported by ADR-010 cache | Always-on; baked into core/state/ |
> | **Learning memory** | Remember patterns, embeddings, decisions across pipelines and runs | [ADR-011](ADR-011-pluggable-backends.md) | Pluggable: sqlite default, ruflo HNSW optional |
>
> The two are independent: a pipeline can resume cleanly with no learning
> memory available, and learning memory persists across pipelines whether or
> not a particular pipeline ever resumed.

## Context

The legacy resume semantics are partially documented. `resume_state` in `legacy/scripts/lib/pipeline-state.sh:876-1075` restores stage statuses and `SELF_HEAL_COUNT` but **does not** read back `CURRENT_ITERATION` — verified at line 269 (written) and confirmed absent in lines 987-1026 (read). On resume, plugins relying on iteration count receive the *initial* value (often 0), causing the loop to re-do iterations.

Other state that doesn't survive resume:
- `loop-state.md` (gitignored; per-iteration debug state; regenerated each run).
- Runtime caches (computed git diffs, environment snapshots, router recommendations).
- Scope-violation diagnostic logs (if `persist_artifacts` failed mid-write).

This isn't a bug per se; it's a contract that was never written down. Plugins inherit different assumptions: some assume iteration is durable; some assume it's reconstructed; some don't think about it at all. The result is brittle resume behavior.

## Decision

zBuild's resume contract is explicit. Two tiers: **persisted** (engine guarantees survival) and **reconstructed** (engine or plugin recomputes at the start of `run` after resume — ADR-056 deleted the `init` hook that used to own this).

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

### Reconstructed (computed at the start of `run` after resume)

| Key | Owner | How |
|---|---|---|
| `git_diff` | per-stage | `git diff` against baseline |
| `repo_hash` | core/state | hash of `git rev-parse HEAD` |
| `env_snapshot` | per-stage | captured in the `run` preamble |
| `router_recommendations` | core/router | recomputed from cost ledger + outcomes |
| `scope_violations_history` | per-stage | replayed from event bus |
| `loop_state_md` | debug | regenerated each iteration |

### Plugin responsibilities

Every plugin's `manifest.yaml` MUST declare:

```yaml
state:
  persisted: [findings, last_cycle_score]    # keys to write via core/state
  reconstructed: [git_diff, repo_hash]        # keys to recompute in the run preamble
```

The engine validates:
1. Every key in `persisted` has a corresponding `core/state/write_plugin_state <plugin_id> <key> <value>` call in `plugin.sh` (greppable; loose but catches obvious omissions).
2. Every key in `reconstructed` is set by the `run` preamble before the stage does any work. Asserted at runtime: missing keys → plugin refuses to run.

### Idempotency scope for `run`

"Plugins MUST be idempotent across re-runs of `run`" means:

- **In scope (A — what is guaranteed):** within a *single resume operation* on a *single pipeline-state.json*, the engine may call `run` more than once (e.g., the cycle re-enters the stage after a transient failure). The plugin MUST tolerate this: side-effects must be writable-or-reread without duplication. Concretely: writing to `core/state/write_plugin_state` is idempotent because the engine de-duplicates; writing to an external sink (Slack, GitHub comment) is NOT idempotent and MUST be guarded by a sentinel key in persisted state.
- **Out of scope (B — what is NOT guaranteed):** idempotency across *different* pipeline runs (run A resumes, then unrelated run B starts). Run B starts fresh; the plugin's `run` may legitimately re-emit side-effects from run B even if run A already did so. Cross-run de-duplication is the calling system's concern (e.g., GitHub issue body de-dup belongs in the output-destination layer, not in the plugin).

**Worked example.** `security-lens` declares `persisted: [last_pr_comment_id]`. On its first `run`, it posts a comment, captures the comment ID, writes it via `core/state/write_plugin_state`. On a second `run` *within the same resume*, it reads the persisted ID, sees the comment exists, skips the post. On a `run` for a different pipeline run, it has no persisted ID for that run and posts again — that's correct, because the runs are independent artifacts.

### Resume sequence

```
1. core/state load(pipeline-state.json) → on error: try .bak; on .bak error: refuse to resume
2. core/state restore persisted state into runtime
3. For each plugin in dependency order:
   a. call plugin.run with ZBUILD_RESUMING=1 (ADR-056 deleted the init hook;
      reconstruction is the run preamble's job)
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
- Cost equivalence (resume re-enters `run` and may re-route models).
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

## Amendment — `preflight_failed` pipeline status (issue #496, ADR-020)

ADR-020 introduces a pre-flight inter-stage data contract validator that
runs at pipeline start (after `load_template`, before any stage executes).
When the validator fails in `ZBUILD_CONTRACT_VALIDATOR=enforce` mode, the
runner writes a minimal state.json with `status: preflight_failed` so
operators can distinguish "pipeline halted before any stage ran" from
"pipeline interrupted mid-flight."

The pipeline status enum now includes:

| Value | Set by | Meaning |
|---|---|---|
| `in_progress` | runner | stages running |
| `complete` | runner | all stages succeeded |
| `interrupted` | runner | aborted mid-flight (signal, mid-stage failure) |
| `aborted` | runner / operator | explicit cancellation |
| `failed` | runner | terminal failure after at least one stage ran |
| `preflight_failed` | contract-validator (ADR-020) | rejected before any stage; no resume target |

Pipelines in `preflight_failed` status are NOT resumable; the runner's
resume policy refuses to restart them (the contract violation is in the
template or manifests, not in execution state). The resume command should
surface a "fix the contract first" hint rather than attempting to continue.

## Amendment — `cycle_iterations` persistence (issue #512, ADR-021)

ADR-021 introduces the outer-cycle orchestrator. Cycle state is persisted
under a new schema-additive key on `pipeline-state.json`:

```json
"cycle_iterations": {
  "<cycle_id>": {
    "status": "in_progress|complete|plateau|divergence|max_iterations|verdict_missing|aborted|preflight_failed",
    "current_iter": <N>,
    "max_iterations": <M>,
    "history_file": "<state_dir>/cycle-<id>-history.jsonl",
    "iter": [...]
  }
}
```

`stage_statuses[]` enum is **unchanged**. Per-cycle stage outcome lives
under `cycle_iterations[X].iter[N].verdict`. Older state files (no
`.cycle_iterations` key) are upgraded in-place on the next write via
defensive `(.cycle_iterations //= {})` init in every mutator.

### Step 3.5 — mid-cycle resume hand-off

Inserted between the existing resume sequence's step 3 and step 4:

> 3.5. If `cycle_iterations[X].status == in_progress`:
> - Re-validate the last completed stage's primary artifact via the
>   #496 validator. If missing → emit `cycle.iter.stale_artifact` and
>   re-run iter N from scratch (drop history rows for N, keep N-1).
> - If artifact present → resume between iters; start iter N+1 with
>   feedback already wired.
> - Restore `_cycle_history[]` from JSONL BEFORE plateau/divergence
>   eval; empty rehydration when `iter > 1` → emit `cycle.history.lost`
>   and fail closed (no silent coast).

Without this hand-off, a `kill -9` during iter 2 of a 3-iter cycle would
restart from iter 1, losing progress and any cumulative state.

## Amendment — atomic `.bak` rotation via `atomic_replace` (issue #909)

The `.bak` rotation in `atomic_write` (the "Persisted" write path above) previously used
`cp "$target" "${target}.bak"` — a read + separate write — so a concurrent reader (or a crash
mid-copy) could observe a torn `.bak`. Because `.bak` is the **corruption-recovery source**
(the Resume sequence reads it on primary failure; `read_state`/`locked_state_update`/`validate_json`
restore from it), a torn backup silently defeats recovery — and the flock-less fallback in
`core/state/atomic.sh` makes this race live on systems without `flock`.

Issue #909 introduces `atomic_replace <src> <dst>` (`scripts/lib/helpers.sh`): copy to a unique
temp **in dst's directory**, then `mv` (atomic rename on a POSIX filesystem). `atomic_write` now
rotates `.bak` via `atomic_replace`. The **contract is unchanged** — `.bak` remains the recovery
source and the Resume sequence is unchanged — but the guarantee is now stronger: a crash or
concurrent writer leaves either the old `.bak` or a complete new one, never a partial one. The
mirror-image recovery *restores* (`.bak`→target) are converted to the same primitive under #946.

Issue #946 completes the pair: the three recovery restores — `validate_json` (`scripts/lib/helpers.sh`),
`read_state` and `locked_state_update`'s empty-recovery branch (`core/state/atomic.sh`) — previously
used a bare `cp "${x}.bak" "$x"`, so a reader holding no lock (notably `read_state`, called outside
the flock) could observe a torn target *during recovery*. All three now restore via `atomic_replace`,
and a failed restore **fails closed** (returns the corruption error) rather than reporting false
success on a still-corrupt file — closing a latent silent-failure the bare `cp` masked.

## Implementation Notes (Phase 0.5 — issue #291)

- **24h auto/manual resume boundary** is implemented at `core/state/resume.sh:178–199` (`age_seconds -lt 86400` → `auto_resume`, else `manual_resume_only`). Both BSD and GNU date parsing supported.
- **`current_iteration` persistence** is wired through `init_state()` (resume.sh:63 sets 0) and surfaces in the resume event at resume.sh:96.
- **Test coverage gaps tracked separately:** #299 (24h boundary not exercised), #300 (runner abort-trap state-write failure path not exercised by mutation A2).
- **Atomic `.bak` rotation (issue #909):** `atomic_write` rotates `.bak` via `atomic_replace` (`scripts/lib/helpers.sh`, temp+rename). Regression-guarded by `tests/unit/scripts-lib-atomic-replace-test.sh` (incl. a concurrent-reader negative control) and the 50× stability loop in `tests/integration/concurrent-state-test.sh`.
- **Atomic recovery restore (issue #946):** the three `.bak`→target restores (`validate_json` in `scripts/lib/helpers.sh`; `read_state` and the empty-recovery branch of `locked_state_update` in `core/state/atomic.sh`) restore via `atomic_replace` and fail closed on restore failure. Guarded by Case F (`[SPEC-3]`, a 12-writer concurrent-restore negative control proven to tear under bare `cp`) in `tests/unit/scripts-lib-atomic-replace-test.sh`, a `read_state` recovery case in `tests/unit/core-state-test.sh`, and Scenario 11 (complete large-`.bak` recovery) in `tests/integration/state-corruption-failclosed-b-test.sh`.

## References

- [KEEPERS.md §C correction: CURRENT_ITERATION lost on resume](../KEEPERS.md#section-c--reliability--safety-expanded)
- [KEEPERS.md §C addition 8: resume best-effort contract](../KEEPERS.md#additions-hidden-safety-primitives-the-original-spec-missed)
- [ARCHITECTURE.md §4](../ARCHITECTURE.md#4-state-model) — full state model.
- `legacy/scripts/lib/pipeline-state.sh:269` (write) vs `:987-1026` (read) — the gap this ADR closes.
