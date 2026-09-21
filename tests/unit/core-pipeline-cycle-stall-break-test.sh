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
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build_test_cycle feedback edge + no-progress stall-break (#1117)"
setup_test_env "cycle-stall-break-1117"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
: > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# ─── SPEC-2 (parse + producer resolution) ────────────────────────────────────
# #1979: the edge is retired, so this now asserts its ABSENCE plus the surviving
# invariant — the producer's artifact is still resolvable by output id, which is
# what the summaries collector depends on.
print_test_section "SPEC-2: no feedback edge, and the producer still resolves"

# #1979: the gate-aggregator→build edge is retired. gate-feedback.md reaches
# build as an engine-collected summary (#1976) instead of a template wire plus a
# bespoke reader, so build_test_cycle declares no feedback edge at all.
#
# The invariant that MATTERS is not the edge — it is that the payload is still
# resolvable from the producer that writes it. That is what the resolution
# assertion below pins, and it is unchanged by the rewiring.
assert_eq "[SPEC-2] simple.yaml build_test_cycle declares no feedback edge" \
    "" \
    "${_TPL_CYCLE_FEEDBACK_build_test_cycle:-}"

_RESOLVE_DIR="$TEST_TEMP_DIR/resolve"
mkdir -p "$_RESOLVE_DIR"
# #1988: gate_feedback is retired — the aggregator renders nothing. The
# surviving invariant is that a GATE's own detail resolves by output id, which
# is what the summaries collector depends on.
set +e
_resolved_src="$(_cycle_resolve_from_path "$_RESOLVE_DIR" "test" "test_failures_summary")"
set -e
case "$_resolved_src" in
    */test-failures-summary.md)
        assert_pass "[SPEC-2] a gate's own detail resolves by output id" ;;
    *)
        assert_fail "[SPEC-2] a gate's own detail resolves by output id" \
            "got: $_resolved_src" ;;
esac

# ─── SPEC-1 (feedback delivery) ──────────────────────────────────────────────
print_test_section "SPEC-1: a failing gate\x27s detail reaches the prompt"

_CYCLE_TRAP_CYCLE_ID="build_test_cycle"
# #1979: the payload no longer travels a feedback wire. It reaches build as an
# engine-collected summary, so the surviving invariant — "a failing gate's
# detail actually arrives" — is asserted on THAT path. Deleting this rather than
# re-pointing it would have removed the only proof the cycle can still converge.
FB_STATE="$TEST_TEMP_DIR/fb-state"
mkdir -p "$FB_STATE/artifacts"
cat > "$FB_STATE/artifacts/test-failures-summary.md" <<'TFS'
# Gate Aggregator Feedback
## suite
- failures:
    - tests/unit/example-test.sh: assert_eq "[SPEC-3] foo" expected=3 actual=2 FAILED
TFS
cat > "$FB_STATE/pipeline-state.json" <<'TFS'
{"schema_version":1,
 "stage_statuses":{"test":"failed"},
 "stage_verdicts":{"test":"fail"}}
TFS

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

_TPL_STAGES=(test)
_SUMMARY_BLOCK="$(stage_summaries_prompt_block "$FB_STATE/pipeline-state.json" \
    "$REPO_ROOT/plugins" 2>/dev/null || true)"

[[ -n "$_SUMMARY_BLOCK" ]] \
    && assert_pass "[SPEC-1] a failing gate contributes a summary" \
    || assert_fail "[SPEC-1] a failing gate contributes a summary" "block was empty"
assert_contains "[SPEC-1] the failure detail reaches the prompt" \
    "$_SUMMARY_BLOCK" "[SPEC-3] foo"
assert_contains "[SPEC-1] and it is framed as blocking, not passive context" \
    "$_SUMMARY_BLOCK" "RESOLVE"

