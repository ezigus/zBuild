#!/usr/bin/env bash
# Tests: scripts/lib/llm-agent.sh — framework foundation (#798, ADR-028 PR 1/5)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# Stub emit_event since the framework calls it.
emit_event() { return 0; }

# shellcheck source=../../scripts/lib/llm-agent.sh
source "$REPO_ROOT/scripts/lib/llm-agent.sh"

print_test_header "LLM-agent framework foundation (#798)"

# ─── _llm_output_contract ────────────────────────────────────────────────────
# C1: required args
set +e
out="$(_llm_output_contract --schema-json '{}' 2>&1)"; rc=$?
set -e
assert_eq "C1: missing --stage → rc=2" "2" "$rc"

# C2: basic render contains canonical opening
out="$(_llm_output_contract --stage impact --verdicts complete,incomplete --schema-json '{"v":1}')"
assert_contains "C2: contains OUTPUT CONTRACT header" "$out" "OUTPUT CONTRACT"
assert_contains "C2: contains 'begins with' rule" "$out" "first output character MUST be"
assert_contains "C2: contains FORBIDDEN list" "$out" "FORBIDDEN"
assert_contains "C2: contains FINAL RULE" "$out" "FINAL RULE"
assert_contains "C2: schema inlined" "$out" '"v":1'

# C3: verdict enum line present when verdicts != "none"
assert_contains "C3: verdict enum line for impact" "$out" '`.verdict` field MUST be one of: complete,incomplete'

# C4: verdict enum line OMITTED when verdicts=none (plan)
out_plan="$(_llm_output_contract --stage plan --verdicts none --schema-json '{}')"
case "$out_plan" in
    *"\`.verdict\`"*) assert_fail "C4: verdicts=none should omit verdict enum line" ;;
    *) assert_pass "C4: verdicts=none omits verdict enum line" ;;
esac

# C5: markdown-fields adds escape requirement
out_md="$(_llm_output_contract --stage test_assessment --verdicts pass,fail --schema-json '{}' --markdown-fields failure_summary_md)"
assert_contains "C5: markdown-fields triggers escape requirement" "$out_md" "JSON-STRING ESCAPING"
assert_contains "C5: cites ADR-022" "$out_md" "ADR-022"
assert_contains "C5: names the field" "$out_md" "failure_summary_md"

# C6: FORBIDDEN list pins all 9 observed phrases
for phrase in 'Based on my analysis' 'Based on my comprehensive analysis' 'Here is' "Here's" 'After reviewing' "I've identified" 'Now I have' 'Let me' 'I have all the information'; do
    assert_contains "C6: FORBIDDEN names '$phrase'" "$out" "$phrase"
done

# ─── _llm_envelope_parse ─────────────────────────────────────────────────────
# P1: missing args
set +e; _llm_envelope_parse "x" 2>/dev/null; rc=$?; set -e
assert_eq "P1: missing prose_var → rc=2" "2" "$rc"

# P2: pure JSON (no prose) → JSON populated, prose empty
json="" prose=""
_llm_envelope_parse '{"verdict":"pass"}' json prose
assert_contains "P2: pure JSON extracted" "$json" '"verdict":"pass"'
assert_eq "P2: prose empty for pure JSON" "" "$prose"

# P3: prose-prefixed JSON → both extracted
json="" prose=""
_llm_envelope_parse 'Based on my analysis... {"v":1}' json prose
assert_contains "P3: JSON extracted from prefixed" "$json" '"v":1'
assert_contains "P3: prose captured" "$prose" "Based on my analysis"

# P4: empty input → both empty, no error
json="" prose=""
_llm_envelope_parse "" json prose
assert_eq "P4: empty input → empty json" "" "$json"
assert_eq "P4: empty input → empty prose" "" "$prose"

# ─── _llm_envelope_validate ──────────────────────────────────────────────────
# V1: valid JSON + valid structure
err=""
set +e; _llm_envelope_validate '{"schema_version":1,"verdict":"pass"}' '.schema_version == 1' err; rc=$?; set -e
assert_eq "V1: valid input → rc=0" "0" "$rc"
assert_eq "V1: valid input → err empty" "" "$err"

# V2: parse-class failure (ADR-022 v2 / column+context)
err=""
set +e; _llm_envelope_validate 'not json at all' '.x' err; rc=$?; set -e
assert_eq "V2: invalid JSON → rc=2 (parse-class)" "2" "$rc"
case "$err" in
    *"parse:"*"column"*) assert_pass "V2: error names 'parse' + 'column'" ;;
    *) assert_fail "V2: expected parse+column in err: $err" ;;
esac

# V3: structure-class failure
err=""
set +e; _llm_envelope_validate '{"schema_version":2}' '.schema_version == 1' err; rc=$?; set -e
assert_eq "V3: bad structure → rc=3 (structure-class)" "3" "$rc"
case "$err" in
    *"structure:"*) assert_pass "V3: error names 'structure'" ;;
    *) assert_fail "V3: expected 'structure' prefix: $err" ;;
esac

# V4: ADR-022 dogfood regression — unescaped `"` inside string field
ADV='{"schema_version":1,"verdict":"fail","failure_summary_md":"text with "3" raw quotes"}'
err=""
set +e; _llm_envelope_validate "$ADV" '.schema_version == 1' err; rc=$?; set -e
assert_eq "V4: ADR-022 unescaped quote → rc=2 (parse-class, not structure)" "2" "$rc"
case "$err" in
    *"parse:"*) assert_pass "V4: ADR-022 regression — diagnosed as parse, not validation" ;;
    *) assert_fail "V4: expected parse-class diagnosis: $err" ;;
