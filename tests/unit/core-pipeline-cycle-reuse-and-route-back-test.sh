#!/usr/bin/env bash
# Tests: simple.yaml build_test_cycle feedback edge + the no-progress stall-break
# (issue #1117). simple.yaml's build_test_cycle loops on failure but declared no
# feedback edge, so build re-ran each iter with the identical task and zero
# failure context → empty_diff → no convergence, burning all 5 iterations.
#
# SPEC-1: the feedback edge delivers failure detail — _cycle_apply_feedback writes
#         a non-empty <to_field>.txt in the next-iter feedback dir referencing the
#         failure (B2/ADR-040: build's gate_feedback input).
# SPEC-2: the simple.yaml edge parses + the producer (gate-aggregator:gate_feedback)
#         resolves to a path that EXISTS in simple.yaml's flow (no required-edge
#         cycle.feedback.missing surprise — it is required:false regardless).
# SPEC-3: the stall-break fires — build verdict=empty_diff + gate-aggregator
#         verdict!=pass ⇒ cycle terminates reason=stalled within <=2 iterations
#         (NOT max_iterations=5), emitting cycle.stalled.
# SPEC-4: empty_diff + gate-aggregator verdict=pass ⇒ converged (no false stall).
# B6 (#1138, ADR-040): build_test_cycle converges on the gate-aggregator verdict
# — the stub drives the decomposed gate roster.
# #2191: split from core-pipeline-cycle-stall-break-test.sh (SPEC-5/6/7), which
# ran past the 480s per-file timeout on loaded CI runners.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build_test_cycle: reuse on an unchanged tree, re-verify a non-reproduction, route back on scope (#2170 #2183 #2178)"
setup_test_env "cycle-reuse-route-back"

# shellcheck source=../lib/cycle-stall-break-fixture.sh
source "$REPO_ROOT/tests/lib/cycle-stall-break-fixture.sh"

# ─── SPEC-5 (#2170): an unchanged tree re-yields the SAME verdicts, failing ones too ─
# #1841: build changed nothing (blocked on testfiles it may not edit), so the
# tree was identical to the previous iteration's — and the 25-minute suite ran
# again to fail the same way, five times. #2117 reused only PASSING members;
# a deterministic member's failure on the same tree is just as reusable.
print_test_section "SPEC-5: empty_diff on the tree a previous iteration FAILED ⇒ that failure is reused, not re-run"
_GA_VERDICT="fail"; _TEST_VERDICT="fail"; _AG_VERDICT="fail"
_run_cycle "refail"
_n_test_f="$(grep -c '"cycle.member.dispatch.complete".*"member":"test"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-5] the FAILING test member is dispatched exactly ONCE across 5 iterations" "1" "$_n_test_f"
_n_reused="$(grep -c '"cycle.iteration.reused".*"member":"test"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-5] …and reused on each of the other four" "4" "$_n_reused"
# An iteration-aware member (spec-acceptance escalates at iter >= 2, #2157) is
# NOT reused on failure — its answer depends on the iteration, not just the tree.
_n_ag_f="$(grep -c '"cycle.member.dispatch.complete".*"member":"acceptance-gate"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-5b] the FAILING acceptance-gate (iteration-aware) is re-dispatched every iteration" "5" "$_n_ag_f"
# …and once a member re-ran, everything after it runs too (its fault may have changed).
_n_ga_f="$(grep -c '"cycle.member.dispatch.complete".*"member":"gate-aggregator"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-5c] the gate-aggregator after a re-dispatched gate is re-dispatched too" "5" "$_n_ga_f"
_AG_VERDICT="pass"
# #2172: exhausted with the suite failing and a build that changed NOTHING is
# the contract's problem, not the builder's — the loop widens to design.
assert_eq "[SPEC-5] exhausted with tests failing and an unchanged tree routes back to design (rc=11)" "11" "$_RUN_RC"
assert_eq "[SPEC-5] …with reason route_back" "route_back" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "[SPEC-5] …to the template's route_back target" "design_verify_cycle" "${_CYCLE_ROUTE_BACK_TO:-}"
_n_rb="$(grep -c '"cycle.route_back.exhausted_unchanged"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-5] …and says why (cycle.route_back.exhausted_unchanged)" "1" "$_n_rb"
_TEST_VERDICT="pass"

