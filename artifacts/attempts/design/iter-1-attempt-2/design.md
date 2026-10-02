# Design — §3/§4: unfinished member blocks convergence; gates emit real disposition

**Issue:** #2032  
**Status:** Proposed

## Architectural decision summary

**Goal.** Two independent behavioral gaps produce the same symptom — a stage that did
not finish appears complete to downstream consumers.

**(A) §4/A — engine.** The build-specific convergence suppression fires only when the
commit-producing member is unfinished (`cycle-orchestrator.sh:2609`). A
`design_verify_cycle` has no commit-producing member, so when `design` times out but
`design-gate` matches the `exit_when` predicate on stale output, the cycle converges
falsely. The fix adds a second suppression block (`cycle-orchestrator.sh:2623`) that
fires when `converged==0 AND _iter_did_not_finish==1` — `_iter_did_not_finish` is
already computed over all members at lines 2575–2582. The new block cannot double-fire
with the build block: when the build member is unfinished, the build block fires first
and sets `converged=1`, so the new block's `converged==0` guard is false. The
empty-diff resting point is also safe: empty_diff members emit `disposition:complete`,
so `_iter_did_not_finish` stays 0.

**The new event `cycle.member_unfinished.suppressed_convergence` must be registered in
`config/event-schema.json` under `known_types`.** Omitting this causes
`event-schema-emitted-coverage-test.sh` to fail (confirmed in iteration 1 test run).
The build stage in iteration 1 missed this registration — iteration 2 must add it.
`config/event-schema.json` is correctly listed in WIRING; the acceptance-gate
reachability check will pass once the file is modified.

**(A.3) max_iterations boundary.** When the suppression block fires on the LAST
iteration (iter == max_iterations), convergence is suppressed and the cycle cannot
iterate further. The `elif [[ "$converged" -eq 0 ]]` branch (which would emit
`complete`) is now skipped; the `_cycle_check_max_iterations` branch fires instead.
Because `_iter_did_not_finish==1` and `_exh_tests_reported==0` (no test member in a
`design_verify_cycle`), the existing #1261 exhaustion path fires:
`cycle.timeout_exhausted` is emitted and `term_rc=8`. SPEC-6 covers this boundary.

**(B) §3/B — plugins.** `spec-coverage`, `spec-correspondence`, and `review-report`
all hardcode `disposition:"complete"` even when `route_to_model` exits non-zero.
`router_reason_disposition` (`scripts/lib/router-rc-classify.sh`) — already in
scope via `route.sh` — maps a router reason to the correct disposition word.
Each plugin captures the router rc, classifies it with `_router_rc_classify`, and
passes the result to its result-writer. The fallback assignment
`|| _*_disposition="unavailable"` (for cases where `router_reason_disposition`
returns empty) **requires a `# disposition-ok: the model router is not responding`
annotation on or within three lines before it** — required by `lint-disposition-words`
(ADR-054 §6a), enforced by `stage-signal-test.sh [G5]`. Iteration 1 added the
fallback without the annotation, causing `lint-disposition-words-test.sh` and
`stage-signal-test.sh [G5]` to fail. The two specific locations are:
  - `plugins/agent/spec-correspondence/plugin.sh:315` (`_sc_disposition="unavailable"`)
  - `plugins/agent/review-report/plugin.sh:180` (`_disposition="unavailable"`)
For `review-report`, the first non-zero rc across all failed lenses is selected
before classification (any unfinished disposition triggers retry).

**(C) §C — ADR-063.** ADR-063 was proposed against the `exhausted` vocabulary
that #2187 retired. Status advances to Accepted; §3/§4 vocabulary is updated to
`timed_out`/`out_of_turns` per `router_reason_disposition`; the `exhausted → escalate`
branch of §4 is stricken (the retry table in ADR-029 replaces it); §1's "One helper"
note is updated to per-stage helpers; a dated back-pointer to #2187 is added.
SPEC-7 verifies the amendment is in place. ADR-021 receives an amendment block
documenting the new `cycle.member_unfinished.suppressed_convergence` suppression case
(already landed in commit `ecf0749b`).

