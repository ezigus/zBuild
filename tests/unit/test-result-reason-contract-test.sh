#!/usr/bin/env bash
# Tests: plugins/tool/test/plugin.sh — `reason` is mandatory in the v2 result (#2050).
#
# test-results.json declares result_contract: 2. Since #1821 the reader treats a
# missing/empty `reason` as a STRUCTURAL failure and returns raw `error`
# (core/pipeline/verdict.sh:382-388,423) — which _cycle_detect_blocked halts on.
# So a red suite that omits `reason` is reported as a broken stage rather than a
# failing one, and build_test_cycle terminates `blocked` on iteration 1 instead
# of handing the failures back to build (run 33720837199).
#
# These SPECs drive the REAL writer into the REAL reader: whatever
# _test_write_result puts on disk is what runner_read_stage_verdict classifies,
# against the test plugin's own shipped manifest. No fixture stands in between.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test plugin — mandatory v2 reason (#2050)"

setup_test_env "test-result-reason-contract"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"
# SPEC-8 drives the halt decision itself, so the predicate that ended run
# 33720837199 is the real one, not a restatement of it.
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
ART_DIR="$STATE_DIR/artifacts"
RESULT="$ART_DIR/test-results.json"
# The stage's own shipped manifest — the `${artifact_dir}` template, the
# `primary: true` marker and the declared type all come from the real file, so a
# manifest change that breaks this contract surfaces here too.
TEST_MANIFEST="$REPO_ROOT/plugins/tool/test/manifest.yaml"
mkdir -p "$ART_DIR"

_reason_of() { jq -r '.reason // ""' "$RESULT" 2>/dev/null || true; }

# Classify the result currently on disk through the live reader. rc=0 so the
# `rc always wins` short-circuit cannot mask what the artifact says: a red suite
# reaches the cycle with rc=0 because the test plugin returns 0 and reports the
# failure through the verdict (plugin.sh:556).
_classify() { runner_read_stage_verdict "$STATE_DIR" "$TEST_MANIFEST" "test" 0; }

# Count contract-violation events appended since line <from>. Always prints a
# number — an early `return` with no output would compare as "" and read as a
# failure regardless of what the engine did.
_violations_since() {
    local from="$1" n
    [[ -f "$ZBUILD_EVENTS_JSONL" ]] || { printf '0'; return 0; }
    n="$(tail -n "+$((from + 1))" "$ZBUILD_EVENTS_JSONL" \
        | grep -c 'stage.verdict.contract_violation')" || n=0
    printf '%s' "${n:-0}"
}

_event_count() {
    [[ -f "$ZBUILD_EVENTS_JSONL" ]] || { printf '0'; return 0; }
    wc -l < "$ZBUILD_EVENTS_JSONL" | tr -d ' '
}

# ─── [SPEC-1] a plain failing suite ──────────────────────────────────────────
# The live shape from run 33720837199: parser recognized the runner, one test
# failed, no special-case reason applies. This is the arm that halted the cycle.
print_test_section "SPEC-1 — a red suite is a failing stage, not a broken one"

rm -f "$RESULT"
_ev0="$(_event_count)"
_test_write_result "$RESULT" "fail" "complete" 1 670 1 \
    "unit 400/400 · e2e 7/8 · FAIL: e2e (exit 1)" "false" "npm test" "" "full"

_r1="$(_reason_of)"
if [[ -n "$_r1" ]]; then
    assert_pass "[SPEC-1] failing suite writes a non-empty reason (got: $_r1)"
else
    assert_fail "[SPEC-1] failing suite writes a non-empty reason" \
        "reason absent or empty; result=$(cat "$RESULT" 2>/dev/null | head -c 200)"
fi

assert_eq "[SPEC-1] the reader classifies a red suite as fail, not error" \
    "fail" "$(_classify)"

assert_eq "[SPEC-1] no contract violation is emitted for a red suite" \
    "0" "$(_violations_since "$_ev0")"

# ─── [SPEC-2] a passing suite ────────────────────────────────────────────────
# Same omission, same downgrade. It never halted a run only because the cycle
# evaluates convergence before _cycle_detect_blocked — the artifact is wrong on
# the green path too, and any consumer reading it directly sees `error`.
print_test_section "SPEC-2 — a green suite is a passing stage"