# ─── SPEC-7 (#2183): a finding that did not reproduce is re-verified ───────
# #1841 run 35802918016: the builder ran the named test 15 times, it passed
# every time, and its prompt forbade saying so — six model calls and 92 minutes
# went into proving a failure that does not exist on this tree. A stage may now
# REPORT non-reproduction; it is not a verdict of done. The engine re-runs the
# member that raised the finding, on the same tree, instead of reusing its
# previous verdict — which is the only way to tell a real intermittent failure
# from a stale one.
print_test_section "SPEC-7: a reported non-reproduction re-runs the member that raised it"
_GA_VERDICT="fail"; _TEST_VERDICT="fail"; _AG_VERDICT="fail"
# Baseline: an unchanged tree reuses the failing member exactly once (#2170).
_BUILD_NOT_REPRODUCED=""
_run_cycle "no-report"
_n_base="$(grep -c '"cycle.member.dispatch.complete".*"member":"test"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-7 guard] with no report the failing member is dispatched once and reused after" "1" "$_n_base"
# With the report, the member that raised the finding is dispatched again on
# that same unchanged tree — the only way to tell a real intermittent failure
# from a stale one.
_BUILD_NOT_REPRODUCED="tests/integration/per-run-state-isolation-test.sh"
_run_cycle "not-repro"
_n_repro="$(grep -c '"cycle.member.dispatch.complete".*"member":"test"' "$ZBUILD_EVENTS_JSONL" || true)"
if [[ "${_n_repro:-0}" -gt "${_n_base:-0}" ]]; then
    assert_pass "[SPEC-7] the reported member is re-run rather than reused (${_n_repro} vs ${_n_base} without the report)"
else
    assert_fail "[SPEC-7] the reported member is re-run rather than reused" \
        "dispatched ${_n_repro}x with the report, ${_n_base}x without — the stale failure was reused"
fi
_BUILD_NOT_REPRODUCED=""
_TEST_VERDICT="pass"; _AG_VERDICT="pass"

# ─── SPEC-6 (#2178): a build blocked on scope is the contract's problem too ─
# Run 35674168348 ended `blocked_on_scope`: the builder needed files the
# contract denies. Same class as SPEC-5 — the build cannot complete under the
# current contract — so it takes the same edge, under the same budget. The
# engine reads no reason from build; the denied request IS the signal.
print_test_section "SPEC-6: a denied scope request routes back to design instead of ending the run"
_BUILD_SCOPE_REQUEST='{"files":[{"path":"tests/unit/other-test.sh","category":"collateral_tests","evidence":"","reason":"named in test feedback"}]}'
_GA_VERDICT="fail"
_run_cycle "scope-rb"
assert_eq "[SPEC-6] the cycle returns route_back (rc=11)" "11" "$_RUN_RC"
assert_eq "[SPEC-6] after ONE iteration — no grinding" "1" "${_CYCLE_LAST_ITERATIONS:-}"
assert_eq "[SPEC-6] to the template's route_back target" "design_verify_cycle" "${_CYCLE_ROUTE_BACK_TO:-}"
assert_eq "[SPEC-6] the stashed fallback is the scope terminal (rc=7)" "7" "${_CYCLE_ROUTE_BACK_FALLBACK_RC:-}"
assert_eq "[SPEC-6] …with its reason" "blocked_on_scope" "${_CYCLE_ROUTE_BACK_FALLBACK_REASON:-}"
assert_eq "[SPEC-6] and says why (cycle.route_back.blocked_on_scope)" "1" \
    "$(grep -c '"cycle.route_back.blocked_on_scope"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-6] the denial itself is still recorded" "1" \
    "$(grep -c '"cycle.scope.denied"' "$ZBUILD_EVENTS_JSONL" || true)"
# With the edge's budget spent the old terminal stands: the run ends blocked.
_RUNNER_ROUTE_BACK_PASSES=2
_run_cycle "scope-nobudget"
unset _RUNNER_ROUTE_BACK_PASSES
assert_eq "[SPEC-6b] budget spent ⇒ blocked_on_scope terminal (rc=7)" "7" "$_RUN_RC"
assert_eq "[SPEC-6b] …with reason blocked_on_scope" "blocked_on_scope" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "[SPEC-6b] and no route_back event" "0" \
    "$(grep -c '"cycle.route_back.blocked_on_scope"' "$ZBUILD_EVENTS_JSONL" || true)"
_BUILD_SCOPE_REQUEST=""

cleanup_test_env
print_test_results
exit $((FAIL > 0))
