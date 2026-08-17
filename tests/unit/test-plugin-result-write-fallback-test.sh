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

# ─── 8. forced jq failure exercises the fallback branch + event emission ────
# Copilot P1 on #640: without this case the suite proved sanitization works
# but never actually walked the failure path. Shim jq via PATH so it exits 1
# unconditionally, which makes the real implementation hit the fallback
# writer and emit test.result_write.fallback.
print_test_section "8. forced jq failure: fallback JSON + event emitted"

JQ_SHIM_DIR="$TEST_TEMP_DIR/jq-shim"
mkdir -p "$JQ_SHIM_DIR"
REAL_JQ="$(command -v jq)"
# Selectively fail only for the writer's `jq -n ...` invocation. Other
# callers (event-bus.sh, assertions, schema lookup) still get real jq so
# emit_event keeps working and the test can observe the fallback event.
cat > "$JQ_SHIM_DIR/jq" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == "-n" ]]; then
    exit 1
fi
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$JQ_SHIM_DIR/jq"

OUT8="$ARTIFACT_DIR/results-forced-fail.json"
ERR8="$TEST_TEMP_DIR/forced-fail.stderr"

# event-bus.sh captured ZBUILD_EVENTS_JSONL at source-time (when plugin.sh
# loaded), so just truncate the existing file rather than re-pointing.
: > "$ZBUILD_EVENTS_JSONL"

PATH="$JQ_SHIM_DIR:$PATH" _test_write_result \
    "$OUT8" "error" 0 0 0 "out" "false" "cmd" 2>"$ERR8" || true

assert_file_exists "forced-fail: results file written" "$OUT8"

if jq empty "$OUT8" >/dev/null 2>&1; then
    assert_pass "forced-fail: fallback JSON is parseable"
else
    assert_fail "forced-fail: fallback JSON is parseable" \
        "content: $(head -c 200 "$OUT8" 2>/dev/null)"
fi

assert_eq "forced-fail: .reason=result_write_failed" "result_write_failed" \
    "$(jq -r '.reason' "$OUT8" 2>/dev/null)"
assert_eq "forced-fail: .verdict=error" "error" \
    "$(jq -r '.verdict' "$OUT8" 2>/dev/null)"

if grep -q '"type":"test.result_write.fallback"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "forced-fail: test.result_write.fallback event emitted"
else
    assert_fail "forced-fail: test.result_write.fallback event emitted" \
        "events.jsonl: $(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null)"
fi

# ─── 9. schema registration ───────────────────────────────────────────────────
# #1717: `test.result_write.fallback` is the test plugin's OWN event, so it is
# declared in the test plugin's manifest and composed into the known set — no
# longer in the engine's config/event-schema.json. Asserting against the
# manifest is the stronger statement: it pins the OWNER, not just membership.
print_test_section "9. test.result_write.fallback declared by the test plugin's manifest"

source "$REPO_ROOT/core/event-bus/known-types.sh"

if eb_manifest_events "$REPO_ROOT/plugins/tool/test/manifest.yaml" \
        | grep -qxF "test.result_write.fallback"; then
    assert_pass "schema: test.result_write.fallback declared in provides.events"
else
    assert_fail "schema: test.result_write.fallback declared in provides.events" \
        "not present in plugins/tool/test/manifest.yaml::provides.events"
fi

if eb_compose_known_types | grep -qxF "test.result_write.fallback"; then
    assert_pass "schema: test.result_write.fallback is in the composed known set"
else
    assert_fail "schema: test.result_write.fallback is in the composed known set" \
        "composition (engine config + manifests) did not yield it"
fi

print_test_results
exit $((FAIL > 0))
