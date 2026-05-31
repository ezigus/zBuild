# ADR-022: Test Assessment Stage — LLM-Interpreted Test Verdict

**Status:** Accepted
**Date:** 2026-05-31
**Issue:** #572 (this ADR), #567 (implementation plan)
**Amends:** ADR-018 (Pattern 1 stages list), ADR-019 (verdict source precedence), ADR-020 (data flow table + LLM-interpreted verdict stages), ADR-021 (cycle `until:` predicate + feedback wiring)
**Related:** ADR-013 (canonical stage list), ADR-001 (plugin contract), ADR-015 (stage-io capture)

## Context

The structural test verdict shipped by `plugins/tool/test/` — exit code +
parsed `"X passed"` / `"X failed"` counts (ADR-019 §2, §6) — is
insufficient for cycle convergence. A cycle whose `until: test.verdict==pass`
either:

- loops forever on flakiness because every iter's structural verdict is
  `fail` even though no real regression exists, or
- converges on hollow no-op `test_cmd`s (the #485 silent-failure class:
  the `total > 0` guard catches `ZBUILD_TEST_CMD="true"` but cannot judge
  whether legitimately passing counts represent forward progress).

The `test` plugin's job is **deterministic execution** (ADR-018 §"Deterministic
operations stay bash"). Folding LLM judgment into it conflates two roles
and breaks the safety invariant that test execution is auditable as a
pure tool.

ADR-021's `build_test_cycle` (#511) exposed the gap: the cycle needs a
*semantic* verdict (does this iteration represent forward progress?) that
the structural test verdict cannot provide. ADR-019's review coercion
further demonstrates that downstream stages already want an interpretable
signal — today each consumer re-interprets raw counts independently.

## Decision

