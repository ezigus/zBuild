#!/usr/bin/env bash
# Tests: scripts/lib/helpers.sh — run_captured_command wrapper (ADR-015 v2, issue #439)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGE_IO_SH="$REPO_ROOT/core/output/stage-io.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/helpers — run_captured_command wrapper (ADR-015 v2, #439)"
setup_test_env "run-captured-command"

# Sandbox event-bus and state dir
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="test-run-rcc"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$STAGE_IO_SH"

# Mock template_stage_io_dests to return "file" by default
_MOCK_DESTS="file"
template_stage_io_dests() {
    local _stage="$1"
    [[ -z "$_MOCK_DESTS" ]] && return 0
    printf '%s\n' "$_MOCK_DESTS" | tr ',' '\n'
}

artifact_for() {
    local stage="$1" seq="$2"
    echo "$ZBUILD_STATE_DIR/artifacts/stage-io/${stage}-${seq}.json"
}

# ── T1: no args → rc=2 ────────────────────────────────────────────────────────
set +e
err="$(run_captured_command 2>&1)"
rc=$?
set -e
assert_eq "T1 zero args returns rc=2" "2" "$rc"
assert_contains_regex "T1 stderr mentions usage/required" "$err" "usage|required"

# ── T2: stage only, no argv → rc=2 ────────────────────────────────────────────
set +e
err2="$(run_captured_command somestage 2>&1)"
rc=$?
set -e
assert_eq "T2 stage-only no argv returns rc=2" "2" "$rc"
assert_contains_regex "T2 stderr mentions argv and required" "$err2" "argv.*required|required.*argv"

# ── T3: simple echo capture ───────────────────────────────────────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
_MOCK_DESTS="file"
set +e
out3="$(run_captured_command t3stage echo hello 2>/dev/null)"
rc=$?
set -e
assert_eq "T3 echo returns rc=0" "0" "$rc"
assert_file_exists "T3 artifact exists" "$(artifact_for t3stage 1)"
t3_json="$(cat "$(artifact_for t3stage 1)" 2>/dev/null || echo '{}')"
assert_json_key "T3 kind == command" "$t3_json" ".kind" "command"
assert_json_key "T3 input == 'echo hello'" "$t3_json" ".input" "echo hello"
assert_contains "T3 output contains hello" "$(printf '%s' "$t3_json" | jq -r .output)" "hello"
assert_json_key "T3 exit_code == 0" "$t3_json" ".exit_code" "0"
t3_pwd="$(printf '%s' "$t3_json" | jq -r '.metadata.pwd' 2>/dev/null)"
[[ -n "$t3_pwd" && "$t3_pwd" != "null" ]] && assert_pass "T3 metadata.pwd present" || assert_fail "T3 metadata.pwd present" "got: $t3_pwd"

# ── T4: failing command preserves rc ──────────────────────────────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
set +e
run_captured_command t4stage false >/dev/null 2>&1
rc=$?
set -e
assert_eq "T4 false transparently returns rc=1" "1" "$rc"
t4_json="$(cat "$(artifact_for t4stage 1)" 2>/dev/null || echo '{}')"
assert_json_key "T4 artifact exit_code == 1" "$t4_json" ".exit_code" "1"

# ── T5: stdout passthrough ────────────────────────────────────────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
out5="$(run_captured_command t5stage echo hi 2>/dev/null)"
# strip trailing newline for comparison
assert_eq "T5 stdout passthrough returns 'hi'" "hi" "${out5%$'\n'}"

# ── T6: merged stderr capture ─────────────────────────────────────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
set +e
run_captured_command t6stage sh -c 'echo err >&2' >/dev/null 2>&1
rc=$?
set -e
assert_eq "T6 sh -c returns rc=0" "0" "$rc"
t6_json="$(cat "$(artifact_for t6stage 1)" 2>/dev/null || echo '{}')"
assert_contains "T6 artifact .output contains stderr 'err'" "$(printf '%s' "$t6_json" | jq -r .output)" "err"

