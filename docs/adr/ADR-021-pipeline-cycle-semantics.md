# ADR-021: Pipeline Cycle Semantics (Outer-Cycle Framework)

**Status:** Proposed (F1) → Accepted (after F2 / #511)
**Date:** 2026-05-30
**Amends:** ADR-006 (resume contract), ADR-013 (canonical stage list), ADR-015 (stage-io v6), ADR-018 (Pattern 2 inner loops), ADR-020 (contract validator)

## Context

ADR-013 fixed the canonical linear stage sequence (`intake → plan → ... →
monitor`). ADR-018 added an **inner** loop (Pattern 2 — `route_to_model_loop`)
that lets a single stage's plugin iterate its LLM calls until a DONE-sentinel
or max-turns cap. Neither addresses the empirically common pattern where
**multiple consecutive stages** must iterate together: build→test→build→test
until tests pass, plan→design→plan until the lens audit converges, etc.

Without an outer cycle:
- Plugins re-implement convergence in ad-hoc ways inside their `run` hook,
  forking state from the engine and breaking ADR-006's resume contract.
- Operators see no first-class "iteration N of M" semantics in banners,
  events, or state.
- Plateau/divergence detection (the proven loop-safety primitives from
  legacy `loop-convergence.sh`) lives outside the engine, so each plugin
  reinvents them with different thresholds and bugs.

## Decision factors

| Factor | Weight | Notes |
|---|---|---|
| Backwards compatibility | Mandatory | Existing templates and plugins must run unchanged. |
| Explicit termination contract | Mandatory | Every cycle must terminate via a declared predicate, not an implicit loop. |
| Resume safety | Mandatory | Mid-cycle kill -9 must not lose history or restart from iter 1. |
| Observable iteration | Mandatory | Banners and events must carry `iter=N/max`. |
| Composability | Important | Cycles compose with the canonical linear list, not replace it. |
| Operator simplicity | Important | Template syntax is overlay, not nested replacement. |

## Decision

Introduce an **outer cycle** as an **overlay** on the canonical stage list.
A cycle is a declarative grouping of contiguous canonical stages plus a
termination predicate. The runner walks the canonical list as today; when
it encounters a stage that is the first stage of a declared cycle, it
hands control to `cycle_orchestrator_run` for the whole cycle and resumes
linear dispatch when the orchestrator returns.

### Decision points

1. **Overlay, not replacement.** Cycle membership annotates which stages
   iterate. Canonical order in `stages:` is preserved; the contract validator
   (ADR-020) still walks `stages:` for upstream resolution.
2. **Structured `until:` grammar (not string DSL).** v1 fields: `verdict`,
   `status`; v1 ops: `eq`, `ne`. Field-missing → **unconverged** (never falsely
   converge). Emits `cycle.iteration.verdict_missing`.
3. **File-path feedback (not env-vars, not in-memory).** Feedback artifacts are
   copied to `${state_dir}/cycle-<id>/iter-<N>/feedback/<to_field>.txt`. Plugins
   read via `ZBUILD_CYCLE_FEEDBACK_DIR`. Missing required from-fields fail loud
   with `cycle.feedback.missing` (never empty-string-substitute).
4. **Single atomic state write per iter boundary.** All updates (current_iter,
   iter[] append, status) go through one `locked_state_update` mutator.
5. **Trap composition.** Runner owns EXIT trap; cycle owns INT/TERM only. Re-
   installs INT/TERM after each stage (route.sh inner loop clobbers them).
6. **Termination priority.** Eval at end of each iter, in order:
   convergence > max_iterations > plateau > divergence > signal.
7. **`max_iterations` REQUIRED.** Bounded 1..10 (HARDCODED `_CYCLE_ABSOLUTE_MAX`
   checked BEFORE the template value). Missing or out-of-range → `cycle.config.invalid`
   at template-load, fail-closed.
8. **Flag-gated dispatch.** `ZBUILD_CYCLES_ENABLED=0` (default in F1) — no
   production behavior change. F2 wires the build/test cycle and enables the flag.

### Template syntax

```yaml
stages:               # canonical order PRESERVED per ADR-013
  - id: intake
  - id: build
  - id: test
  - id: review

cycles:               # NEW overlay
  - id: build-test
    stages: [build, test]            # MUST be contiguous subseq of stages[]
    until:
      stage: test                    # MUST be in cycle.stages[]
      field: verdict                 # whitelist v1: verdict | status
      op: eq                         # whitelist v1: eq | ne
      value: pass
    max_iterations: 5                # REQUIRED 1..10
    on_max: continue                 # continue | halt
    plateau:
      window: 3                      # default 3
    divergence:
      window: 2                      # default K=2
    feedback:                        # OPTIONAL
      - from: { stage: test, output: primary.txt }
        to:   { stage: build, input: prior_test_result, required: false }
```

### State schema (additive)

```json
"cycle_iterations": {
  "<cycle_id>": {
    "status": "in_progress|complete|plateau|divergence|max_iterations|verdict_missing|aborted|preflight_failed",
    "current_iter": <N>,
    "max_iterations": <M>,
    "history_file": "<state_dir>/cycle-<id>-history.jsonl",
    "iter": [
      {"n":1,"status":"complete","verdict":"pass","failure_count":0,"ended_at":"..."}
    ]
  }
}
```

Older state files without `.cycle_iterations` are upgraded in-place by the
defensive `(.cycle_iterations //= {})` init in every mutator.

### Event schema additions

Registered in `config/event-schema.json::known_types`:

| Event | Required keys |
|---|---|
| `cycle.start` | cycle_id, iter=1, max, stages |
| `cycle.iteration.complete` | cycle_id, iter, verdict, velocity, failure_count |
| `cycle.complete` | cycle_id, iter, reason ∈ {converged,plateau,max_iterations,divergence,verdict_missing,aborted,error} |
| `cycle.plateau` | cycle_id, iter, evidence, streak |
| `cycle.divergence` | cycle_id, iter, velocity_history |
| `cycle.aborted` | cycle_id, iter, signal |
| `cycle.config.invalid` | cycle_id, reason, value |
| `cycle.feedback.missing` | cycle_id, iter_next, from_stage, to_field, required, src |
| `cycle.iteration.verdict_missing` | cycle_id, iter, stage, field |
| `cycle.history.lost` | cycle_id, iter, reason |
| `cycle.metric.invalid` | cycle_id, metric, value |
| `cycle.plateau.skipped` | cycle_id, iter, reason, have, need |
| `cycle.iter.stale_artifact` | cycle_id, iter, path |

### Orchestrator surface

```
cycle_orchestrator_run <cycle_id> <state_dir> <state_file>
  rc: 0=converged | 1=max_iterations | 2=plateau | 3=divergence |
      4=config_invalid / aborted-on-feedback | 130=aborted (signal)
  Sets: _CYCLE_LAST_TERMINATED_REASON, _CYCLE_LAST_ITERATIONS,
        _CYCLE_LAST_HISTORY_FILE
```

Internal helpers (`_cycle_*`) own template loading, dispatch, traps, history
JSONL, structured `until` eval, max-iter check, plateau/divergence detection,
feedback file wiring, and atomic per-iter state writes.

### Runner integration

`_TPL_DISPATCH_UNITS[]` is built from `_TPL_STAGES[]` overlaid with `cycles:`.
Each unit is `stage:<id>` or `cycle:<id>`. The runner branches on this list
when `ZBUILD_CYCLES_ENABLED=1` and at least one `cycle:*` unit is present;
otherwise it falls through to the legacy stage loop (zero behavior change).

## Consequences

**Good:**
- Cycles compose with the canonical list — no surprise reordering.
- Convergence vocabulary is unified (one set of detectors, one set of events).
- Resume is durable: iter history lives in JSONL plus state.
- Fail-loud on every silent-failure class (verdict missing, feedback missing,
  metric invalid, history lost, plateau skipped).

**Bad:**
- Template authors learn one more keyword (`cycles:`).
- The orchestrator runs with `set +e` internally to protect set-e-naive
  callers; helpers must explicitly check return codes.

**Open questions (deferred to F2 / #511):**
- Concrete build/test cycle wiring in `standard.yaml`.
- Plugin-side helpers for reading `ZBUILD_CYCLE_FEEDBACK_DIR`.

## F1 vs F2 split

| Item | F1 (#512, this PR) | F2 (#511) |
|---|---|---|
| Cycle parser + validator | ✓ | — |
| `cycle_orchestrator_run` framework | ✓ | — |
| Event registrations | ✓ | — |
| State schema additions | ✓ | — |
| Test fixtures + unit/integration tests | ✓ | — |
| Concrete cycle in `standard.yaml` | ✗ | ✓ |
| Build/test plugin feedback wiring | ✗ | ✓ |
| `ZBUILD_CYCLES_ENABLED=1` by default | ✗ | ✓ |

## Implementation Notes

- HARDCODED `_CYCLE_ABSOLUTE_MAX=10` checked BEFORE template's value.
- Refuse `max_iterations <= 0` and `> 10` → `cycle.config.invalid`, fail-closed.
- Plateau detection requires `iter ≥ 2 AND history_lines ≥ N` (skip with
  `cycle.plateau.skipped reason=insufficient_history` otherwise).
- Divergence requires `iter ≥ K+1` (silent skip — divergence at start of
  cycle is not signal).
- Verdict missing never feeds plateau/divergence math.
- Numeric inputs validated `[[ "$v" =~ ^[0-9]+$ ]] || emit cycle.metric.invalid`.
- Trap composition: runner owns EXIT (single owner). Cycle installs INT/TERM
  only and re-installs after every dispatched stage (silent-failure finding
  #6: route.sh `_route_loop_install_traps` clobbers without saving prior).

## References

- ADR-006 — resume contract (amended below for `cycle_iterations` persistence)
- ADR-013 — canonical stage list (amended below for cycle composition)
- ADR-015 — stage-io capture (amended for per-iter banner header)
- ADR-018 — inner loop Pattern 2 (disambiguates from outer cycles)
- ADR-020 — pre-flight contract validator (amended for cycled stages)
- `legacy/scripts/lib/loop-convergence.sh` — read-only convergence reference
- `core/pipeline/cycle-orchestrator.sh` — implementation
- `core/pipeline/template.sh` — cycles overlay parser
