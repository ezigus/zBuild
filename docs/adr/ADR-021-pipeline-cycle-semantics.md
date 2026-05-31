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

**Operator visibility (amended 2026-05-31, issue #526).** HIGH-severity cycle
events — `cycle.feedback.missing`, `cycle.config.invalid`,
`cycle.iteration.verdict_missing`, `cycle.history.lost`, `cycle.metric.invalid`
— emit BOTH a structured JSONL record (durable, machine-readable) AND a
single-line `⚠ <event.type> — <k=v...>` banner to stderr (operator-visible,
indented under the active cycle divider). The HIGH set is owned by
`core/output/event-banners.sh::_HIGH_EVENT_TYPES`; expanding it is a
non-breaking change. Banner emit failure (closed fd, full pipe) MUST NOT
abort the cycle — JSONL is the source of truth.

**Bad:**
- Template authors learn one more keyword (`cycles:`).
- The orchestrator runs with `set +e` internally to protect set-e-naive
  callers; helpers must explicitly check return codes.

**Open questions (deferred to F2 / #511):**
- Concrete build/test cycle wiring in `standard.yaml`.
- Plugin-side helpers for reading `ZBUILD_CYCLE_FEEDBACK_DIR`.

### Operator visibility (#524)

Cycle entry, per-iter boundaries, per-iter outcomes, and cycle exit are
rendered on fd 2 as operator chrome via four helpers in
`core/pipeline/runner.sh` (full spec in ADR-015 §v6 "Cycle-scope visual
hierarchy"). The orchestrator stays event-emit + control-flow only and
calls three optional hook functions when declared:
`cycle_iter_begin_hook`, `cycle_iter_complete_hook`, `cycle_exit_hook`.

Banner emission is single-fan-in through `_cycle_handle_terminal_rc`, which
emits `cycle.complete` (durable) FIRST and then invokes the exit hook
(best-effort) — mirroring the v4 stage-start ordering contract. The
inline `cycle.plateau` / `cycle.divergence` diagnostic events still emit
at their original sites (they carry termination-specific evidence the
central helper doesn't know about); `cycle.complete` is centralised so a
typo in a termination reason cannot silently bypass the exit banner.

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

## Amendment — Concrete F2 wiring (issue #511)

F2 (#511) wires the FIRST production cycle into `config/templates/standard.yaml`:

```yaml
cycles:
  - id: build_test_cycle
    stages: [build, test]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 3
    on_max: continue
    feedback:
      - from: { stage: test, output: test_failures_summary }
        to:   { stage: build, input: prior_test_failures, required: false }
```

### Consumer-side declaration requirement (#511)

Each `feedback.to.input=<X>` MUST appear on the consumer's manifest as
an `inputs[]` entry with `source: cycle_feedback` (see ADR-020
amendment). The contract-validator enforces both directions
(`CYCLE_FB_UNWIRED` and `CYCLE_FB_UNDECLARED`) so neither side can drift.

### Feedback-path resolution (#511 Pin 2)

`_cycle_apply_feedback` resolves the from-stage source via the from-stage
manifest's `outputs[id==<from_output>].path` (with canonical templating
expansion), NOT the legacy `artifacts/<stage>/<output>` hardcoded layout
that real plugins do NOT follow. The pre-F2 implementation silently
failed to find anything for plugins (build, test) that write FLAT into
`state/artifacts/`. F1 mock fixtures (which DO write under
`artifacts/<stage>/`) continue to work via a manifest-absent fallback.

### Per-iter artifact cleanup contract (#511 Pin 8)

Before EACH cycle iteration dispatch, the orchestrator deletes per-cycle
stage primary outputs (read from each stage's manifest
`outputs[primary:true].path`). Without this, a stale prior-iter
`test-results.json` could silently satisfy `until: verdict==pass` even
though the current iter's test stage never ran. Event:
`cycle.artifacts.cleared iter=N stage=<id> path=<resolved>`.

### `test-results.json` reflects the FINAL iter (#511 Pin 16)

The test plugin uses `atomic_write` and overwrites
`state/artifacts/test-results.json` each iteration. The downstream
review stage reads from the canonical path — i.e. it always sees the
LAST iteration's verdict. F2 ships canonical-only; per-iter triage
copies under `state/cycle-<id>/iter-<N>/artifacts/` are out of scope.

### Pipeline halt-vs-continue (#511 Pin 7)

The runner CONTINUES to the next dispatch unit on cycle rc ∈
{0 converged, 1 max_iterations, 2 plateau, 3 divergence} so the review
stage runs and the ADR-019 fail-closed gate (#485) fires as the FINAL
arbiter. Halt only on rc=4 (config_invalid) and rc=130 (aborted).

### `--from-stage` rejection (#511 Pin 14)

`runner.sh --from-stage <S>` is REFUSED with rc=2 when `<S>` is a member
of any cycle, OR appears strictly after a cycle in the dispatch order.
Either case would produce non-deterministic feedback state or consume
stale test artifacts. Event: `pipeline.from_stage.rejected
reason=inside_cycle_or_after`.

### Auto-enable + env override (#511 Pin 4)

Cycles are AUTO-ENABLED when the active template declares any
`cycles:[]`. The legacy `ZBUILD_CYCLES_ENABLED` env var still wins:
`=1` forces on, `=0` forces off (emits `cycle.disabled
reason=env_override` + stderr banner so the operator notices). Unset
falls through to the auto-detect path. Auto-enable emits
`cycle.auto_enabled template=<id>`.

### Empty-feedback preamble omission (#511 Pin 5)

The build plugin's `_build_read_prior_failures` uses `[[ -s file ]]`
(present AND non-empty). An empty feedback file → preamble OMITTED
entirely. Never silent emit.

### Termination → next stage (amendment for #527/#528)

The cycle orchestrator MUST NOT mutate `pipeline_status` on any termination rc.
Only the runner's dispatch-unit loop writes terminal pipeline status. On cycle
rc∈{1,2,3} the runner continues to the next dispatch unit (typically `review`)
with `pipeline_status="in_progress"` preserved; the `cycle_iterations[<id>].status`
field retains its non-converged terminal value AND a new `_RUNNER_CYCLE_UNCONVERGED`
flag ensures the final pipeline status reflects the unconverged outcome (failed,
not complete). Review's ADR-019 fail-closed gate (#485) is the sole verdict-class
arbiter; the runner's status flag is independent.

On rc=4 (config_invalid), rc=5 (blocked, #528), rc=130 (aborted) the
runner halts immediately: `pipeline_status="interrupted"`, `pipeline.end
status=failed`, no further dispatch units run.

Additionally, when the cycle terminates rc∈{1,2,3} the runner sets
`stage_statuses[<until-stage>]=failed` (typically `test`) BEFORE dispatching
review, so review's `_review_derive_test_status` sees an unambiguous failure
signal and the ADR-019 coercion path fires deterministically. A new event
`cycle.unconverged cycle_id=<id> iter=<N> reason=<max_iterations|plateau|divergence>`
is emitted alongside the existing `cycle.complete`.

## Amendment — Blocked termination class (#528)

A new termination class `blocked` distinguishes "stage could not produce
signal" (verdict=error/corrupt_diff/block) from "stage ran and didn't
converge" (verdict=fail). Per ADR-019 plugin verdicts table.

**Predicate:** `_cycle_detect_blocked` fires when ANY stage in `cycle.stages[]`
this iter has raw verdict ∈ {error, corrupt_diff, block}. Read from
`_CYCLE_LAST_VERDICTS_BLOB` (resume-safe). Does NOT fire on missing verdict
(handled by `verdict_missing`), on `fail` (keep iterating), or on
`scope_violation` (actionable).

**Priority (revised):** until > max_iterations > plateau > divergence > blocked > signal.

Blocked is LAST so legitimate convergence + plateau/divergence detection
still fire when applicable. Blocked is bypassed when `until.value == "error"`
(operator template explicitly converging on error).

**Return code 5 allocation:** rc=5 halts the pipeline (review does NOT run on
blocked). Runner halt set: `{4, 5, 130}`. Rationale: upstream input is
structurally broken; running review on `verdict=error` produces noise + burns
tokens.

**Reason enum extension:** `cycle.complete reason ∈ {converged, plateau,
max_iterations, divergence, blocked, verdict_missing, aborted, error}`.

**Event:** `cycle.blocked cycle_id=X iter=N stage=Y verdict=Z feedback_missing=bool`
emitted between `cycle.iteration.complete` and `cycle.complete reason=blocked`.

**State enum extension:** `cycle_iterations[X].status ∈ {..., blocked}`.

**Fail-CLOSED handling:** jq parse failure on verdicts blob → emit
`cycle.metric.invalid metric=blocked_eval reason=jq_failed`, treat as
terminate-now (mirrors `_cycle_check_max_iterations` non-numeric handling).
Empty `_CYCLE_LAST_VERDICTS_BLOB={}` → emit `cycle.metric.invalid
metric=verdicts_blob_empty`, also fail-CLOSED.

## Amendment — `test_assessment` as `until:` source (#572, ADR-022)

The canonical `build_test_cycle` `until:` predicate (see #511 amendment
above) is amended to read `test_assessment.verdict` when the assessment
stage (ADR-022) is in the cycle's `stages[]`. The canonical wiring becomes:

```yaml
cycles:
  - id: build_test_cycle
    stages: [build, test, test_assessment]
    until: { stage: test_assessment, field: verdict, op: eq, value: pass }
    max_iterations: 3
    on_max: continue
    feedback:
      - from: { stage: test_assessment, output: failure_summary }
        to:   { stage: build, input: prior_test_failures, required: false }
```

**Rationale.** The test plugin's `verdict=pass|fail|error` is *structural*
(exit code + parsed counts). Convergence requires *semantic*
interpretation: did the new test failures regress prior work, are the
remaining failures flaky, is the change actually green? `test_assessment`
provides that signal. Folding it into the test plugin would violate
ADR-018's "Deterministic operations stay bash" clause and conflate two
concerns (see ADR-022 §Alternatives).

**Verdict invariant.** `test_assessment.verdict == pass` REQUIRES BOTH
`test.failed == 0` AND `agrees_with_build_complete == true` AND
`build.verdict == pass`. The assessment cannot upgrade a structural
failure into convergence; it can only down-classify a structural pass
into `fail` or `inconclusive` when semantic interpretation contradicts
the raw counts.

**Per-iter artifact cleanup.** The cleanup contract (#511 Pin 8) extends
to `test-assessment.json`: each cycle iteration deletes the file before
dispatching the iteration, preventing stale prior-iter assessments from
silently satisfying `until: verdict==pass`.

**Blocked termination.** The blocked predicate (#528 amendment above)
treats `test_assessment.verdict ∈ {error}` as blocked identically to
other stages. `inconclusive` is NOT blocked (the LLM is uncertain, not
broken) — the cycle keeps iterating until convergence or another
termination class fires.

**Feedback source.** Feedback now flows from
`test_assessment.failure_summary_md` (human-readable markdown) into
build's `prior_test_failures` input via `source: cycle_feedback`, giving
build a higher-signal preamble than the test plugin's raw counts. The
empty-feedback omission rule (#511 Pin 5) is unchanged: an empty
`failure_summary_md` produces no preamble.

**Backward compatibility.** Templates that omit `test_assessment` from
the cycle's `stages[]` keep `until: { stage: test, field: verdict }` and
the F2 wiring is unchanged. The amendment is opt-in via the stage list.