esac

# ─── _llm_router_classify ────────────────────────────────────────────────────
# R1: re-export of _router_rc_classify works
verdict="" reason=""
_llm_router_classify 124 verdict reason
assert_eq "R1: rc=124 → verdict=error" "error" "$verdict"
assert_eq "R1: rc=124 → reason=router_timeout" "router_timeout" "$reason"

verdict="" reason=""
_llm_router_classify 137 verdict reason
assert_eq "R2: rc=137 → verdict=error" "error" "$verdict"

verdict="" reason=""
_llm_router_classify 0 verdict reason
assert_eq "R3: rc=0 → verdict empty" "" "$verdict"

# ─── _llm_with_json_output ──────────────────────────────────────────────────
# W1: save/restore around callback
unset ZBUILD_ROUTER_JSON_OUTPUT
_inner() {
    echo "$ZBUILD_ROUTER_JSON_OUTPUT"
}
seen="$(_llm_with_json_output _inner)"
assert_eq "W1: callback sees ZBUILD_ROUTER_JSON_OUTPUT=1" "1" "$seen"
assert_eq "W1: env restored to unset after" "" "${ZBUILD_ROUTER_JSON_OUTPUT-}"

# W2: save/restore preserves caller's value
export ZBUILD_ROUTER_JSON_OUTPUT=0
_inner2() { echo "$ZBUILD_ROUTER_JSON_OUTPUT"; }
seen="$(_llm_with_json_output _inner2)"
assert_eq "W2: callback sees =1 even when caller had =0" "1" "$seen"
assert_eq "W2: caller's value preserved post-callback" "0" "$ZBUILD_ROUTER_JSON_OUTPUT"
unset ZBUILD_ROUTER_JSON_OUTPUT

# W3: rc preserved even on callback failure
_inner3() { return 42; }
set +e; _llm_with_json_output _inner3; rc=$?; set -e
assert_eq "W3: callback rc=42 propagated" "42" "$rc"

# ─── _llm_emit_violation ─────────────────────────────────────────────────────
# E1: positional event_class arg (no env leak between calls)
# Just verify it doesn't crash with various arg shapes.
set +e
_llm_emit_violation impact impact.contract.violation contract_violation 258 /tmp/foo
rc=$?
set -e
assert_eq "E1: full args → rc=0" "0" "$rc"

set +e
_llm_emit_violation impact
rc=$?
set -e
assert_eq "E1: minimal args → rc=0" "0" "$rc"

# ─── CLI failure fast-fail helpers (#1024) ───────────────────────────────────
# Use an isolated temp dir as ZBUILD_STATE_DIR so counter files don't bleed.
_FF_STATE_DIR="$(mktemp -d)"
export ZBUILD_STATE_DIR="$_FF_STATE_DIR"

# Reset helper before each group.
_ff_reset() { _zbuild_reset_cli_fail; }

# FF1 [SPEC-7]: below threshold → _llm_check_cli_fail_abort returns 0 (no abort).
# This is a GUARD: single failure must not trip fast-fail.
_ff_reset
export ZBUILD_LLM_FAIL_THRESHOLD=2
_zbuild_record_cli_fail
set +e; _llm_check_cli_fail_abort; rc=$?; set -e
assert_eq "[SPEC-7] one failure (below threshold=2) → no abort (rc=0)" "0" "$rc"

# FF2 [SPEC-2]: at threshold → _llm_check_cli_fail_abort returns 9 (abort).
# This is a CHANGE: new fast-fail behavior; fails at baseline (function absent).
_ff_reset
_zbuild_record_cli_fail
_zbuild_record_cli_fail
set +e; _llm_check_cli_fail_abort; rc=$?; set -e
assert_eq "[SPEC-2] two failures (at threshold=2) → abort rc=9" "9" "$rc"

# FF3: custom threshold via ZBUILD_LLM_FAIL_THRESHOLD.
_ff_reset
export ZBUILD_LLM_FAIL_THRESHOLD=3
_zbuild_record_cli_fail
_zbuild_record_cli_fail
set +e; _llm_check_cli_fail_abort; rc=$?; set -e
assert_eq "FF3: two failures below threshold=3 → no abort" "0" "$rc"
_zbuild_record_cli_fail
set +e; _llm_check_cli_fail_abort; rc=$?; set -e
assert_eq "FF3: three failures at threshold=3 → abort rc=9" "9" "$rc"
export ZBUILD_LLM_FAIL_THRESHOLD=2

# FF4 [SPEC-5]: abort message includes run_id.
# This is a CHANGE: new terminal message behavior; fails at baseline (function absent).
_ff_reset
export ZBUILD_RUN_ID="test-run-ff4"
_zbuild_record_cli_fail; _zbuild_record_cli_fail
msg="$(_llm_check_cli_fail_abort 2>&1 || true)"
assert_contains "[SPEC-5] abort message contains run_id" "$msg" "test-run-ff4"
assert_contains "[SPEC-5] abort message contains failure count" "$msg" "2"
unset ZBUILD_RUN_ID

# FF5: _zbuild_reset_cli_fail clears counter.
_ff_reset
_zbuild_record_cli_fail; _zbuild_record_cli_fail
_zbuild_reset_cli_fail
set +e; _llm_check_cli_fail_abort; rc=$?; set -e
assert_eq "FF5: reset clears counter — no abort after reset" "0" "$rc"

# Cleanup temp dir.
rm -rf "$_FF_STATE_DIR"
unset ZBUILD_STATE_DIR ZBUILD_LLM_FAIL_THRESHOLD

print_test_results
exit $((FAIL > 0))