# ─── SPEC-3 / SPEC-4 (stall-break vs converge) ───────────────────────────────
# Drive the REAL cycle_orchestrator_run with a stubbed dispatch hook. build always
# emits empty_diff; every mechanical gate passes; the gate-aggregator (the cycle's
# exit_when stage after the B6 #1138 cutover) verdict is parameterized.
_GA_VERDICT="fail"
# shellcheck disable=SC2317
cycle_dispatch_stage() {
    local _st_stage="$1" _st_iter="$2" _st_state_file="$3"
    local _st_dir; _st_dir="$(dirname "$_st_state_file")"
    local _art="$_st_dir/artifacts"; mkdir -p "$_art"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_VERDICT_RAW="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""
    case "$_st_stage" in
        build)
            # ADR-054: new format — verdict=pass + disposition=complete + data.build_kind=empty_diff
            printf '{"schema_version":1,"result_contract":2,"verdict":"pass","disposition":"complete","data":{"build_kind":"empty_diff"},"iterations":1,"terminated_reason":"done_sentinel","files_changed":[]}' \
                > "$_art/build-summary.json"
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            _CYCLE_DISPATCH_DISPOSITION="complete"
            _CYCLE_DISPATCH_DATA_KIND="empty_diff"
            ;;
        test)
            printf '{"result_contract":2,"verdict":"%s","disposition":"complete","reason":"mock","data":{"exit_code":0,"passed":1,"failed":0}}' "${_TEST_VERDICT:-pass}" \
                > "$_art/test-results.json"
            _CYCLE_DISPATCH_VERDICT="${_TEST_VERDICT:-pass}"
            _CYCLE_DISPATCH_VERDICT_RAW="${_TEST_VERDICT:-pass}"
            # v2: a failing suite is verdict=fail with rc 0 (rc 1 = broken).
            ;;
        acceptance-gate)
            _CYCLE_DISPATCH_VERDICT="${_AG_VERDICT:-pass}"
            _CYCLE_DISPATCH_VERDICT_RAW="${_AG_VERDICT:-pass}"
            ;;
        gate-aggregator)
            printf '{"schema_version":1,"verdict":"%s","summary":"x"}' "$_GA_VERDICT" \
                > "$_art/gate-aggregator-result.json"
            _CYCLE_DISPATCH_VERDICT="$_GA_VERDICT"
            _CYCLE_DISPATCH_VERDICT_RAW="$_GA_VERDICT"
            _CYCLE_DISPATCH_FAULT="${_GA_FAULT:-}"
            ;;
        *)
            # shape-floor, acceptance-gate, secret-scan: all pass (verdict
            # defaults set above) so only the aggregator gates. (#1129 Change C
            # dropped lint/coverage/mutation as cycle members.)
            :
            ;;
    esac
    return 0
}

_run_cycle() {
    local _label="$1"
    local _sd="$TEST_TEMP_DIR/run-$_label/state"
    mkdir -p "$_sd/artifacts"
    printf '{"schema_version":1,"status":"in_progress"}' > "$_sd/pipeline-state.json"
    : > "$ZBUILD_EVENTS_JSONL"
    set +e
    cycle_orchestrator_run "build_test_cycle" "$_sd" "$_sd/pipeline-state.json"
    _RUN_RC=$?
    set -e
}

# #1208: the #1117 empty-diff STALL-BREAK was REMOVED. "Run all tries": an
# empty_diff that never converges no longer terminates early — the cycle uses ALL
# its iterations (each cheap: build self-yields on an empty diff) and then
# terminates by-severity. Here the mock's `test` stage passes (gate-aggregator
# fails), so exhaustion routes to rc=2 (unconverged→review, reason
# max_iterations), NOT the old reason=stalled / ≤2-iter early break.
print_test_section "SPEC-3: empty_diff + gate!=pass ⇒ runs ALL iters → rc=2 (no early stall-break, #1208)"
_GA_VERDICT="fail"
_run_cycle "stall"
assert_eq "[SPEC-3] cycle rc=2 (unconverged→review)" "2" "$_RUN_RC"
assert_eq "[SPEC-3] terminated reason is max_iterations (not stalled — early break removed)" \
    "max_iterations" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "[SPEC-3] ran ALL 5 iterations (no early terminator)" "5" "${_CYCLE_LAST_ITERATIONS:-}"
if grep -q 'cycle.stalled' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-3] no cycle.stalled event (stall-break removed)" "cycle.stalled emitted"
else
    assert_pass "[SPEC-3] no cycle.stalled event (stall-break removed)"
fi
# #2117: the iterations still all RUN, but an unchanged tree is not
# re-VERIFIED. After build reports empty_diff on a fingerprint the previous
# iteration already verified, every member that PASSED then is reused from
# that iteration; a member that FAILED re-runs (its iter-aware escalation
# needs to see ZBUILD_CYCLE_ITER advance). #1840 spent 45 min of tests and
# 68 min of gate on each of three identical trees.
_n_test="$(grep -c '"cycle.member.dispatch.complete".*"member":"test"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-3b] the passing test member is dispatched exactly ONCE across 5 iterations" "1" "$_n_test"
assert_eq "[SPEC-3c] iterations 2–5 reuse the test member's verdict (4 reuse events)" \
    "4" "$(grep '"cycle.iteration.reused"' "$ZBUILD_EVENTS_JSONL" | grep -c '"member":"test"' || true)"
assert_contains "[SPEC-3c] a reuse event names the iteration it reuses" \
    "$(grep '"cycle.iteration.reused"' "$ZBUILD_EVENTS_JSONL" | head -1)" '"from_iter":"1"'
