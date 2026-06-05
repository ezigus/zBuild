# ADR-026: Review Remediation Cycle

**Status:** Proposed
**Date:** 2026-06-05
**Depends on:** ADR-019 (review fail-CLOSED on test failure), ADR-020 (inter-stage data contract), ADR-021 v2 (pipeline cycle semantics), ADR-027 (recursive flow template format)
**Implemented by:** #707 (Wave 18-B `review_cycle` wiring in `config/templates/standard.yaml` + build manifest `prior_review_feedback` input), #708 (Wave 18-C contract lint).

## Context

Multiple dogfood runs against #653 over Waves 16 and 17 surface the same
failure mode: the review stage produces an LLM verdict that names real,
actionable bugs in the diff (a missing nil-guard, a regressed test, a
contract violation against ADR-019) and the pipeline then terminates
without acting on the feedback. The reviewer's words land in
`review.review_md` and stop there; the only path forward is manual
operator intervention (re-queue the issue, re-run the pipeline, hope the
build LLM stumbles into the same fix).

Shipwright legacy had this loop. The function
`_write_merge_retry_ctx_review` at
`legacy/scripts/lib/pipeline-stages-delivery.sh:676-687` wrote a
`.retry-context-build.md` file when PR review requested changes; the
build stage on the next pipeline pass read that file and prepended it to
its prompt, giving the next build iteration the reviewer's complaints as
context. The mechanism was implicit (file-based, not visible in the
template) but functionally it closed the loop: review feedback drove a
build retry. zbuild lost this when the delivery stages were re-modelled
as plugins.

Two prior architectural moves now make rebuilding this loop a wiring
exercise rather than a new mechanism:

