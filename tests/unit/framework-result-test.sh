#!/usr/bin/env bash
# Tests: scripts/lib/framework-result.sh + plugins/tool/test/plugin.sh
# ADR-040 / #1133 — shared test-framework result (lint + coverage + mutation).
#
# Covers the lib functions (lint pass/fail/skipped; coverage measured/skipped/
# error/below-floor; mutation parse) and the ADDITIVE, opt-in integration into
# test-results.json: the new blocks appear under opt-in and are OMITTED by
# default (default writer output stays byte-unchanged).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "framework-result: lint/coverage/mutation + opt-in test-results.json (#1133)"

setup_test_env "framework-result"

# Isolated event bus so plugin.sh's emit_event calls are inert.
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

ARTIFACT_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"

# Sourcing plugin.sh also sources scripts/lib/framework-result.sh (the lib under
# test) and gives us _test_write_result / _test_framework_enabled.
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"

# ─── 1. framework_run_lint: pass ──────────────────────────────────────────────
print_test_section "1. lint pass (rc=0)"

LINT_PASS="$(ZBUILD_LINT_CMD="true" framework_run_lint)"
assert_json_key "lint pass: status" "$LINT_PASS" ".status" "pass"
assert_json_key "lint pass: exit_code" "$LINT_PASS" ".exit_code" "0"

# ─── 2. framework_run_lint: fail ──────────────────────────────────────────────
print_test_section "2. lint fail (rc!=0 captures exit_code + summary)"

LINT_FAIL="$(ZBUILD_LINT_CMD="bash -c 'echo lint-broke >&2; exit 3'" framework_run_lint)"
assert_json_key "lint fail: status" "$LINT_FAIL" ".status" "fail"
assert_json_key "lint fail: exit_code" "$LINT_FAIL" ".exit_code" "3"
assert_contains "lint fail: summary carries output" \
    "$(echo "$LINT_FAIL" | jq -r '.summary')" "lint-broke"

# ─── 3. framework_run_lint: skipped (explicitly empty cmd) ────────────────────
print_test_section "3. lint skipped (ZBUILD_LINT_CMD empty)"

LINT_SKIP="$(ZBUILD_LINT_CMD="" framework_run_lint)"
assert_json_key "lint skip: status" "$LINT_SKIP" ".status" "skipped"
assert_json_key "lint skip: exit_code null" "$LINT_SKIP" ".exit_code" "null"

# ─── 4. framework_run_coverage: measured ──────────────────────────────────────
print_test_section "4. coverage measured (Total: line, rc=0)"

COV_MEAS="$(ZBUILD_COVERAGE_CMD="echo 'Total: 50/100 lines (50.0%)'" \
            ZBUILD_COVERAGE_FLOOR=29 framework_run_coverage)"
assert_json_key "coverage measured: status" "$COV_MEAS" ".status" "measured"
assert_json_key "coverage measured: pct" "$COV_MEAS" ".pct" "50.0"
assert_json_key "coverage measured: floor" "$COV_MEAS" ".floor" "29"

# ─── 5. framework_run_coverage: skipped (explicitly empty cmd) ────────────────
print_test_section "5. coverage skipped (ZBUILD_COVERAGE_CMD empty)"

COV_SKIP="$(ZBUILD_COVERAGE_CMD="" framework_run_coverage)"
assert_json_key "coverage skip: status" "$COV_SKIP" ".status" "skipped"
assert_json_key "coverage skip: pct null" "$COV_SKIP" ".pct" "null"

# ─── 6. framework_run_coverage: error (instrumentation rc=2) ──────────────────
print_test_section "6. coverage error (rc=2 instrumentation failure)"

COV_ERR="$(ZBUILD_COVERAGE_CMD="exit 2" framework_run_coverage)"
assert_json_key "coverage error: status" "$COV_ERR" ".status" "error"

# ─── 7. framework_run_coverage: below floor (rc=1) ────────────────────────────
print_test_section "7. coverage below_floor (rc=1, pct<floor)"

COV_LOW="$(ZBUILD_COVERAGE_CMD="echo 'Total: 5/100 lines (5.0%)'; exit 1" \
           ZBUILD_COVERAGE_FLOOR=29 framework_run_coverage)"
assert_json_key "coverage below: status" "$COV_LOW" ".status" "below_floor"
assert_json_key "coverage below: pct" "$COV_LOW" ".pct" "5.0"
assert_json_key "coverage below: floor" "$COV_LOW" ".floor" "29"