**Shape-floor.** `config/shape-change-paths.txt` includes both
`core/pipeline/cycle-orchestrator.sh` and `config/event-schema.json`. Because
`cycle-orchestrator.sh` is in the diff, the shape-floor fires. The shape-floor gate
(`scripts/lib/shape-floor.sh`) requires all `tests/golden/**/event-sequence.golden`
files and all `_TPL_STAGES[N]`-indexed test files to appear in the diff **and** be
actually changed (`_sf_floor_file_updated` rejects comment-only touches, per #2183).
The standard full-pipeline and parity golden scenarios do NOT emit
`cycle.member_unfinished.suppressed_convergence`, so their event sequences are
unchanged in content — nonetheless, the build stage must touch these files with a
real (non-comment) edit to satisfy the gate. The append-only exemption
(schema sole-match) does NOT apply because `cycle-orchestrator.sh` is also matched.

```scope
core/pipeline/cycle-orchestrator.sh
core/pipeline/disposition.sh
plugins/agent/spec-coverage/plugin.sh
plugins/agent/spec-correspondence/plugin.sh
plugins/agent/review-report/plugin.sh
scripts/lib/router-rc-classify.sh
config/event-schema.json
docs/adr/ADR-021-pipeline-cycle-semantics.md
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
tests/integration/cycle-member-unfinished-no-convergence-test.sh
tests/unit/spec-coverage-test.sh
tests/unit/spec-correspondence-test.sh
tests/unit/review-report-v2-contract-test.sh
tests/unit/convergence-timeouts-never-fatal-1208-test.sh
tests/unit/design-timeout-exhaustion-halt-1261-test.sh
tests/unit/router-reason-disposition-test.sh
tests/unit/disposition-vocabulary-test.sh
tests/unit/adr-063-vocabulary-test.sh
tests/unit/event-schema-emitted-coverage-test.sh
tests/unit/lint-disposition-words-test.sh
tests/unit/stage-signal-test.sh
tests/golden/full-pipeline/event-sequence.golden
tests/golden/parity/event-sequence.golden
tests/unit/template-simple-yaml-test.sh
tests/unit/build-oos-pass-request-test.sh
tests/unit/core-pipeline-template-test.sh
tests/unit/template-resolvability-preflight-test.sh
tests/unit/impact-prefilter-order-detector-test.sh
```

```acceptance
SPEC-1[change]: when converged==0 (exit_when predicate matched) and any iteration member carries an unfinished disposition (timed_out, out_of_turns, or interrupted), the cycle does NOT converge — it emits cycle.member_unfinished.suppressed_convergence and iterates instead
SPEC-2[guard]: when all iteration members carry disposition:complete and the exit_when predicate matches, the cycle converges normally; the new unfinished-member suppression block does not fire
SPEC-3[change]: spec-coverage — when route_to_model exits non-zero (e.g., rc=124 timeout) and produces no parseable verdict, spec-coverage-result.json carries the disposition classified via router_reason_disposition (e.g., timed_out), not the hardcoded 'complete'
SPEC-4[change]: spec-correspondence — when the router call exits non-zero, spec-correspondence-result.json carries the disposition classified via router_reason_disposition, not the hardcoded 'complete'
SPEC-5[change]: review-report — when one or more lens subshells return a non-zero exit code, review-report.json carries the disposition classified from the first failed lens rc via router_reason_disposition, not the hardcoded 'complete'
SPEC-6[change]: at max_iterations when the last iteration has any member with an unfinished disposition, the §4/A suppression block fires (preventing false complete), and the cycle takes the existing #1261 exhaustion path — emitting cycle.timeout_exhausted with reason=design_timeout_exhausted and term_rc=8, not rc=0 complete
SPEC-7[change]: docs/adr/ADR-063-budget-disclosure-and-partial-output.md status header reads "Accepted" and the document contains no prescriptive use of `exhausted` as the §3 disposition word or `escalate` as the §4 engine action — vocabulary is updated to timed_out/out_of_turns per #2187
WIRING:
core/pipeline/cycle-orchestrator.sh
plugins/agent/spec-coverage/plugin.sh
plugins/agent/spec-correspondence/plugin.sh
plugins/agent/review-report/plugin.sh
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
config/event-schema.json
TESTFILES:
SPEC-1: tests/integration/cycle-member-unfinished-no-convergence-test.sh
SPEC-2: tests/integration/cycle-member-unfinished-no-convergence-test.sh
SPEC-3: tests/unit/spec-coverage-test.sh
SPEC-4: tests/unit/spec-correspondence-test.sh
SPEC-5: tests/unit/review-report-v2-contract-test.sh
SPEC-6: tests/integration/cycle-member-unfinished-no-convergence-test.sh
SPEC-7: tests/unit/adr-063-vocabulary-test.sh
```

```supersedes
tests/unit/review-report-v2-contract-test.sh [SPEC-5]: asserts `disposition=complete` when a lens subshell call returns rc=1 — after §3/B the disposition is router_reason_disposition of the first failed lens rc (rc=1 → router_rc_nonzero → unavailable); the stale #2187 comment at line 131 that justified hardcoding 'complete' is removed
```

LOOP_COMPLETE
