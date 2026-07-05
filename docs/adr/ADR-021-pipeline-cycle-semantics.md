# ADR-021: Pipeline Cycle Semantics (Outer-Cycle Framework)

**Status:** Proposed (F1) → Accepted (after F2 / #511)
**Date:** 2026-05-30
**Amends:** ADR-006 (resume contract), ADR-013 (canonical stage list), ADR-015 (stage-io v6), ADR-018 (Pattern 2 inner loops), ADR-020 (contract validator)
**Amended by:** ADR-042 — cycle members now resolve their plugin role-then-id via the shared `resolve_stage_plugin` helper, not id-only.
**Amended by:** ADR-045 (#1217) — the terminal-rc table gains `11 = route_back`, a NON-halt **CONTINUE-with-bounded-REWIND** class (deliberately absent from the runner halt-case). The orchestrator reclassifies only a *correctable* terminal (`term_rc ∈ {2, 8}`) into rc=11 when a `route_back` predicate matches, stashing the by-severity fallback rc + target; the runner then rewinds the dispatch index to a strictly-earlier unit (bounded by a global budget, default 2 total passes) or, on budget exhaustion, restores the fallback rc and falls through to the normal by-severity handling.

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

### Phase 1 — cycle convergence aggregator is preflight-enforced (issue #1177)

A cycle whose `exit_when.stage` resolves to a convergence-marked stage must bind to a cycle MEMBER
declaring `convergence: gate` (the gate aggregator, e.g. `gate-aggregator`). An advisory target, or a
target that is not a member of the cycle, fails preflight LOUDLY in
`core/pipeline/contract-validator.sh` (mirrored in `scripts/lib/lint-contract.sh`). Cycles whose
`exit_when` target carries NO convergence marker are legacy/untyped (standard.yaml's
`test_assessment`/`impact`/`review` convergence) and are intentionally NOT retro-checked — preserving
existing semantics while making the new typed contract fail-closed. See ADR-040 §Phase 1.

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
      - from: { stage: test_assessment, output: test_assessment_md }
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

**simple.yaml uses `objective-gate` as its `until:` source (I10-C).** In
`simple.yaml`'s `build_test_cycle`, `test_assessment` is absent from the
cycle entirely. Convergence is driven by `objective-gate.verdict == pass`
(mechanical tool-stage verdict, no LLM interpretation required). The
`test_assessment`-as-`until:` source pattern described in this amendment
applies to `standard.yaml` only. If `test_assessment` is ever wired as an
advisory stage in `simple.yaml`, `ZBUILD_TEST_ASSESSMENT_ADVISORY=1` must
be set so the pass-invariant coercion is suppressed (ADR-022 Amendment v6).

---

## Amendment §"Cycle declaration syntax v2" (#585)

**Decision.** The legacy two-block template shape (top-level `stages:` flat
list + sibling `cycles:` overlay) is retired. v2 inlines cycles as `stages:`
entries in execution order; per-stage attributes for cycle members are
hoisted into a new top-level `stage_definitions:` map.

**v1 (retired)**:
```yaml
stages:
  - id: intake
  - id: plan
  - id: build
  - id: test
  - id: review
cycles:
  - id: build_test
    stages: [build, test]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 3
```

**v2**:
```yaml
stages:
  - id: intake
    roles: [intake]
  - id: plan
    roles: [planner]
  - id: build_test
    type: cycle
    stages: [build, test]
    until:
      stage: test
      field: verdict
      op: eq
      value: pass
    max_iterations: 3
  - id: review
    roles: [reviewer]

stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
```

**Rationale.** Top-down readability: the cycle appears in execution order,
not in a separate block the reader must mentally splice in. Cycle id and
member-stage attrs are clearly separated into distinct namespaces; the
canonical-stages allow-list applies only to the flat expanded `_TPL_STAGES[]`
(canonical ids), while cycle ids live in `_TPL_CYCLES[]` (free namespace).

**Hard-break.** The parser refuses templates with a top-level `cycles:`
block and points the operator at `scripts/migrate-template-v2.sh`. Dual-
syntax tolerance was rejected: the AWK parser cannot disambiguate cleanly
and the migration is mechanical for the small set of in-tree fixtures + any
user template. Hard-break also avoids silent precedence bugs.

**Invariants preserved.** The downstream contract (`_TPL_STAGES[]` =
canonical-ordered flat list; `_TPL_DISPATCH_UNITS[]` = `stage:<id>` /
`cycle:<cid>` tokens; per-stage `_TPL_STAGE_*_<safe>` vars) is identical
to v1, so the runner, cycle-orchestrator, contract validator, and plugin
manifests required ZERO code changes. The parser refactor is local.

**Migration.** `scripts/migrate-template-v2.sh <file> [--in-place]` performs
a mechanical YAML transform: hoists cycle member stage definitions into
`stage_definitions:`, replaces them in `stages:` with one inline
`type: cycle` entry, and drops the `cycles:` block. The script is
idempotent (a v2 file with no `cycles:` block is emitted verbatim).

**Validation rule changes.**
- Legacy "contiguous-subsequence in flat stages" check no longer applies
  (v2 has no flat list to be a subsequence of). Cycle membership is now
  defined by the inline `stages:` list directly.
- New rule: every cycle member id MUST have a `stage_definitions:` entry,
  or `load_template` fails with `cycle 'X' references stage 'Y' but no
  'stage_definitions.Y' entry exists`.
- Existing rules unchanged: `max_iterations 1..10` REQUIRED;
  `until.stage` MUST be in cycle's `stages[]`; cycle ids do NOT collide
  with canonical stage names (a cycle id named `build` would be ambiguous
  with the `build` member, but no template ships that way and the
  collision is structurally rejected by the missing-stage-def check).

## Amendment — Per-iteration commit contract (issue #608, 2026-05-31)

A cycle that hopes to converge requires per-iteration commits. Without
them, `test_assessment` reads `git diff --numstat HEAD` against a stale
HEAD (the cycle's pre-build seed) and reports 0 files changed even when
the LLM did real work — and the cycle's `until:` predicate never fires
positively.

The amendment pins:

1. **Commit happens INSIDE the build stage** — not a new stage, not a
   coordinator concern. Build owns the loop; build owns the commit.
2. **Commit happens OUTSIDE the LLM** — the pipeline invokes
   `git commit`. The LLM is forbidden from running `git commit` per the
   prompt's `### Rules` section.
3. **Commit author** is `zbuild-pipeline <pipeline@local>` so test runs
   and downstream stages can distinguish pipeline-authored commits from
   the operator's seed commits via `git log --author`.
4. **`--no-verify`** is used: pre-commit hooks in the target repo MUST
   NOT block the pipeline mid-cycle. The review stage (T2 reviewer) is
   the canonical quality gate; the build commit is provisional.
5. **Guards**: when `verdict=scope_violation` OR the staged diff is
   empty after `git add -- <plan_files>`, the pipeline emits
   `build.commit.skipped reason=<scope_violation|empty_diff>` and does
   NOT create a commit. This preserves the invariant that pipeline
   commits correspond 1:1 to a successful in-scope iteration.
6. **Observability**: `build.commit.created sha=<sha> msg="<msg>"
   iter=<N>` lands in `events.jsonl` for every successful per-iter
   commit. The cycle orchestrator reads these events to populate
   `cycle.iter.N.commit_sha` in its state record.

Cumulative effect across a multi-iter cycle: HEAD advances by exactly
one commit per successful build iteration. `test_assessment` running
on iter N sees the iter (N-1) commit on HEAD and `git diff --numstat`
against the cycle's seed reflects the cumulative work.

---

## Amendment v3 (2026-06-11) — pipeline-status aggregation, rc propagation, pre-LLM gate prohibition

### Background

The #754 dogfood (`run_id 20260611072619-15296`) surfaced three contract gaps:

1. `plan_impact_cycle` exhausted `max_iterations=3` with `on_max=continue`; the pipeline correctly fell forward through `build_review_cycle` (build converged, review approved, 332/332 tests pass) — but the final pipeline status reported `✗ Pipeline failed — cycle 'plan_impact_cycle' did not converge`. The aggregator treats ANY cycle `unconverged` as terminal even when `on_max=continue` was specifically designed to defer the decision downstream.

2. `claude max_turns reached` (`rc=124` from `gtimeout`) was translated to `rc=1` by the router before the agent plugin's classify helper saw it. PR #788's `_router_rc_classify` maps rc=124 → verdict=error correctly, but the upstream translation defeats it.

3. PR #789 (subsequently reverted via #791) added a pre-LLM scope-mismatch gate in build that bypassed the entire feedback contract — build iter 2 never received `prior_test_assessment` because the gate short-circuited before `route_to_model_loop`.

### Rules

**R1. `on_max` MUST be honored at the pipeline-status aggregator.**

- `on_max: continue` MUST NOT propagate to pipeline-terminal failure. The cycle records `cycle.unconverged` as an event for forensics; the pipeline final status is computed from the FINAL stage that ran.
- `on_max: abort` exhaustion DOES propagate. The cycle records `cycle.aborted` and the pipeline final status is `failed`.
- Pipeline aggregator logic: walk the dispatch units in order; if the LAST unit produced `verdict=pass|approve`, pipeline succeeds. If a `cycle.unconverged` event has `on_max=continue`, treat as a warning, NOT a failure.

**R2. Router rc propagation: rc=124 and rc=137 MUST reach the agent plugin verbatim.**

- `route_to_model` (and any `route_to_model_loop` shim) MUST NOT translate rc=124 (gtimeout) or rc=137 (SIGKILL/OOM) to rc=1.
- Each agent plugin runs `_router_rc_classify` on the returned rc; the classify helper maps to (verdict, reason).
- Generic rc>0 (claude-emitted error) still maps to verdict=fail; rc=124/137 are reserved for infra failures.

**R2 amendment (#1237): rate/session-limit disposition.** The claude CLI reports a rate/session limit as **rc=1** with a MISLEADING `subtype:"success"` envelope carrying `is_error:true` + `api_error_status ∈ {429,529}` (or a `result`/`error` naming a session/rate/usage/quota limit or "overloaded"). Because the rc is 1, this stays `rc=1` on the wire — deliberately NOT a new rc — so the ~4 stages that treat `rc=1` as recoverable (impact, review lenses, security-lens, plan) remain NON-blocking, and it is NOT auto-retried (the router's timeout retry loop is `rc=124`-only; a rate-limit resets at a future time, so an immediate retry re-hits it). The router (`_route_call_claude`) detects the signal via `_router_is_rate_limit`, prints an honest `LLM rate-limited — resets X` line (replacing the opaque `claude CLI failed (rc=1)`), and emits a distinct `router.rate_limited` event plus `router.error reason=router_rate_limited`. `_router_rc_classify <rc> <v> <r> 1` maps the rate-limited flag → `verdict=fail reason=router_rate_limited` (verdict stays `fail`/recoverable, NOT the infra `error` class that halts a cycle).

**R3. Pre-LLM gates in cycle members are forbidden.**

- "Pre-LLM gate" = any code path inside a cycle member's `_*_run_inner` that short-circuits before `route_to_model` returns, AND skips the LLM call because of cycle-feedback state.
- Enforcement: cycle members MUST run the LLM with the current iter's feedback context. The LLM either attempts an in-scope solution OR emits its sentinel with a diagnostic.
- Post-LLM diagnostics are fine and encouraged: enrich `build-summary.json` / `impact.json` with reason codes after the LLM call. They signal without bypassing the cycle's iteration contract.
- The per-edit scope guard (file-write refusal at the Edit tool layer) is the correct enforcement layer for scope safety. It runs WHILE the LLM is in the loop, not before.

**Rationale:** the cycle's purpose IS to give the LLM iterated feedback. Pre-LLM gates that read prior_test_assessment/prior_impact_feedback and decide "skip the LLM this round" defeat the entire reason cycles exist.

### Affected components

- `core/pipeline/runner.sh` (pipeline aggregator) — R1
- `core/router/route.sh` (rc preservation) — R2
- All cycle member plugins (`plan`, `impact`, `build`, `test_assessment`, `review`) — R3
- `scripts/lib/lint-contract.sh` — should add a static check that no cycle member plugin shortcuts to `return 0` before `route_to_model` based on cycle-feedback state (heuristic: `_*_run_inner` body must contain `route_to_model` between any `prior_*_feedback` read and the first non-zero `return`).

### Verification

- New test `tests/unit/cycle-on-max-continue-pipeline-status-test.sh`: drive a cycle to exhaustion with `on_max=continue`, assert pipeline final status is success when downstream succeeds.
- Extend `core/router/route.sh` tests with rc=124 preservation; assert the rc returned to caller is 124, not 1.
- Lint rule + test for R3 enforcement.

### Cites

- Dogfood `run_id 20260611072619-15296` (the misleading "Pipeline failed" on a substantively successful run)
- PR #788 (`_router_rc_classify`) defeated by upstream rc translation
- PR #789 (broken pre-LLM gate) reverted via PR #791

---

## Amendment v4 (2026-06-14, #842) — design_impact_cycle replaces plan_impact_cycle

### Background

The `plan_impact_cycle` (plan→impact, up to 5 iter) was introduced in Wave 19-J (#744) to verify that plan's `steps[].files[]` was scope-complete. Dogfood experience showed two structural problems:

1. **Impact was symbol-grepping a prediction.** plan.json's `files[]` was produced *before any design search*, so impact traced dependencies from a list that hadn't yet been validated against the actual repo topology. Gaps were found because plan missed files, not because design found them.
2. **plan re-plans on impact feedback.** On `incomplete`, the cycle re-ran plan — a costly LLM re-plan whose principal task (scope discovery) should belong to design (which actively Greps the repo).

### Decision

Replace `plan_impact_cycle` with `design_impact_cycle`:

- **plan** becomes a **leaf** (no cycle). It produces `plan.json` as before; it no longer receives cycle feedback. The re-plan-on-impact regression (#773) is eliminated.
- **design_impact_cycle** (design→impact, 3 iter, `on_max=continue`) is the successor. design runs *first*, exhaustively enumerating scope via Read/Grep/Glob (ADR-841). impact then adversarially finds post-design consequences design missed. On `incomplete`, the cycle re-runs design with:
  - `prior_impact_feedback` (impact's gap report → `design.prior_impact_feedback`)
  - `prior_design` (design self-feedback edge, mirrors #773 lesson: design iter N+1 refines rather than re-creates)

### Impact on cycle semantics

The `on_max=continue` dogfood example from v3 (line 565) cited `plan_impact_cycle`; the same pattern now applies to `design_impact_cycle`. The `_runner_cycle_unconverged` flag semantics are identical.

The cycle-id in state records, events.jsonl, and `_TPL_CYCLE_FEEDBACK_*` variable names changes from `plan_impact_cycle` to `design_impact_cycle`. No orchestrator code change is required; only the template and plugin wiring changes.

### Affected components

- `config/templates/standard.yaml` — topology change (plan leaf, design_impact_cycle)
- `plugins/agent/plan/manifest.yaml`, `plugin.sh` — remove cycle_feedback inputs
- `plugins/agent/design/manifest.yaml`, `plugin.sh` — add cycle_feedback inputs + prompt splice
- `plugins/agent/impact/manifest.yaml`, `plugin.sh` — primary input changes from plan.json to design.md
- Test files pinning `plan_impact_cycle` — updated to `design_impact_cycle`

## Amendment v5 (2026-06-15, #895) — no-op convergence (empty_diff + green)

A cycle member may legitimately produce "no change needed" — e.g. the
`build_test_cycle` build stage emits `build.verdict=empty_diff` (done_sentinel,
0 files changed) when the work is already implemented. When all downstream
signals are green (tests pass, the assessment LLM agrees), this is a
**convergence outcome, not a failure**: the cycle's `until:` predicate MUST be
allowed to fire. Treating a no-op build as "not done" makes the cycle re-iterate
on an already-complete branch and livelock to `max_iterations`
(dogfood `run_id 20260615100734-32729`, re-dogfood of #846).

Convergence vs. stall is decided by the downstream signal, not by the presence
of a diff: **no-change + green = converge; no-change + red = re-iterate.** The
gate that enforces this for `build_test_cycle` is the test_assessment verdict
invariant (ADR-022 Amendment v4).

## Amendment — Flat-velocity plateau termination (#845)

The existing `plateau` detector (`_cycle_detect_plateau`) fires only on a
**verdict+status+failure_count tuple identical** for N iters; `divergence` fires
only when `failure_count` **strictly increases**. Neither catches a cycle that
makes no forward progress while still varying — `failure_count` flat or
oscillating without strictly rising (e.g. 11→11→11 or 5→6→5). The motivating
dogfood (`20260612173055-58001`) burned the full `max_iterations` on
`failure_count=11` identical across all three iters because the tuple detector
fires only AFTER `max_iterations` and divergence saw no strict increase.

**Predicate:** `_cycle_detect_velocity_plateau <history_file> <window>` examines
the last `window` history rows and fires when **no consecutive pair shows a
strict decrease** — i.e. every one of the `window - 1` deltas among those rows
is ≤ 0 (`failure_count[i] >= failure_count[i-1]`, no improvement). So `window`
is a count of iterations, not of pairs: `window: 2` inspects 2 rows / 1 delta.
It reuses the existing exit surface: `rc=2`, `reason=plateau`, `cycle.plateau`
event — distinguished from the tuple path by `evidence=velocity_flat` (vs
`verdict_tuple_identical`), set via the
`_CYCLE_PLATEAU_TYPE`/`_CYCLE_LAST_PLATEAU_EVIDENCE` global. The `cycle.plateau`
event's `streak` field reports the window of whichever detector fired (the
velocity window when `evidence=velocity_flat`, the tuple window otherwise).

**Template key (opt-in).** `velocity_plateau: { window: K }` as a sibling of the
existing `plateau:`/`divergence:` blocks. Omitted or non-numeric → disabled
(`_CYCLE_VELOCITY_PLATEAU_WINDOW=0`); unlike tuple-plateau there is no active
default, so cycles that don't declare it are unaffected. `window < 2` →
`cycle.metric.invalid`, treated as disabled.

**Position in the chain — BEFORE `max_iterations`.** This is the key difference
from tuple-plateau: a flat cycle must abandon *early* to save iterations, not at
the ceiling. So velocity-plateau is evaluated before the `max_iterations` check.

**Priority (revised):**
`until > cycle_abort > blocked_on_scope > velocity_plateau > max_iterations > plateau (tuple) > divergence > blocked > signal`.

**Skip logic (mirrors tuple-plateau):** emit `cycle.plateau.skipped
reason=insufficient_history` and do not fire when `iter < 2` or history has fewer
than `window` rows.

**Live wiring (#845).** The production `build_test_cycle` in
`config/templates/standard.yaml` sets `velocity_plateau: { window: 2 }`. With
`max_iterations: 3`, a stuck cycle abandons after iter 2 (`reason=plateau`)
instead of running to iter 3 — `window=2 < max_iterations` is what actually saves
an iteration (window=3 would only relabel the ceiling exit). Without this live
wiring the detector is inert and the motivating dogfood is not fixed: the feature
must run in the dispatched flow, not merely exist behind an opt-in default.

## Amendment (#936, 2026-06-18) — over-scope-safe deterministic convergence for design_impact_cycle

`design_impact_cycle` exits only on `impact.verdict == complete`. When impact
re-flags real-but-irrelevant adjacent files (the changed file's reference
closure — a *different* existing file each iter), `missing[]` stays non-empty
with real paths, the #911 hallucination drop never flips the verdict, and the
cycle burns all `max_iterations` exiting via `on_max=continue` (not convergence).
There is no diff at impact time (the cycle runs before build), so a diff
cross-check is impossible.

**Asymmetric-risk principle.** Over-scoping is HARMLESS at this stage: the cycle
runs before build and build derives its write-scope from design.md's scope block,
so converging "early" on an over-scoped design costs nothing downstream.
UNDER-scoping is the dangerous direction, but it remains recoverable by three
mechanisms that this change preserves: (1) the deterministic #781/#881 prefilter
floor (shape/golden/order mandates), (2) ADR-030 scope-governance (build requests
collateral mid-cycle), and (3) build's full-suite test stage (a missed file
surfaces as a red test). Mechanisms (2)+(3) only cover the COLLATERAL classes
(`tests/`, `config/`, `docs/`) — a structural `core/`/`scripts/`/`plugins/`
omission is NOT recoverable.

**Decision.** `_impact_converge_on_overscope` (scripts/lib/impact-prefilter.sh,
called after the #911 drop) flips `incomplete→complete` ONLY when EVERY condition
holds: verdict=incomplete; NOT a detected shape-change; no floor entry
(`step_id==prefilter`); `ZBUILD_CYCLE_ITER>=2` AND the non-floor `missing[]` file
SET is identical to the prior verdict-producing iter (a TRUE plateau, tracked via
the per-run sidecar `impact-prior-missing.txt` written after the schema gate —
never on a #782/#892/#937 synthetic envelope); EVERY remaining file is
collateral-class; EVERY remaining file exists. It only flips the verdict, never
drops a file, and emits `impact.scope.plateau`. A structural cascade (the
motivating dogfood: `scripts/lib/*` files, a different one each iter) does NOT
satisfy these conditions and correctly terminates via `on_max=continue` — the
safe fallback. The PRIMARY reduction of over-scoping is a charter tightening in
`_impact_instructions` (referential adjacency = a real gap; lexical/directory
adjacency = not a gap), so impact stops chasing the reference closure at the
source.

## Amendment (#937, 2026-06-18) — router TIMEOUT is recoverable (best-effort), not a terminal error

ADR-021 v2 (#782) codified an `error` verdict class for infra-origin router
failures so the cycle blocked-predicate could distinguish them from recoverable
`fail`. In practice a router **timeout** (rc=124) wrote `verdict=error` with an
EMPTY `missing[]`/feedback — wasting the whole cycle iteration (observed eating
iter-1 of dogfood `20260617195045-6103`). #892 had already given the rc=1
(max_turns) case a best-effort `verdict=incomplete` so the cycle re-iterates with
signal; #937 extends that to the rc=124 timeout. A timeout is transient and
re-runnable, so impact now writes a best-effort `verdict=incomplete` with a
turn-aware note (and `reason=router_timeout` in BOTH the `plugin.run.error` event
and the impact.json artifact) instead of an empty error. Genuine infra failures
(OOM rc=137, claude crash) KEEP `verdict=error` — the error class still exists,
its boundary is just drawn at non-recoverable failures. The synthetic best-effort
envelope short-circuits before the schema gate, so it never reaches the #936
over-scope backstop and never writes its plateau sidecar (a timeout iter is not a
verdict-producing iter).

## Amendment (Phase 2, 2026-07-01) — generic member-disposition contract

The cycle engine previously HARDCODED one member's failure semantics: a helper
`_cycle_acceptance_terminal_failure` knew the literal stage name `acceptance-gate`,
the artifact filename `acceptance-gate-result.json`, and the acceptance-gate
failure-class vocabulary (which classes are terminal vs recoverable vs infra).
That coupling is removed. The engine now speaks a GENERIC member-result-envelope
contract:

> A cycle member MAY declare `disposition: terminal | recoverable | advisory` in
> its primary-output result artifact. When a member's artifact records
> `verdict: fail`, the cycle reads its `disposition`:
> - `terminal`  → HALT: the cycle does not converge (rc=8, pipeline.end=failed),
>   even if a downstream advisory stage (e.g. review) approved. The engine emits
>   `cycle.member.terminal_failure` carrying the failing `member` id.
> - `recoverable` → NON-terminal: the pipeline does not hard-fail; the cycle
>   re-iterates so the feedback edge can self-heal (the #951 acceptance→build
>   loop is now expressed this way).
> - `advisory` → NON-terminal and, in the gate-aggregator, non-blocking for
>   convergence (an infra flake must never block or halt).
> - ABSENT → NON-terminal (fail-safe): only an EXPLICIT `terminal` halts, so a
>   disposition-unaware plugin preserves the pre-Phase-2 behavior.

The generic helper `_cycle_member_terminal_failure` iterates THIS cycle's member
roster (`_CYCLE_STAGES` == `_TPL_CYCLE_STAGES_<id>`) and resolves each member's
result artifact via the SHARED roster mechanism (`manifest_graph_resolve_member`
/ `manifest_graph_result_filename` — the same primitives the gate-aggregator uses
under ADR-040 §2: id-match then role binding; `provides.artifact_type` then
primary-output basename). No plugin id, artifact filename, or failure-class string
survives in the engine. A plugin owns its own class→disposition mapping (for the
acceptance-gate, see ADR-036 Phase-2 amendment). This is orthogonal to the ADR-013
`blocking:true` mechanism, which stays an immediate, rc-only halt during member
dispatch (both surface as rc=8 → reason `blocking_member_failure` for blocking:true,
`member_terminal_failure` for the disposition path).

## Amendment — Timeouts never fatal; single fatal = exhaustion-without-convergence (issue #1208, 2026-07-03)

Lineage: a `--template simple` dogfood (#944) shipped `status=complete` while its
`build` stage had actually timed out — three per-turn timeouts made the router return
"fatal", the build stage swallowed it as `verdict=pass`, and the cycle converged on
iteration 1 on an incomplete tree. #1208 re-states the cycle's stop/converge model so a
timeout can never produce a false `complete`, and so the pipeline halts on exactly ONE
condition.

**Core model (engine-level, repo-agnostic — keys only on repo-neutral signals:
LOOP_COMPLETE-vs-timeout, roster-driven gate/test verdict, `failure_count`,
`max_iterations`; no runner/language/path/plugin hardcode):**

1. **A build-stage timeout is NEVER fatal — anywhere.** The router loop, on repeated
   per-turn timeout, ends the attempt and YIELDS to the cycle (`route.sh` returns 0,
   `_ROUTE_LOOP_TERMINATED_REASON=router_timeout`); no path kills the pipeline.
2. **The test stage is the verifier — the build never short-circuits the cycle.** After
   ANY build outcome (clean finish / stall / empty diff / timeout) the build falls out
   to the cycle, which ALWAYS runs the test stage to verify the real state.
3. **Convergence (ALL must hold, evaluated first each iter):** (a) gates green
   (gate-aggregator `verdict==pass`); (b) the build reached a **clean resting point** —
   `LOOP_COMPLETE`, or a legitimate empty-diff "nothing-to-do" stall — **not mid-flight**
   (a timeout/error = interrupted, verdict `did_not_finish`); (c) well-formed (no
   `scope_violation`/`corrupt_diff`). A mid-flight build cannot ratify convergence even
   if a stale/partial tree passes the gate — the orchestrator suppresses it and emits
   `cycle.build_unfinished.suppressed_convergence` (a second convergence-suppression
   instance alongside ADR-034's full-suite gate).
4. **Progress is NOT required to converge.** A re-run of a done issue (empty diff via
   `LOOP_COMPLETE` + gates green) converges on iteration 1. An empty diff counts against
   the run only when gates are red.
5. **The single fatal condition** is the cycle reaching `max_iterations` without ever
   converging. At exhaustion the outcome splits **by severity** using the generic test
   verdict + `failure_count`: tests failing (`test.verdict==fail` OR `failure_count>0`)
   → `term_rc=8` (runner `status=failed`, HALT — a nested inner cycle's rc=8 propagates
   as `blocking_member_failure`, so a failing build/test cycle is **never** rescued by an
   advisory review); tests passing-but-unconverged → `term_rc=2` (unconverged→review;
   `on_max` honored at the runner).

**Removed early terminators.** The velocity_plateau / plateau / divergence early
terminators and the #1117 empty-diff stall-break are REMOVED as *terminators* — the
cycle runs ALL its tries (each cheap: the build self-yields on an empty diff), and a
plateau signal only classifies the exhaustion outcome. The detector functions remain
defined (dormant, for potential reuse) but are no longer wired into the cascade.
`_cycle_detect_blocked` is retained for genuine structural failures (raw verdict
`error`/`corrupt_diff`/`block` — NOT a timeout, which iterates → rc=5 halt).

Supersedes the ADR-021 termination priority order (§Decision points) for the
build/test cycle: `converged → abort_when → scope-deny → max_iterations(by-severity) →
blocked`. See also ADR-029 (G2 abandon removed / G3 kept), ADR-013 (router-loop timeout
non-fatal), ADR-034 (second convergence-suppression instance), and ADR-044 (repo-
declarable test-count contract).

## Amendment (#945, 2026-07-05) — design stage router timeout is recoverable

`design_impact_cycle` ran with the same infra-timeout exposure as impact: when
`route_to_model_loop` returns rc=124 (gtimeout SIGTERM) inside
`_design_stage_run_inner`, the pre-#945 code emitted `plugin.run.error
reason=router_error` (a generic label) and returned rc=1 (terminal) — wasting the
entire iteration and leaving `design.md` absent, which caused impact to abort on
the missing artifact.

**Decision (mirrors #937 for impact).** rc=124 is now a recoverable disposition in
the design plugin:

1. `_router_rc_classify` (scripts/lib/router-rc-classify.sh) maps rc=124 →
   reason=router_timeout.
2. `plugin.run.error reason=router_timeout` is emitted for forensics (same as
   before, but with the correct classified reason instead of the generic
   `router_error`).
3. A best-effort stub `design.md` is written to the declared output path,
   containing the seed scope from `plan.json files[]` and a minimal acceptance
   block, so downstream artifact checks do not abort the cycle.
4. `design.timeout.stub_written` is emitted (registered in event-schema.json).
5. `_design_stage_run_inner` returns rc=0 so the `design_impact_cycle` loop
   records the iteration and re-dispatches design on the next turn.

**rc=137 (OOM-kill) and all other non-zero rcs remain terminal** (return rc=1)
with `plugin.run.error reason=<classified reason>`. The `error` verdict class
from #782 is unchanged; only the rc=124 boundary is re-drawn as recoverable.

**Router-retry exhaustion.** The design plugin exhausts `router.retries`
(configured in `config/models.json`) BEFORE rc=124 propagates to the plugin.
A timeout reaching `_design_stage_run_inner` is post-retry; the re-iterate path
fires at the cycle level, not at the router level.

**No new classification predicate.** `_router_rc_classify` from
`scripts/lib/router-rc-classify.sh` is the sole classifier — no parallel
predicate is introduced.
