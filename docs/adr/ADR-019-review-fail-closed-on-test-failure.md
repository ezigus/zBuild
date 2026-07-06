# ADR-019: Review Fail-Closed on Unknown or Failed Tests

**Status:** Accepted
**Date:** 2026-05-30
**Issue:** #485
**Related:** ADR-013 (canonical stage list), ADR-018 (stage invocation modes),
keeper #17 (gate semantics)

## Context

Two issues surfaced together during the Wave B → Wave C transition:

1. **Standard template lacked the `test` stage.** `config/templates/standard.yaml`
   declared four stages — intake, plan, build, review — even though
   `plugins/tool/test/` had been shipping a real test-runner plugin since #342.
   Every default pipeline run reached the review stage with no test signal at
   all; the review LLM was told to verify "tests pass" with no evidence either
   way. Reviewers approved diffs that had never been tested.

2. **The review prompt asked the LLM to police itself.** ADR-018 (#469) lifted
   the "no tool-use" prohibition so review could Read files inside scope.
   Nothing on the plugin side post-validated the verdict against the test
   artifact — an approve verdict from the LLM was written through verbatim,
   even when `test-results.json` was missing or recorded a failed run. This is
   the same class of trust-the-LLM bug ADR-004 (redaction chokepoint)
   addresses: safety primitives belong in code, not in prompts.

A third issue compounded the first two:

3. **Test plugin silently approved no-op runs.** `plugins/tool/test/plugin.sh`
   parsed `"X passed"` / `"X failed"` lines from test output but defaulted to
   `verdict=pass` whenever `test_cmd` exited 0 — including `true`, `:`, and
   empty scripts. A misconfigured test stage looked identical to a passing
   test suite at the artifact layer.

Keeper #17 (gate semantics) is the long-term home for fail-closed counts at
the pipeline-engine layer. This ADR records the plugin-layer post-validation
contract for one specific dimension: the test-status signal feeding the
review verdict. ADR-018 covers the envelope/prompt layer (Pattern 1);
this is the orthogonal layer below it.

## Decision

### 1. The `test` stage is part of `standard.yaml`

`config/templates/standard.yaml` declares the stage between `build` and
`review`, with `roles: [tester]`. The `tester` role is registered via
`provides.role: tester` on `plugins/tool/test/manifest.yaml`. The canonical
stage sequence in ADR-013 already anticipated this slot (intake → plan →
design → **build → test → review** → …).

### 2. Schema-mismatch resolution (Option A)

The test plugin writes `.verdict` (`pass | fail | error`); the review plugin
consumes that field directly via the new `_review_derive_test_status` helper.
No producer change to the test-results.json schema; review derives its
internal `test_status` (`passed | failed | unknown`) from the producer field:

| `.verdict`           | `test_status` |
| -------------------- | ------------- |
| `pass`               | `passed`      |
| `fail`               | `failed`      |
| `error`              | `failed`      |
| missing / other      | `unknown`     |
| file does not exist  | `unknown`     |

`error` maps to `failed` (not `unknown`) so that a producer-reported error
is treated as fail-closed evidence, not absence of evidence.

### 3. Verdict coercion rules

After the existing invalid-verdict fallback and before review.json is
written, the review plugin applies:

- `verdict == approve` AND `test_status ∈ {unknown, failed}`
  → coerce to `request_changes`
- `verdict == block` → stays `block` (block is the floor; we never demote)
- `verdict == request_changes` → stays (no change)

Coercion is one-way (approve → request_changes only). LLM confidence is
preserved verbatim — it is an advisory signal, not a safety lever. The
coercion appends a synthetic issue:

> "tests did not pass (test_status=$X); approve coerced to request_changes"

and prepends a marker to the summary so the LLM's reasoning stays visible:

> "[coerced: tests $test_status] $original_summary"

Operators see a stderr banner:

> "review_run: verdict coerced from approve to request_changes (test_status=$X)"

so they do not need to grep `events.jsonl`.

### 4. Coercion event

A single event documents every coercion, mirroring `review.scope.violation`
style with flat key=value payload:

```
review.test_status.coerced
  plugin=review
  stage=review
  original_verdict=approve
  coerced_verdict=request_changes
  test_status=unknown|failed
  test_exit_code=<int|empty>
```

Added to `config/event-schema.json::known_types`.

### 5. Prompt-layer reinforcement

The review prompt's Rules section gains a single line:

> "An approve verdict requires that test results show tests passed; if test
> results are missing, unknown, or failed, return request_changes (not approve)."

This is a hint, not a defence — the plugin-layer coercion above is the
authoritative gate. The prompt rule keeps the LLM's behaviour aligned with
the gate so coercion fires rarely in practice.

### 6. Test plugin silent-failure guard

`plugins/tool/test/plugin.sh` adds a `total > 0` guard: if `passed == 0`
AND `failed == 0` AND `exit_code == 0`, emit `verdict=error` (not `pass`).
A passing test suite that parses zero passes is indistinguishable from a
no-op `test_cmd`; we fail closed on both.

### 7. Verdict-source precedence with test_assessment (#572, ADR-022)

When the `test_assessment` stage (ADR-022) is present in the template, the
review plugin's `_review_derive_test_status` helper MUST prefer
`test_assessment.verdict` over `test.verdict` as the coercion source. The
mapping table is unchanged:

| Source verdict (test_assessment OR test) | `test_status` |
| ----------------------------------------- | ------------- |
| `pass`                                    | `passed`      |
| `fail`                                    | `failed`      |
| `error`                                   | `failed`      |
| `inconclusive` (test_assessment only)     | `unknown`     |
| missing / other                           | `unknown`     |

Resolution order: `test_assessment.json.verdict` > `test-results.json.verdict`
> `unknown`. Falls back to `test.verdict` for legacy templates without the
assessment stage so the ADR-019 contract remains backward compatible. The
coercion banner gains a `source=test_assessment|test` field for triage. A
new event `review.test_assessment.consumed source=test_assessment` is
emitted when assessment is the chosen source. Fail-closed behavior is
unchanged: `unknown` and `failed` both coerce `approve → request_changes`.

`inconclusive` (the LLM signalled it could not judge) is the ONLY non-blocking
non-pass value emitted by `test_assessment`; review treats it as `unknown`
(fail-closed) and the build/test cycle treats it as `fail` (keep iterating)
per ADR-021's #572 amendment.

The per-stage verdict source table (#507 amendment, below) gains a row:

| test_assessment | test-assessment.json | `.verdict` (assessed by LLM; pass\|fail\|error\|inconclusive) |

## Consequences

### Positive

- A default `shipwright pipeline start` against an issue with broken tests
  can no longer produce a green review. The plugin layer enforces the
  invariant; the LLM is a hint.
- Schema-mismatch (review reading `.status` that producers never wrote)
  is permanently resolved at the consumer side without breaking the test
  plugin's artifact contract.
- The `tester` role makes test-plugin selection explicit in `standard.yaml`
  rather than relying on the stage-id fallback.

### Negative

- Existing review tests that fed canned approve responses without installing
  a `test-results.json` fixture now exercise the coercion path. Those tests
  were updated to call a shared `_install_passing_test_results` helper.
- The full-pipeline e2e test's `ZBUILD_TEST_CMD="true"` now produces
  `verdict=error` (no-op guard) which in turn coerces the review verdict.
  Goldens for the full-pipeline and parity event sequences include the new
  `review.test_status.coerced` line.

### Out of scope

- Other fail-closed dimensions (scope-violation counts, file-count
  thresholds, redaction-failure counts) — keeper #17 will track each as
  a separate plugin-layer post-validation.
- Test plugin output-format harmonization beyond the `total > 0` guard
  (e.g. structured pytest / jest result ingestion).
- Block-verdict treatment under test failure: block is already the floor,
  and demoting it would be the wrong direction. Promoting from
  `request_changes` to `block` on test failure is a separate policy
  question not addressed here.

## Implementation Notes (Phase 1, issue #485)

Files touched in #485:

- `config/templates/standard.yaml` — inserted `test` stage between build
  and review.
- `plugins/tool/test/manifest.yaml` — added `provides.role: tester`.
- `plugins/tool/test/plugin.sh` — added the `total > 0` silent-failure
  guard inside `_test_run_inner`.
- `plugins/agent/review/plugin.sh` — added `_review_derive_test_status`
  helper, coercion block (after invalid-verdict fallback, before review.json
  write), and the prompt rule.
- `config/event-schema.json` — registered `review.test_status.coerced`.
- `plugins/agent/review/tests/review-test.sh` — `_install_passing_test_results`
  helper + new tests 13–17 covering the coercion contract.
- `plugins/tool/test/tests/test-test.sh` — new test 4b for the no-op guard.
- `tests/unit/core-pipeline-template-test.sh` — updated for 5-stage
  standard.yaml; new assertion for `tester` role.
- `tests/e2e/full-pipeline-test.sh` — added build < test < review ordering
  assertion.
- `tests/golden/full-pipeline/event-sequence.golden`,
  `tests/golden/parity/event-sequence.golden` — added the new coerce event
  emitted under the all-`true` test fixture.
- `docs/adr/ADR-019-review-fail-closed-on-test-failure.md` — this file.

## Implementation Notes (Phase 1, issue #507) — verdict-driven indicators

#485 wired the review stage to consume the test plugin's `.verdict` field;
the runner itself still painted every rc=0 stage with a green `✓`. Issue
#507 generalises ADR-019's verdict-awareness across **every** stage's
operator-facing indicator.

The runner now sources `core/pipeline/verdict.sh`, which reads the plugin's
manifest-declared *primary* output (a new `outputs[].primary: true` flag —
exactly one per stage-bound manifest, enforced by `scripts/lib/lint-contract.sh`)
and maps the verdict to one of `pass | warn | fail | unknown`:

| Verdict (raw)                                | Class | Glyph | Color  |
| -------------------------------------------- | ----- | ----- | ------ |
| `pass`, `approve`                            | pass  | `✓`   | GREEN  |
| `request_changes`                            | warn  | `⚠`   | YELLOW |
| `fail`, `error`, `block`, `scope_violation`, `corrupt_diff` | fail | `✗` | RED |
| missing/malformed primary artifact           | warn  | `⚠`   | YELLOW |
| `rc != 0` (any cause)                        | fail  | `✗`   | RED — rc always wins |

`security-lens` keeps its **informational** role: an emitted
`security-findings.json` is always treated as `pass`, never as a stop.
Gate semantics (which verdicts halt the pipeline) are *unchanged* in #507;
this is an indicator-only change.

Note: `corrupt_diff` (added in #509) is the third terminal verdict value
for build alongside `pass` and `scope_violation`. The build plugin sets it
when `git apply --check -R` rejects the post-loop `diff.patch`; the plugin
also returns rc=1 in that case so the runner's rc-wins halt path
(`core/pipeline/runner.sh:672-686`) prevents the downstream test stage
from ever running on a syntactically corrupt patch.

Test stage `verdict=fail` no longer appears as `✓` — the regression that
motivated #507.

### Note (#527): cycle-unconverged signal propagation

When the outer build/test cycle (ADR-021) terminates non-converged (rc∈{1,2,3}:
max_iterations, plateau, divergence), the runner now sets
`stage_statuses[<until-stage>]=failed` (typically `test`) BEFORE dispatching
review. This ensures `_review_derive_test_status` has an unambiguous failure
signal even if test-results.json is stale or missing, so the coercion
`approve → request_changes` fires deterministically. Without this
propagation (pre-#527), the cycle's non-convergence could be silently masked:
review would approve, runner would write `pipeline_status=complete`, and the
ADR-019 contract was violated. The propagated `stage_statuses[test]=failed`
combined with `_RUNNER_CYCLE_UNCONVERGED=1` (which controls the final
`pipeline_status=failed` write) closes that hole.

### Amendment (#1261): on_max=continue fall-through — timeout-exhaustion exception

`on_max: continue` (this ADR's fall-through) is a deliberate CONTENT policy: an
imperfect-but-usable artifact from an unconverged cycle should flow to the
operator/downstream, not hard-fail. It was NOT meant to cover an INFRA failure.

`design_verify_cycle` is `max_iterations: 3, on_max: continue`. A SINGLE design
router-timeout is recoverable (#945: design writes a gate-FAILING marker so the
cycle re-iterates). But when EVERY iteration times out (a persistent infra
problem), the cycle exhausts and — under `on_max: continue` — would fall through
carrying the empty `# Design incomplete — router timeout` marker to build, which
then implements from nothing.

**Exception:** when the TERMINATING iteration was interrupted by a router
timeout — a member surfaced the repo-neutral `did_not_finish` verdict (build's
#1208 verdict; design's #1261 verdict, carried on a `design-verdict.json`
sidecar) — AND the cycle has NO authoritative verifier signal (no `test` member
verdict and no `test-results.json`), the cycle HALTS with terminal reason
`design_timeout_exhausted` (rc=8 → pipeline `status=failed`) even though
`on_max: continue`. This is NOT `on_max: halt` (too blunt — it would also
hard-fail a genuine CONTENT non-convergence): a content non-convergence has no
`did_not_finish` tail and keeps the fall-through above.

**Repo-neutral.** The exception keys ONLY on the `did_not_finish` tail plus the
absence of a test signal — never on a stage id. `build_test_cycle` ALWAYS runs
`test` (so it has a signal) and is therefore unaffected (scope: design-only for
now); a future verifier-less cycle inherits the same fail-fast. See ADR-021
Amendment (#1261) for the terminal-reason registration.