- **ADR-021 v2** introduced the cycle framework with structured
  `until:`/`exit_when:` predicates, `max_iterations:` caps, `on_max:`
  behavior, and `feedback:` edges through ADR-020's inter-stage data
  contract (`source: cycle_feedback`). Wave 17-B (ADR-027 + #703) extends
  the framework with `abort_when:` as a sibling predicate that
  propagates outward and terminates the pipeline (rc=5, cycle_abort
  class from ADR-025).
- **ADR-027** (Wave 17-A) reshapes the template format so cycles ARE
  stages and nest recursively. An outer cycle wrapping `build_test_cycle`
  is declaratively trivial under the recursive `flow:` shape: the outer
  cycle's `flow:` references the inner cycle's ID alongside `review`,
  and member stages live at the top level alongside everything else.

With both pieces in place, the review-remediation loop reduces to wiring
`review.review_md → build.prior_review_feedback` via an outer cycle that
wraps `build_test_cycle` plus `review`. No new orchestrator code, no new
template keyword, no new event types beyond what Wave 17-B already
registers for `abort_when`. ADR-026 codifies the wiring and the
review-feedback semantic.

## Decision

ADR-026 codifies the **review remediation cycle**: an outer cycle that
turns the review stage's verdict into a feedback signal driving build
retry.

1. **Outer cycle shape.** The remediation cycle wraps two members in its
   `flow:`: the inner `build_test_cycle` (ADR-021 v2 + ADR-027), and
   `review`. The cycle's `exit_when:` fires when
   `review.verdict == approve` — convergence on a green review.
2. **Abort path.** The cycle's `abort_when:` fires when
   `review.verdict == block`. `block` is review's hardest verdict
   (ADR-019); it means the diff is structurally broken in a way
   remediation cannot recover (corrupt diff, scope violation,
   never-build-this category). `abort_when` propagates outward and
   terminates the pipeline with rc=5 (cycle_abort class, ADR-025) —
   downstream stages do not run.
3. **`max_iterations` safety cap.** The outer cycle declares
   `max_iterations: 2` in `standard.yaml` (default; configurable per
   template). The cap is independent of the inner `build_test_cycle`'s
   `max_iterations: 3` — worst case the outer cycle invokes the inner
   cycle twice, each up to three iterations, before the cap fires.
4. **`on_max: continue` (default).** When the outer cycle exhausts its
   cap without converging, the pipeline proceeds to whatever sibling
   follows the outer cycle in the top-level `flow:` with the latest
   review state preserved. This matches today's ADR-019 fall-through to
   the operator: an unconverged review still records its verdict, and
   the pipeline's final status reflects the unconverged outcome
   (ADR-021 v2 #527/#528 amendment — `_RUNNER_CYCLE_UNCONVERGED` is
   set, `pipeline_status` is not silently `complete`). Templates that
   want hard termination on `max_iterations` instead declare
   `on_max: abort_pipeline` and the runner exits rc=5.
5. **Feedback wiring.** The `feedback:` block declares one edge:
   `from: { stage: review, output: review_md }` → `to: { stage: build,
   input: prior_review_feedback, required: false }`. Build's
   `manifest.yaml` adds `prior_review_feedback` to its `inputs:` with
   `source: cycle_feedback` — the same shape as the existing
   `prior_test_failures` / `prior_test_assessment` inputs (ADR-020
   amendment for cycle feedback; ADR-021 v2 #511 consumer-side
   declaration requirement).
6. **Plan is one-shot at the top level.** The remediation cycle does
   NOT wrap `plan`. Each remediation iteration re-runs build, test,
   test_assessment, and review with the new feedback context; `plan`
   ran once at the top of the pipeline and stays committed. Re-running
   plan on review feedback is a deferred decision (see Alternative
   (c)).
7. **Build prompt integration.** Build's `plugin.sh` checks for the
   `prior_review_feedback` artifact at the cycle-feedback path
   (`ZBUILD_CYCLE_FEEDBACK_DIR`, ADR-021 v2 #511 file-path feedback
   contract) and, when present and non-empty (`[[ -s file ]]` per
   ADR-021 v2 #511 Pin 5), prepends a `## Prior review feedback`
   section to the LLM prompt. Empty file → preamble omitted entirely
   (never silent emit). The integration mirrors the existing
   `_build_read_prior_failures` helper for `prior_test_failures`.

## Boundary

What stays the same:

- **Review's verdict semantic (ADR-019).** Review still emits
  `approve | request_changes | block`, still post-validates against
  test_status, still fail-CLOSED coerces approve→request_changes when
  `test_status ∈ {unknown, failed}`. ADR-026 adds a fourth informational
  behavior on top of the existing three-verdict contract: when review's
  verdict is `request_changes`, its `review_md` flows as feedback into
  the next build iteration via the outer cycle's `feedback:` edge.
  Approve still ends the cycle; block still aborts; `request_changes`
  still records the verdict — it just no longer dead-ends.
- **Cycle orchestrator.** The orchestrator already handles `exit_when`,
  `abort_when`, `max_iterations`, `on_max`, and `feedback:` after Wave
  17-B (#703). ADR-026 reuses the mechanism unchanged — there is no new
  orchestrator code, no new event type, no new state field. The outer
  cycle is a regular cycle stage that happens to contain another cycle
  stage in its `flow:`.
- **Inner `build_test_cycle`.** Unchanged. Its `exit_when` still reads
  `test_assessment.verdict == pass` (ADR-021 v2 #572 amendment), its
  `feedback:` still wires `test_assessment.test_assessment_md →
  build.prior_test_assessment`, its `max_iterations` and per-iter
  commit contract (ADR-021 v2 #608 amendment) are untouched.
- **Plugin contract (ADR-020).** Feedback edges still flow through
  manifest-declared `inputs[].source: cycle_feedback`. The contract
  validator (`CYCLE_FB_UNWIRED` / `CYCLE_FB_UNDECLARED` from ADR-021 v2
  #511) catches drift on the new edge identically to existing edges.

What changes:

- **`config/templates/standard.yaml`** gains an outer `review_cycle`
  stage section under the ADR-027 recursive `flow:` shape. The
  top-level `flow:` becomes `[intake, plan, review_cycle]`;
  `build_test_cycle` and `review` move from top-level siblings into
  `review_cycle.flow:`. Wave 18-B (#707) owns this migration.
- **`plugins/tool/build/manifest.yaml`** gains a `prior_review_feedback`
  entry in `inputs:` with `source: cycle_feedback, required: false`.
- **`plugins/tool/build/plugin.sh`** gains a check for the feedback
  artifact and prepends a `## Prior review feedback` section to the
  LLM prompt when the file is present and non-empty. Mirrors
  `_build_read_prior_failures` (ADR-021 v2 #511 Pin 5).
- **Contract lint** (Wave 18-C, #708) enforces ADR-027 invariants
  including that the new `review_cycle` section is well-formed under
  the recursive `flow:` shape (reserved key set, flow ID resolution,
  cycle membership acyclicity).

## Example wire

The `review_cycle` section in `config/templates/standard.yaml` under
the ADR-027 shape:

```yaml
review_cycle:
  type: cycle
  flow:
    - build_test_cycle
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: approve
  abort_when:
    stage: review
    field: verdict
    op: eq
    value: block
  max_iterations: 2
  on_max: continue
  feedback:
    - from:
        stage: review
        output: review_md
      to:
        stage: build
        input: prior_review_feedback
        required: false
```

The top-level `flow:` becomes:

```yaml
flow:
  - intake
  - plan
  - review_cycle
```

`build_test_cycle`, `build`, `test`, `test_assessment`, and `review`
remain top-level stage sections (per ADR-027's recursive `flow:` shape
— cycle members live at the top level alongside everything else and
are referenced by ID from inside a cycle's `flow:`).

## Alternatives considered

- **(a) `remediation_loop:` keyword on the review stage.** Add a
  per-stage `remediation_loop:` block on the `review` section naming a
  feedback edge back to `build`. Rejected (matches ADR-027 Alternative
  (a)): introduces vocabulary that duplicates cycle mechanics, only
  solves the single-stage-retry shape, does not generalize to
  multi-stage review-plus-test remediation, and mixes flow control
  with stage attrs at the same scope. The cycle framework already
  solves the general case; review-remediation is one specific wiring
  of it.

- **(b) File-based retry-context (shipwright legacy pattern).**
  Preserve the `.retry-context-build.md` shape: a hidden file under
  the state directory that the build plugin reads on subsequent
  pipeline invocations. Rejected: the mechanism is implicit — nothing
  in the template surfaces the loop, operators reading the template
  cannot tell that review feedback drives a retry, and resume
  semantics (ADR-006) become muddled because the file lives outside
  the cycle's `state/cycle-<id>/iter-<N>/feedback/` directory.
  ADR-021 v2's `feedback:` block is the explicit, declarative
  equivalent that lives inside the cycle vocabulary and the runner's
  resume contract.

- **(c) Plan in the remediation cycle.** Wrap `plan` alongside
  `build_test_cycle` and `review` in `review_cycle.flow:` so a
  `request_changes` review re-runs planning with the review feedback
  in hand, producing a new `plan.json` that drives subsequent build
  iterations. Rejected for now: plan is the most expensive
  LLM-invoked stage in the pipeline (token spend, router T3+ tier),
  re-running it on every remediation iter blows the budget; review
  feedback is typically actionable directly against the diff (build's
  concern) without needing a new plan; and a re-running plan means
  `plan.json` mutates mid-pipeline, which breaks ADR-020's
  upstream-stable assumption for downstream consumers. If a future
  failure class shows review feedback that plan must consume (e.g.,
  reviewer says "this whole approach is wrong, replan"), a follow-up
  ADR can extend the remediation cycle to wrap plan with a separate
  feedback edge.

## Consequences

**Easier:**

- zbuild can self-correct when review surfaces actionable bugs. Failed
  runs that should iterate now do, automatically, up to the
  `max_iterations` cap. This reduces manual operator intervention on
  the failure class that today requires re-queueing the issue.
- Aligns with shipwright's autonomous-pipeline model: review feedback
  is a first-class control signal, not a dead-letter output.
- The remediation loop is visible in the template. An operator reading
  `standard.yaml` sees `review_cycle` in the top-level `flow:` and can
  trace exactly which stages iterate under which conditions. No hidden
  file-based magic.

**Harder:**

- Pipeline duration on remediation paths is longer. Worst case under
  default caps: outer cycle 2 iterations × inner cycle 3 iterations =
  6 build invocations + 6 test invocations + 6 test_assessment
  invocations + 2 review invocations before the pipeline gives up.
  Operators need to understand that outer × inner caps multiply.
- The cycle banner output gains a new layer of indentation (outer
  cycle iter N/2 → inner cycle iter M/3 → stage). ADR-021 v2's
  operator-visibility amendment (#524, #526) already supports nested
  cycle chrome via the `cycle_iter_*` hook functions; the new outer
  cycle uses the same mechanism. No new banner code, but the rendered
  output has more depth.
- Token spend per remediation iter rises by the build prompt's
  `## Prior review feedback` preamble. The preamble is bounded by
  `review_md` size (typically a few hundred tokens, reviewers are
  concise); the omission rule (empty file → no preamble) prevents
  silent noise.

## Status flip

ADR-026 ships in **Proposed** status. The status flips from Proposed
to **Accepted** when Wave 18-B (#707) merges the `review_cycle`
template wiring + build manifest `prior_review_feedback` input + build
plugin prompt integration. This matches the ADR-then-impl precedent
set by ADR-024 (flipped on #673) and ADR-027 (flips on #703). No code,
no test, no event-schema changes in this PR. Only the ADR text.

## References

- [ADR-019](ADR-019-review-fail-closed-on-test-failure.md) — review
  fail-CLOSED contract; extended by ADR-026 from "final arbiter" to
  "feedback source for remediation" without changing the verdict
  semantic.
- [ADR-020](ADR-020-inter-stage-data-contract.md) — inter-stage data
  contract; the new `prior_review_feedback` input uses
  `source: cycle_feedback` identically to existing cycle-feedback
  inputs.
- [ADR-021 v2](ADR-021-pipeline-cycle-semantics.md) — pipeline cycle
  semantics; ADR-026 is a wiring of this framework, not an extension.
  `exit_when`, `abort_when`, `max_iterations`, `on_max`, `feedback:`,
  and `source: cycle_feedback` are all reused unchanged.
- [ADR-025](ADR-025-abort-propagation.md) — abort propagation; the
  `abort_when: block` path uses rc=5 cycle_abort class from this ADR.
- [ADR-027](ADR-027-recursive-flow-template-format.md) — recursive
  flow template format; ADR-026's `review_cycle` declaration uses
  ADR-027's `type: cycle` shape with member stages at the top level.
- `legacy/scripts/lib/pipeline-stages-delivery.sh:676-687` —
  shipwright `_write_merge_retry_ctx_review` precedent. ADR-026 maps
  the file-based retry-context pattern into zbuild's cycle vocabulary
  (explicit `feedback:` edge instead of implicit `.retry-context-build.md`).
- Issue #702 / #709 (Wave 17-A) — ADR-027 baseline this ADR depends on.
- Issue #703 (Wave 17-B) — template loader + `abort_when` mechanism
  this ADR reuses.
- Issue #706 (Wave 18-A) — this ADR.
- Issue #707 (Wave 18-B) — `review_cycle` template + build plugin
  impl; flips ADR-026 to Accepted.
- Issue #708 (Wave 18-C) — contract lint enforcing ADR-027 invariants
  including the new `review_cycle` section shape.