Introduce `test_assessment` as a canonical Pattern 1 stage slotted between
`test` and `review` in the canonical stage sequence (ADR-013 amended by
#572 implementation). The decision is recorded as nine pins:

1. **Stage location.** New plugin at `plugins/agent/test-assessment/` with
   `manifest.yaml` + `plugin.sh` + `tests/`. Role: `test-assessor`.

2. **Inputs.** `test_results` (required, from `test`) and `diff_patch`
   (optional, from `build`). The diff is included so the LLM can
   correlate failures to the changes that produced them.

3. **Output schema.** `test-assessment.json`:

   ```
   {
     "schema_version": 1,
     "verdict": "pass|fail|error|inconclusive",
     "summary": "<one-line operator-facing>",
     "diagnosis": "<multi-line root-cause analysis>",
     "required_changes": ["..."],
     "agrees_with_build_complete": true|false,
     "branch_numstat": {"files": <int>, "insertions": <int>, "deletions": <int>},
     "failure_summary_md": "<markdown; used as cycle feedback>",
     "iter": <int>
   }
   ```

4. **Verdict enum.** `pass | fail | error | inconclusive`. The four-value
   set aligns with the existing `_cycle_detect_blocked` matcher
   (`error|corrupt_diff|block`); `inconclusive` is the dedicated LLM
   uncertainty path that does NOT trigger blocked termination.

5. **Verdict invariant.** `verdict == pass` REQUIRES
   `test.failed == 0 && agrees_with_build_complete && build.verdict == pass`.
   The assessment can downgrade structural pass into `fail` /
   `inconclusive`, but it can NEVER upgrade structural failure into
   convergence. This invariant is enforced at the consumer side
   (review per ADR-019 §7, cycle per ADR-021 amendment) and asserted
   by plugin tests.

6. **Primary output.** `outputs[].primary: true` on `test_assessment`
   per ADR-020's #507 amendment. CI lint enforces the single-primary
   invariant.

7. **Renderer.** A new `render_test_assessment_md` function is
   registered via `register_artifact_renderer "test_assessment"
   render_test_assessment_md` at plugin bootstrap (ADR-018 §"Artifact
   renderer registry"). The stage-io banner picks it up for both
   producer and consumer sides.

8. **Envelope-mode contract.** Pattern 1 with tools requires JSON
   envelope mode (ADR-018 decision #8). The plugin exports
   `ZBUILD_ROUTER_JSON_OUTPUT=1` and
   `ZBUILD_ROUTER_ARTIFACT_ID=test_assessment` around its
   `route_to_model` call, routes `.result` through
   `extract_first_json_object`, and follows the "respond with `{` …"
   prompt rule (#478). Malformed output → `verdict=error`, rc=1.

9. **Feedback wiring.** `test_assessment.failure_summary_md` flows into
   build's `prior_test_failures` input via `source: cycle_feedback`
   (ADR-020 #511 amendment). The empty-feedback omission rule (#511
   Pin 5) is unchanged: empty `failure_summary_md` produces no
   preamble. The test plugin remains UNCHANGED — feedback is sourced
   from the assessment, not the deterministic tool stage.

## Consequences

### Positive

- Review's verdict has a clear preferred source (ADR-019 §7) rather than
  a per-consumer re-interpretation of raw counts.
- Cycle convergence becomes *semantic* (does this iter make forward
  progress?) rather than *structural* (did exit code happen to be 0?).
- The `test` plugin stays deterministic per ADR-018 — no LLM call leaks
  into the auditable tool layer.
- Feedback to build is high-signal markdown (`failure_summary_md`) rather
  than raw `"X failed"` counts. Build's `prior_test_failures` preamble
  becomes operator-readable.
- The four-value verdict enum aligns with existing cycle machinery
  (`_cycle_detect_blocked` already matches `error|corrupt_diff|block`),
  so the blocked-termination predicate (#528) extends cleanly.

### Negative

- One extra LLM call per cycle iteration (cost + latency).
- One extra plugin to maintain.
- Potential drift between `test_assessment.verdict` and `test.verdict`
  requires the resolution-order table in ADR-019 §7. The verdict
  invariant (pin 5) limits the drift surface to `pass → fail` /
  `pass → inconclusive`; the reverse direction is structurally
  forbidden.

### Fail-closed

Assessment missing OR malformed → treated as `unknown` → review coerces
`approve → request_changes` (ADR-019 §7); cycle continues iterating
because verdict is not `pass`. The cycle does NOT converge on missing
assessment, mirroring ADR-021's verdict-missing rule.

### Fail-open class

`verdict=inconclusive` is the ONLY non-blocking non-pass value:

- **Cycle:** treated as `fail` (keep iterating until max_iterations,
  plateau, or convergence). NOT blocked.
- **Review:** treated as `unknown` (fail-closed; coerces
  `approve → request_changes`).

The LLM signalling uncertainty (`inconclusive`) is distinct from the LLM
or plugin failing (`error`). The latter is blocked per ADR-021 §"Blocked
termination class (#528)"; the former is normal cycle iteration.

## Alternatives considered

### (a) Inline LLM call in the test plugin

Have `plugins/tool/test/plugin.sh` invoke `route_to_model` after parsing
the structural counts and emit a richer verdict directly.

**Rejected.** Violates ADR-018's "Deterministic operations stay bash"
clause; conflates execution with judgment; breaks the `test` plugin's
auditability as a pure tool. A future operator debugging "did tests
actually run?" would have to disentangle deterministic exit-code
behavior from LLM interpretation, which is the exact pathology ADR-018
prevents.

### (b) Extend the test plugin's verdict logic with richer heuristics

Add heuristics to `_test_run_inner` (e.g. "verdict=fail unless N
consecutive iterations show the same failing test name"). No LLM call;
just smarter bash.

**Rejected.** Heuristics cannot judge regressions vs flakes. The failure
modes (#485 silent no-op, #527 cycle masking) recur in a new shape:
heuristics encode policy that drifts from reality. The verdict needs
*judgment*, not pattern matching.

### (c) Augment the review prompt to do assessment inline

Let `review` interpret `test-results.json` itself and feed the cycle
through a different `until:` source (e.g. review's own JSON).

**Rejected.** ADR-021 Pin 7 specifies that the cycle's `until:`
predicate fires BEFORE review runs (the cycle terminates, then review
runs as the next dispatch unit). Review-time assessment cannot inform
cycle convergence: by the time review sees the artifact, the cycle has
already converged or hit `max_iterations`. The signal must live BETWEEN
test and review, not after.

## References

- [ADR-013](ADR-013-canonical-stage-list.md) — canonical stage list (amended to insert `test_assessment` between `test` and `review`)
- [ADR-018](ADR-018-stage-invocation-modes.md) — Pattern 1 stage invocation; `test_assessment` joins plan/review/security-lens
- [ADR-019](ADR-019-review-fail-closed-on-test-failure.md) §7 — verdict-source precedence (assessment > test)
- [ADR-020](ADR-020-inter-stage-data-contract.md) — inter-stage data contract; LLM-interpreted verdict stages subsection codifies the manifest schema
- [ADR-021](ADR-021-pipeline-cycle-semantics.md) — cycle semantics; `test_assessment` as `until:` source + feedback wiring
- Issue #567 — implementation plan (plugin scaffolding, tests, manifest)
- Issue #568 — cycle wiring (`standard.yaml` cycle definition update)
- Issue #569 — review consumer wiring (precedence table consumer)
- Issue #571 — build prompt update (consume `prior_test_failures` from assessment feedback)
- Issue #572 — this ADR (amendments + new record)