rm -f "$RESULT"
_ev0="$(_event_count)"
_test_write_result "$RESULT" "pass" "complete" 0 671 0 \
    "unit 400/400 · integration 238/238" "false" "npm test" "" "full"

_r2="$(_reason_of)"
if [[ -n "$_r2" ]]; then
    assert_pass "[SPEC-2] passing suite writes a non-empty reason (got: $_r2)"
else
    assert_fail "[SPEC-2] passing suite writes a non-empty reason" \
        "reason absent or empty; result=$(cat "$RESULT" 2>/dev/null | head -c 200)"
fi

assert_eq "[SPEC-2] the reader classifies a green suite as pass" \
    "pass" "$(_classify)"

assert_eq "[SPEC-2] no contract violation is emitted for a green suite" \
    "0" "$(_violations_since "$_ev0")"

# ─── [SPEC-3] the derived reason states what the stage observed ──────────────
# ADR-054 §5: a result that cannot explain itself to an operator is incomplete.
# A placeholder token would satisfy the reader's presence check while telling an
# operator nothing, so the counts must survive into the reason.
print_test_section "SPEC-3 — the derived reason carries the counts"

# Matched whole, not by substring: "1" alone occurs inside "671", so a
# substring check would still pass if the writer reported the wrong count.
assert_eq "[SPEC-3] a red suite's reason names failed-of-total" \
    "1 of 671 tests failed" "$_r1"
assert_eq "[SPEC-3] a green suite's reason names passed-of-total" \
    "671 of 671 tests passed" "$_r2"

# ─── [SPEC-7] positive control — the detector this rests on actually fires ───
# SPEC-1/SPEC-2 assert an ABSENCE, which passes for free if the reader never
# emits or the counter never counts. Strip `reason` back off a conformant result
# and the violation must reappear, with the verdict downgraded to `error` — the
# exact pair observed in run 33720837199. Without this the green above is inert.
print_test_section "SPEC-7 — stripping the reason reproduces the halt"

_test_write_result "$RESULT" "fail" "complete" 1 670 1 \
    "some output" "false" "npm test" "" "full"
jq 'del(.reason)' "$RESULT" > "$RESULT.stripped" && mv "$RESULT.stripped" "$RESULT"

_ev0="$(_event_count)"
assert_eq "[SPEC-7] a result with no reason is classified error" \
    "error" "$(_classify)"
assert_eq "[SPEC-7] a result with no reason emits one contract violation" \
    "1" "$(_violations_since "$_ev0")"

# An empty-string reason is the same structural failure as an absent one — the
# reader checks length, so a writer that emitted `reason: ""` would satisfy a
# naive has() check and still halt the cycle.
jq '.reason = ""' "$RESULT" > "$RESULT.empty" && mv "$RESULT.empty" "$RESULT"
assert_eq "[SPEC-7] an empty-string reason is classified error too" \
    "error" "$(_classify)"

# ─── [SPEC-4 guard] explicit reasons are untouched ───────────────────────────
# #485 silent_failure, #584 summary_unavailable and missing_diff_patch are the
# three reasons callers pass today. A default must not overwrite them.
print_test_section "SPEC-4 (guard) — an explicit reason still wins"

for _case in "silent_failure:error:broken:0:0:0" \
             "summary_unavailable:error:broken:1:null:null" \
             "missing_diff_patch:error:broken:2:0:0"; do
    IFS=':' read -r _want _v _d _rc _p _f <<< "$_case"
    rm -f "$RESULT"
    _test_write_result "$RESULT" "$_v" "$_d" "$_rc" "$_p" "$_f" \
        "" "false" "npm test" "$_want" "full"
    assert_eq "[SPEC-4 guard] explicit reason '$_want' is preserved verbatim" \
        "$_want" "$(_reason_of)"
done

