# Design — §3/§4: unfinished member blocks convergence; gates emit real disposition

**Issue:** #2032  
**Status:** Proposed

## Architectural decision summary

**Goal.** Two independent behavioral gaps produce the same symptom — a stage that did
not finish appears complete to downstream consumers.

**(A) §4/A — engine.** The build-specific convergence suppression fires only when the
commit-producing member is unfinished (cycle-orchestrator.sh:2608–2613). A
`design_verify_cycle` has no commit-producing member, so when `design` times out but
`design-gate` matches the exit_when predicate on stale output, the cycle converges
falsely. The fix adds a second suppression block after line 2613 that fires when
`converged==0 AND _iter_did_not_finish==1` — `_iter_did_not_finish` is already
computed over all members at lines 2574–2581 (it reads `.disposition` from the blob
and calls `disposition_unfinished`, which matches `timed_out|out_of_turns|interrupted`).
The new block cannot double-fire with the build block: when the build member is
unfinished, the build block fires first and sets `converged=1`, so the new block's
`converged==0` guard is false. The empty-diff resting point is also safe: empty_diff
members emit `disposition:complete`, so `disposition_unfinished` returns false for
all of them and `_iter_did_not_finish` stays 0.

The comment at lines 2566–2573 ("Consumed ONLY by the reason-aware exhaustion halt
below") must be updated to reflect that `_iter_did_not_finish` is now also consumed
by the new convergence-suppression block.

**(A.3) max_iterations boundary.** When the suppression block fires on the LAST
iteration (iter == max_iterations), convergence is suppressed and the cycle cannot
iterate further. The `elif [[ "$converged" -eq 0 ]]` branch at line 2728 (which
would emit `complete`) is now skipped; the `elif _cycle_check_max_iterations` branch
at line 2749 fires instead. Because `_iter_did_not_finish==1` and
`_exh_tests_reported==0` (no test member in a `design_verify_cycle`), the existing
#1261 exhaustion path fires: `cycle.timeout_exhausted` is emitted and `term_rc=8`.
Without §4/A, the false convergence at line 2728 fires first, so this exhaustion
path is unreachable. SPEC-6 covers this boundary behavior.

**(B) §3/B — plugins.** `spec-coverage`, `spec-correspondence`, and `review-report`
all hardcode `disposition:"complete"` even when `route_to_model` exits non-zero.
`router_reason_disposition` (scripts/lib/router-rc-classify.sh:259) — already in
scope via `route.sh` — maps a router reason to the correct disposition word.
Each plugin captures the router rc via a temp file (subshell boundary), classifies
it with `_router_rc_classify`, and passes the result to its result-writer.
`_scv_write` and `_sc_write_result` gain an optional disposition argument that
defaults to `complete`, leaving every path that does not involve a router failure
unchanged. For `review-report`, the worst non-zero rc across all failed lenses is
selected before classification (first non-zero is sufficient — any unfinished
disposition triggers retry). The comment on review-report/plugin.sh:174
(`# #2187: the report ran; each lens reports its own cause`) is stale and removed.

**(C) §C — ADR-063.** ADR-063 is still "Proposed" and still prescribes `exhausted`
as the §3 disposition word and `escalate` as the §4 engine action — vocabulary
retired by #2187. Status advances to Accepted; §3/§4 vocabulary is updated to
`timed_out`/`out_of_turns` per `router_reason_disposition`; the `exhausted → escalate`
branch of §4 is stricken (the retry table in ADR-029 replaces it); §1's "One helper"
note is updated to per-stage helpers; a dated back-pointer to #2187 is added. SPEC-7
verifies the amendment is in place and contains no prescriptive `exhausted`/`escalate`
vocabulary. The test (`tests/unit/adr-063-vocabulary-test.sh`) asserts the status
line is Accepted and no §3/§4 prescription still uses the retired words — following
the `adr-migration-claims-test.sh` pattern.

ADR-021 also receives an amendment block documenting the new
`cycle.member_unfinished.suppressed_convergence` suppression case, parallel to the
existing `cycle.build_unfinished.suppressed_convergence` block at line 849–851.

**ADR-039 / ADR-065 are additive since the prior design; neither intersects this
issue's scope.** ADR-039 (parallel stage groups) is a flow-grammar change that does
not touch cycle convergence semantics. ADR-065 (process budget) is a fork-count
contract; the changes here (one suppression block, small plugin patches) do not
materially affect fork count and require no amendment.

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
```

```acceptance
SPEC-1[change]: when converged==0 (exit_when predicate matched) and any iteration member carries an unfinished disposition (timed_out, out_of_turns, or interrupted), the cycle does NOT converge — it emits cycle.member_unfinished.suppressed_convergence and iterates instead
SPEC-2[guard]: when all iteration members carry disposition:complete and the exit_when predicate matches, the cycle converges normally; the new unfinished-member suppression block does not fire
SPEC-3[change]: spec-coverage — when route_to_model exits non-zero (e.g., rc=124 timeout) and produces no parseable verdict, spec-coverage-result.json carries the disposition classified via router_reason_disposition (e.g., timed_out), not the hardcoded 'complete'
SPEC-4[change]: spec-correspondence — when the router call exits non-zero, spec-correspondence-result.json carries the disposition classified via router_reason_disposition, not the hardcoded 'complete'
SPEC-5[change]: review-report — when one or more lens subshells return a non-zero exit code, review-report.json carries the disposition classified from the worst failed lens rc via router_reason_disposition, not the hardcoded 'complete'
SPEC-6[change]: at max_iterations when the last iteration has any member with an unfinished disposition, the §4/A suppression block fires (preventing false complete at line 2728), and the cycle takes the existing #1261 exhaustion path — emitting cycle.timeout_exhausted with reason=design_timeout_exhausted and term_rc=8, not rc=0 complete
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
tests/unit/review-report-v2-contract-test.sh [SPEC-5]: asserts `disposition=complete` when a lens subshell call returns rc=1 — after §3/B the disposition is router_reason_disposition of the worst failed lens rc (rc=1 → router_rc_nonzero → unavailable); the stale #2187 comment at line 131 and the hardcoded-complete comment at line 174 that justified the behaviour are removed
```

LOOP_COMPLETE