# ─── 8. framework_parse_mutation: measured + skipped ──────────────────────────
print_test_section "8. mutation parse (present → measured, absent → skipped)"

MUT_RAW="$(printf 'unit: 10/10 passed\nmutation: 18/20 passed\n')"
MUT_MEAS="$(framework_parse_mutation "$MUT_RAW")"
assert_json_key "mutation present: status" "$MUT_MEAS" ".status" "measured"
assert_json_key "mutation present: score" "$MUT_MEAS" ".score" "18/20"

MUT_SKIP="$(framework_parse_mutation "$(printf 'unit: 10/10 passed\n')")"
assert_json_key "mutation absent: status" "$MUT_SKIP" ".status" "skipped"
assert_json_key "mutation absent: score null" "$MUT_SKIP" ".score" "null"

# ─── 9. _test_framework_enabled gating ────────────────────────────────────────
print_test_section "9. opt-in gate (_test_framework_enabled)"

( unset ZBUILD_FRAMEWORK_RESULT ZBUILD_LINT_CMD ZBUILD_COVERAGE_CMD
  _test_framework_enabled ) \
    && assert_fail "gate: disabled when nothing configured" \
    || assert_pass "gate: disabled when nothing configured"

( ZBUILD_FRAMEWORK_RESULT=1 _test_framework_enabled ) \
    && assert_pass "gate: enabled by ZBUILD_FRAMEWORK_RESULT=1" \
    || assert_fail "gate: enabled by ZBUILD_FRAMEWORK_RESULT=1"

( unset ZBUILD_FRAMEWORK_RESULT; ZBUILD_LINT_CMD="eslint ." _test_framework_enabled ) \
    && assert_pass "gate: auto-enabled when a *_CMD is configured" \
    || assert_fail "gate: auto-enabled when a *_CMD is configured"

# ─── 10. test-results.json carries the blocks under opt-in ────────────────────
print_test_section "10. test-results.json carries lint/coverage/mutation (opt-in)"

OPT_OUT="$ARTIFACT_DIR/results-optin.json"
_test_write_result "$OPT_OUT" "pass" 0 10 0 "ok" "true" "npm test" "" "full" \
    "" "deadbeef" "$LINT_PASS" "$COV_MEAS" "$MUT_MEAS"

assert_file_exists "optin: results written" "$OPT_OUT"
jq empty "$OPT_OUT" >/dev/null 2>&1 \
    && assert_pass "optin: valid JSON" \
    || assert_fail "optin: valid JSON" "$(head -c 200 "$OPT_OUT")"
assert_json_key "optin: .lint.status" "$(cat "$OPT_OUT")" ".lint.status" "pass"
assert_json_key "optin: .coverage.status" "$(cat "$OPT_OUT")" ".coverage.status" "measured"
assert_json_key "optin: .coverage.pct" "$(cat "$OPT_OUT")" ".coverage.pct" "50.0"
assert_json_key "optin: .mutation.score" "$(cat "$OPT_OUT")" ".mutation.score" "18/20"

# ─── 11. default writer OMITS the blocks (byte-unchanged) ──────────────────────
print_test_section "11. default path omits the blocks + stays byte-unchanged"

# Baseline: the pre-#1133 12-arg call shape (no framework args).
BASE_OUT="$ARTIFACT_DIR/results-base.json"
_test_write_result "$BASE_OUT" "pass" 0 10 0 "ok" "true" "npm test" "" "full" "" "deadbeef"

assert_eq "default: .lint absent" "false" \
    "$(jq 'has("lint")' "$BASE_OUT" 2>/dev/null)"
assert_eq "default: .coverage absent" "false" \
    "$(jq 'has("coverage")' "$BASE_OUT" 2>/dev/null)"
assert_eq "default: .mutation absent" "false" \
    "$(jq 'has("mutation")' "$BASE_OUT" 2>/dev/null)"

# Passing EMPTY framework args (the disabled-opt-in path) must produce a
# byte-identical artifact to the bare 12-arg call.
EMPTY_OUT="$ARTIFACT_DIR/results-empty.json"
_test_write_result "$EMPTY_OUT" "pass" 0 10 0 "ok" "true" "npm test" "" "full" "" "deadbeef" "" "" ""

if cmp -s "$BASE_OUT" "$EMPTY_OUT"; then
    assert_pass "default: empty framework args are byte-identical to baseline"
else
    assert_fail "default: empty framework args are byte-identical to baseline" \
        "$(diff "$BASE_OUT" "$EMPTY_OUT" 2>&1 | head -c 300)"
fi

print_test_results
exit $((FAIL > 0))
