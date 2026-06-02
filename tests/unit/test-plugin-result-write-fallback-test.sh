#!/usr/bin/env bash
# Tests: plugins/tool/test/plugin.sh — _test_write_result defensive fallback (#626).
#
# Wave 10 defense-in-depth on top of #625. The writer must fail-CLOSED:
# test-results.json is ALWAYS written and ALWAYS parseable as JSON, even when
# callers pass adversarial input (whitespace in numeric slots, control chars in
# test_output, embedded quotes/backticks in test_cmd). When jq rejects the
# input, a degenerate-but-valid fallback object is written and a
# `test.result_write.fallback` event is emitted. jq stderr never leaks to the
# terminal.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-plugin _test_write_result defensive fallback (#626)"

setup_test_env "test-plugin-result-write-fallback"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACT_DIR"

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"

# ─── Helper: drive _test_write_result and assert basic invariants ─────────────
# Args: <label> <out_path> <stderr_path> -- <args-to-_test_write_result>
_drive_writer() {
    local label="$1"; shift
    local out="$1"; shift
    local err="$1"; shift
    [[ "$1" == "--" ]] && shift
    _test_write_result "$@" 2>"$err" || true

    assert_file_exists "$label: results file written" "$out"

    if jq empty "$out" >/dev/null 2>&1; then
        assert_pass "$label: results file is valid JSON"
    else
        assert_fail "$label: results file is valid JSON" \
            "jq empty failed; content: $(head -c 200 "$out" 2>/dev/null || echo MISSING)"
    fi

    if grep -qiE 'jq: error|invalid (numeric literal|json|input)|Cannot iterate' "$err"; then
        assert_fail "$label: no jq error leaked to stderr" \
            "stderr: $(cat "$err")"
    else
        assert_pass "$label: no jq error leaked to stderr"
    fi
}

# ─── 1. whitespace `passed` slot (adversarial numeric input) ────────────────
print_test_section "1. whitespace in passed slot triggers fallback"

OUT1="$ARTIFACT_DIR/results-ws-passed.json"
ERR1="$TEST_TEMP_DIR/ws-passed.stderr"
_drive_writer "ws-passed" "$OUT1" "$ERR1" -- \
    "$OUT1" "error" 0 "  " 0 "out" "false" "cmd" "bad_passed"

# Sanitized passed should be null (not 0 — we don't silently coerce garbage).
assert_eq "ws-passed: .passed sanitized to null" "null" \
    "$(jq -r '.passed' "$OUT1" 2>/dev/null)"

# ─── 2. non-numeric `failed` slot (`abc`) ────────────────────────────────────
print_test_section "2. non-numeric failed slot triggers sanitizer"

OUT2="$ARTIFACT_DIR/results-abc-failed.json"
ERR2="$TEST_TEMP_DIR/abc-failed.stderr"
_drive_writer "abc-failed" "$OUT2" "$ERR2" -- \
    "$OUT2" "error" 0 0 "abc" "out" "false" "cmd" "bad_failed"

assert_eq "abc-failed: .failed sanitized to null" "null" \
    "$(jq -r '.failed' "$OUT2" 2>/dev/null)"

# ─── 3. control-char test_output ──────────────────────────────────────────────
print_test_section "3. control-char test_output is accepted, JSON still valid"

OUT3="$ARTIFACT_DIR/results-ctl.json"
ERR3="$TEST_TEMP_DIR/ctl.stderr"
CTL_OUT=$'\x01\x02bad\x03'
_drive_writer "ctl-output" "$OUT3" "$ERR3" -- \
    "$OUT3" "error" 1 0 1 "$CTL_OUT" "false" "cmd"

# ─── 4. embedded-quote test_cmd ───────────────────────────────────────────────
print_test_section "4. embedded quotes/backticks in test_cmd survive"

OUT4="$ARTIFACT_DIR/results-quotes.json"
ERR4="$TEST_TEMP_DIR/quotes.stderr"
EVIL_CMD='"npm" '\''test'\'' `evil`'
_drive_writer "quotes" "$OUT4" "$ERR4" -- \
    "$OUT4" "error" 1 0 1 "" "false" "$EVIL_CMD"

# .test_cmd should round-trip verbatim through jq.
GOT_CMD="$(jq -r '.test_cmd' "$OUT4" 2>/dev/null)"
assert_eq "quotes: .test_cmd round-trips" "$EVIL_CMD" "$GOT_CMD"

# ─── 5. non-bool diff_applied slot ────────────────────────────────────────────
print_test_section "5. non-bool diff_applied is sanitized to false"

OUT5="$ARTIFACT_DIR/results-bad-bool.json"
ERR5="$TEST_TEMP_DIR/bad-bool.stderr"
_drive_writer "bad-bool" "$OUT5" "$ERR5" -- \
    "$OUT5" "error" 0 0 0 "out" "garbage" "cmd"

assert_eq "bad-bool: .diff_applied sanitized to false" "false" \
    "$(jq -r '.diff_applied' "$OUT5" 2>/dev/null)"

# ─── 6. whitespace exit_code slot ─────────────────────────────────────────────
print_test_section "6. whitespace exit_code is sanitized to null"

OUT6="$ARTIFACT_DIR/results-ws-ec.json"
ERR6="$TEST_TEMP_DIR/ws-ec.stderr"
_drive_writer "ws-exit" "$OUT6" "$ERR6" -- \
    "$OUT6" "error" "  " 0 0 "" "false" "cmd"

assert_eq "ws-exit: .exit_code sanitized to null" "null" \
    "$(jq -r '.exit_code' "$OUT6" 2>/dev/null)"

# ─── 7. all-good happy path still works (no regression) ──────────────────────
print_test_section "7. happy path (no regression)"

OUT7="$ARTIFACT_DIR/results-happy.json"
ERR7="$TEST_TEMP_DIR/happy.stderr"
_drive_writer "happy" "$OUT7" "$ERR7" -- \
    "$OUT7" "pass" 0 5 0 "ok" "true" "npm test"

assert_eq "happy: .verdict" "pass" "$(jq -r '.verdict' "$OUT7" 2>/dev/null)"
assert_eq "happy: .exit_code" "0" "$(jq -r '.exit_code' "$OUT7" 2>/dev/null)"
assert_eq "happy: .passed" "5" "$(jq -r '.passed' "$OUT7" 2>/dev/null)"
assert_eq "happy: .diff_applied" "true" "$(jq -r '.diff_applied' "$OUT7" 2>/dev/null)"

# ─── 8. schema registration ───────────────────────────────────────────────────
print_test_section "8. test.result_write.fallback registered in event-schema.json"

if jq -e '.known_types | index("test.result_write.fallback")' \
        "$REPO_ROOT/config/event-schema.json" >/dev/null 2>&1; then
    assert_pass "schema: test.result_write.fallback registered"
else
    assert_fail "schema: test.result_write.fallback registered" \
        "not present in config/event-schema.json::.known_types"
fi

print_test_results
exit $((FAIL > 0))
