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

print_test_header "build_test_cycle: reuse on an unchanged tree, re-verify a non-reproduction, stop on a denied scope (#2170 #2183 #2178)"
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
assert_eq "[SPEC-5] the FAILING test member is dispatched exactly ONCE across the 3 iterations" "1" "$_n_test_f"
_n_reused="$(grep -c '"cycle.iteration.reused".*"member":"test"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-5] …and reused on each of the other two" "2" "$_n_reused"
# #2271: the acceptance check no longer escalates by round number, so its
# answer depends only on the tree — its failure is reused like any other.
_n_ag_f="$(grep -c '"cycle.member.dispatch.complete".*"member":"acceptance-gate"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-5b] the FAILING acceptance-gate is reused too (dispatched once)" "1" "$_n_ag_f"
_AG_VERDICT="pass"
# #2271: no jump back. Exhausted with the suite failing is a failed end (rc 1,
# outcome failed — rc 8 before #1850, ADR-054 §4); nested in the outer loop,
# that ends the round and the outer loop goes round from design.
assert_eq "[SPEC-5] exhausted with tests failing ⇒ rc=1, outcome failed" "1 failed" "$_RUN_RC ${_CYCLE_LAST_OUTCOME:-unset}"
assert_eq "[SPEC-5] …with reason max_iterations_tests_failing" "max_iterations_tests_failing" "${_CYCLE_LAST_TERMINATED_REASON:-}"
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

# ─── SPEC-6 (#2178, #2271): a build blocked on scope ends this loop at once ─
# Run 35674168348 ended `blocked_on_scope`: the builder needed files the
# contract denies. Grinding cannot help, so the loop ends after that round; the
# outer loop (delivery_loop) then goes round from design, which owns the scope.
print_test_section "SPEC-6: a denied scope request ends the build loop after one round"
_BUILD_SCOPE_REQUEST='{"files":[{"path":"tests/unit/other-test.sh","category":"collateral_tests","evidence":"","reason":"named in test feedback"}]}'
_GA_VERDICT="fail"
_run_cycle "scope-rb"
assert_eq "[SPEC-6] the loop ends blocked_on_scope (rc=1, outcome interrupted; was rc=7)" \
    "1 interrupted" "$_RUN_RC ${_CYCLE_LAST_OUTCOME:-unset}"
assert_eq "[SPEC-6] after ONE iteration — no grinding" "1" "${_CYCLE_LAST_ITERATIONS:-}"
assert_eq "[SPEC-6] …with its reason" "blocked_on_scope" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "[SPEC-6] the denial itself is still recorded" "1" \
    "$(grep -c '"cycle.scope.denied"' "$ZBUILD_EVENTS_JSONL" || true)"
_BUILD_SCOPE_REQUEST=""

cleanup_test_env
print_test_results
exit $((FAIL > 0))