# ─── [SPEC-5] adversarial input still yields a conformant result ─────────────
# #626's sanitizers absorb control chars, a non-boolean flag and a malformed
# timing blob, so the NORMAL writer runs — this is not the jq fallback branch
# (that one hardcodes reason=result_write_failed and is covered by
# test-plugin-result-write-fallback-test.sh:189). The point here is that the
# mandatory field survives the sanitizer path too, not only the clean one.
print_test_section "SPEC-5 — a sanitized write still carries a reason"

rm -f "$RESULT"
_test_write_result "$RESULT" "fail" "complete" 1 670 1 \
    "$(printf 'ctrl\x01chars')" "not-a-bool" 'weird `cmd` "quoted"' "" "full" \
    "{{{malformed" >/dev/null 2>&1 || true

if jq empty "$RESULT" >/dev/null 2>&1; then
    assert_pass "[SPEC-5] the result is valid JSON under adversarial input"
else
    assert_fail "[SPEC-5] the result is valid JSON under adversarial input" \
        "content: $(head -c 200 "$RESULT" 2>/dev/null || echo MISSING)"
fi

if [[ -n "$(_reason_of)" ]]; then
    assert_pass "[SPEC-5] a sanitized write carries a non-empty reason"
else
    assert_fail "[SPEC-5] a sanitized write carries a non-empty reason" \
        "result=$(cat "$RESULT" 2>/dev/null | head -c 200)"
fi

# ─── [SPEC-6 guard] mandatory v2 fields are all present ──────────────────────
# The reader checks verdict, disposition and reason as one set. Assert the whole
# set so a future edit cannot fix `reason` by dropping a sibling.
print_test_section "SPEC-6 (guard) — every mandatory v2 field is present"

rm -f "$RESULT"
_test_write_result "$RESULT" "fail" "complete" 1 670 1 \
    "some output" "false" "npm test" "" "full"

for _field in verdict disposition reason; do
    if jq -e --arg f "$_field" \
        'has($f) and (.[$f] | type == "string") and (.[$f] | length > 0)' \
        "$RESULT" >/dev/null 2>&1; then
        assert_pass "[SPEC-6 guard] '$_field' is present and non-empty"
    else
        assert_fail "[SPEC-6 guard] '$_field' is present and non-empty" \
            "result=$(cat "$RESULT" 2>/dev/null | head -c 300)"
    fi
done

assert_eq "[SPEC-6 guard] result_contract is still 2" \
    "2" "$(jq -r '.result_contract // ""' "$RESULT" 2>/dev/null || true)"

# ─── [SPEC-8] the whole chain: writer → reader → halt decision ───────────────
# The bug's consequence was never the JSON — it was build_test_cycle giving up
# on iteration 1. Run the real writer into the real reader into the real
# predicate and assert the cycle keeps iterating on a red suite. Both arms are
# asserted so the pass cannot come from a predicate that never fires.
print_test_section "SPEC-8 — a red suite lets the cycle iterate"

_CYCLE_TRAP_CYCLE_ID="test-2050"
_CYCLE_TRAP_ITER=1
_CYCLE_STAGES=(build test)
_CYCLE_UNTIL_VALUE="pass"

# rc 0 = blocked (terminate now), rc 1 = not blocked (keep iterating).
_blocked_rc_for() {
    local verdict="$1" rc
    set +e
    _cycle_detect_blocked \
        "{\"build\":{\"verdict\":\"pass\"},\"test\":{\"verdict\":\"$verdict\"}}" 1
    rc=$?
    set -e
    printf '%s' "$rc"
}

rm -f "$RESULT"
_test_write_result "$RESULT" "fail" "complete" 1 670 1 \
    "unit 400/400 · e2e 7/8 · FAIL: e2e (exit 1)" "false" "npm test" "" "full"
assert_eq "[SPEC-8] a red suite does NOT block the cycle (rc=1, keep iterating)" \
    "1" "$(_blocked_rc_for "$(_classify)")"

# Negative control — the production failure, reproduced. Strip the field the
# writer now guarantees and the same chain terminates the cycle.
jq 'del(.reason)' "$RESULT" > "$RESULT.stripped" && mv "$RESULT.stripped" "$RESULT"
assert_eq "[SPEC-8] with no reason the same chain blocks (rc=0, run 33720837199)" \
    "0" "$(_blocked_rc_for "$(_classify)")"

print_test_results