# ── T7: quoting round-trip via printf %q ──────────────────────────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
run_captured_command t7stage echo "hello world" >/dev/null 2>&1
t7_json="$(cat "$(artifact_for t7stage 1)" 2>/dev/null || echo '{}')"
t7_input="$(printf '%s' "$t7_json" | jq -r .input)"
# Either `'hello world'` (printf %q older) or `hello\ world` (newer). Check
# round-trip via bash -c reproducing the literal output.
t7_round="$(bash -c "$t7_input" 2>/dev/null || true)"
assert_eq "T7 input round-trips to reproduce argv via bash -c" "hello world" "${t7_round%$'\n'}"

# ── T8: no-destinations short-circuit ─────────────────────────────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
_MOCK_DESTS=""
out8="$(run_captured_command t8stage echo x 2>/dev/null)"
rc=$?
assert_eq "T8 no-dests passthrough returns 'x'" "x" "${out8%$'\n'}"
assert_eq "T8 no-dests rc=0" "0" "$rc"
assert_file_not_exists "T8 no artifact written" "$(artifact_for t8stage 1)"
_MOCK_DESTS="file"

# ── T9: missing-helper guard ──────────────────────────────────────────────────
# Run in a subshell where capture_stage_io is undefined.
set +e
err9="$(bash -c '
    # Only source helpers.sh (NOT stage-io.sh).
    source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
    # Defensive: ensure capture_stage_io is not present.
    unset -f capture_stage_io 2>/dev/null
    run_captured_command somestage echo nope
' 2>&1 >/dev/null)"
rc=$?
set -e
assert_eq "T9 missing capture_stage_io returns rc=2" "2" "$rc"
assert_contains "T9 stderr mentions capture_stage_io not loaded" "$err9" "capture_stage_io not loaded"

# ── T10: truncation ───────────────────────────────────────────────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
RUN_CAPTURED_CMD_MAX_BYTES=100 run_captured_command t10stage seq 1 100 >/dev/null 2>&1
t10_json="$(cat "$(artifact_for t10stage 1)" 2>/dev/null || echo '{}')"
t10_out="$(printf '%s' "$t10_json" | jq -r .output)"
assert_contains "T10 truncated output ends with [truncated:" "$t10_out" "[truncated:"

# ── T11: errexit transparency ─────────────────────────────────────────────────
# In a subshell with set -e, false should NOT abort the caller; the wrapper
# returns the exit code transparently and caller's || handler runs.
set +e
out11="$(bash -c '
    set -e
    source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
    source "'"$STAGE_IO_SH"'"
    template_stage_io_dests() { return 0; }   # empty dests → no capture
    if run_captured_command t11stage false; then
        echo "UNEXPECTED_TRUE"
    else
        echo "HANDLED_RC=$?"
    fi
    # Verify set -e still active.
    case $- in *e*) echo "ERREXIT_OK" ;; *) echo "ERREXIT_LOST" ;; esac
' 2>/dev/null)"
set -e
assert_contains "T11 caller's || handler ran" "$out11" "HANDLED_RC=1"
assert_contains "T11 caller still has errexit" "$out11" "ERREXIT_OK"

# ── T12: caller cwd recorded ──────────────────────────────────────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
mkdir -p "$TEST_TEMP_DIR/somedir"
(
    cd "$TEST_TEMP_DIR/somedir"
    run_captured_command t12stage pwd >/dev/null 2>&1
)
t12_json="$(cat "$(artifact_for t12stage 1)" 2>/dev/null || echo '{}')"
t12_pwd="$(printf '%s' "$t12_json" | jq -r '.metadata.pwd')"
# On macOS /tmp -> /private/tmp realpath; compare both.
expected_real="$(cd "$TEST_TEMP_DIR/somedir" && pwd)"
if [[ "$t12_pwd" == "$expected_real" || "$t12_pwd" == "$TEST_TEMP_DIR/somedir" ]]; then
    assert_pass "T12 metadata.pwd matches caller cwd"
else
    assert_fail "T12 metadata.pwd matches caller cwd" "expected: $expected_real, got: $t12_pwd"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