_n_ga="$(grep -c '"cycle.member.dispatch.complete".*"member":"gate-aggregator"' "$ZBUILD_EVENTS_JSONL" || true)"
# #2170: a failing member on an unchanged tree is reused like a passing one
# (was: re-dispatched every iteration — the 25-minute suite ran five times to
# fail identically on #1841).
assert_eq "[SPEC-3d] the FAILING gate-aggregator is dispatched once and reused on an unchanged tree" "1" "$_n_ga"

print_test_section "SPEC-3f: a tree that CHANGED between iterations is fully re-verified"
_GA_VERDICT="fail"
# The orchestrator reads the fingerprint inside a $( ), so the stub cannot
# keep a counter in shell state — a file does.
_FP_COUNTER="$TEST_TEMP_DIR/fp.count"; : > "$_FP_COUNTER"
if declare -F _cycle_tree_fingerprint >/dev/null 2>&1; then
    eval "$(declare -f _cycle_tree_fingerprint | sed '1s/^_cycle_tree_fingerprint/_orig_cycle_tree_fingerprint/')"
fi
_cycle_tree_fingerprint() { printf 'x\n' >> "$_FP_COUNTER"; printf 'fp-%s' "$(wc -l < "$_FP_COUNTER" | tr -d ' ')"; }
_run_cycle "changed"
assert_eq "[SPEC-3f] with a different fingerprint each iteration nothing is reused" \
    "0" "$(grep -c '"cycle.iteration.reused"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-3f] the test member ran every iteration (5)" \
    "5" "$(grep -c '"cycle.member.dispatch.complete".*"member":"test"' "$ZBUILD_EVENTS_JSONL" || true)"
if declare -F _orig_cycle_tree_fingerprint >/dev/null 2>&1; then
    eval "$(declare -f _orig_cycle_tree_fingerprint | sed '1s/^_orig_cycle_tree_fingerprint/_cycle_tree_fingerprint/')"
else
    unset -f _cycle_tree_fingerprint
fi

# #2119: a gate that declares `fault: specification` has said whose problem
# this is. The route_back edge used to be evaluated only at exhaustion (term_rc
# 2/8), so the cycle burned every remaining iteration re-failing the same
# gate before design got the rewind. It now fires at the iteration the fault
# appears, while the edge's budget lasts.
print_test_section "SPEC-11 [#2119]: a specification fault routes back at the iteration it appears"
_GA_VERDICT="fail"; _GA_FAULT="specification"
_run_cycle "early-rb"
assert_eq "[SPEC-11] the cycle returns route_back (rc=11)" "11" "$_RUN_RC"
assert_eq "[SPEC-11] after ONE iteration, not at exhaustion" "1" "${_CYCLE_LAST_ITERATIONS:-}"
assert_eq "[SPEC-11] cycle.route_back.early emitted" "1" "$(grep -c '"cycle.route_back.early"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[SPEC-11] the rewind target is the design cycle" "design_verify_cycle" "${_CYCLE_ROUTE_BACK_TO:-}"
_GA_FAULT=""

print_test_section "SPEC-4/SPEC-10: empty_diff + gate=pass ⇒ converged (no false stall)"
_GA_VERDICT="pass"
_run_cycle "converge"
assert_eq "[SPEC-4] cycle rc=0 (converged)" "0" "$_RUN_RC"
assert_eq "[SPEC-4] terminated reason is converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "[SPEC-4] converges at iter 1 (single-pass empty_diff NOT misclassified)" \
    "1" "${_CYCLE_LAST_ITERATIONS:-}"
# [SPEC-10] (#1832, ADR-054 §6): no_committed_changes exemption reads _build_kind (not _build_verdict).
# build stub writes verdict=pass + data.build_kind=empty_diff; old code checked _build_verdict!="empty_diff"
# → "pass" != "empty_diff" → would fire no_committed_changes; new code checks _build_kind → EXEMPT.
# (Guard: this cycle has no intake-baseline-ref.txt, so _cycle_no_commits_ahead fails-soft; the guard
# confirms the converge path reaches rc=0 without interference.)
assert_eq "[SPEC-10] empty_diff via kind field (verdict=pass) converges cleanly — kind-based exemption" \
    "0" "$_RUN_RC"
if grep -q 'cycle.stalled' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-4] no cycle.stalled event on a clean converge" "cycle.stalled emitted"
else
    assert_pass "[SPEC-4] no cycle.stalled event on a clean converge"
fi

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
assert_eq "[SPEC-5] the cycle still ends as it does today — max iterations with tests failing (rc=8)" "8" "$_RUN_RC"
assert_contains "[SPEC-5] …with that reason" "$(tail -3 "$ZBUILD_EVENTS_JSONL")" "max_iterations_tests_failing"
_TEST_VERDICT="pass"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
