#!/usr/bin/env bash
# Tests: core/output/stage-io.sh fd-fallback path (#586).
# Sourcing stage-io.sh with ZBUILD_STAGE_IO_FD set to a closed fd should NOT
# fail (relaxed guard); it should warn once, set ZBUILD_STAGE_IO_FD=2, and
# emit a stage_io.fd_fallback event (unless ZBUILD_TEST_MODE=1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGE_IO_SH="$REPO_ROOT/core/output/stage-io.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io fd-fallback (#586): warn once + set fd=2 + emit event"
setup_test_env "stage-io-fd-fallback"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="test-fd-fallback"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# ─── T1: closed fd 3, no test mode → warns + falls back + emits event ───────
sub_out="$(mktemp -t fdfb1.XXXXXX)"
sub_err="$(mktemp -t fdfb1.XXXXXX)"
set +e
(
    # Drop ZBUILD_TEST_MODE so the event-emission branch runs.
    unset ZBUILD_TEST_MODE
    # Use fd 17 (guaranteed closed in a fresh subshell) so the fallback path
    # triggers regardless of whether the parent harness pre-opens fd 3.
    export ZBUILD_STAGE_IO_FD=17
    # Ensure fd 3 is NOT open in this subshell. It isn't by default.
    # shellcheck disable=SC1090
    source "$STAGE_IO_SH"
    rc=$?
    echo "rc=$rc"
    echo "effective_fd=${ZBUILD_STAGE_IO_FD:-unset}"
) >"$sub_out" 2>"$sub_err"
set -e

assert_contains "T1 source returns rc=0 (relaxed guard)" "$(cat "$sub_out")" "rc=0"
assert_contains "T1 effective fd falls back to 2" "$(cat "$sub_out")" "effective_fd=2"
assert_contains_regex "T1 warn fires on stderr" "$(cat "$sub_err")" "fallback|fall.*back|fd 2"
# Event must exist in jsonl
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    if grep -q '"stage_io.fd_fallback"' "$ZBUILD_EVENTS_JSONL"; then
        assert_pass "T1 stage_io.fd_fallback event emitted"
    else
        assert_fail "T1 stage_io.fd_fallback event missing from events.jsonl"
    fi
else
    assert_fail "T1 events.jsonl was not created"
fi

# ─── T2: ZBUILD_TEST_MODE=1 → warn fires, NO event in jsonl ────────────────
rm -f "$ZBUILD_EVENTS_JSONL"
sub_out2="$(mktemp -t fdfb2.XXXXXX)"
sub_err2="$(mktemp -t fdfb2.XXXXXX)"
set +e
(
    export ZBUILD_TEST_MODE=1
    # Use fd 17 (guaranteed closed in a fresh subshell) so the fallback path
    # triggers regardless of whether the parent harness pre-opens fd 3.
    export ZBUILD_STAGE_IO_FD=17
    # shellcheck disable=SC1090
    source "$STAGE_IO_SH"
    rc=$?
    echo "rc=$rc"
    echo "effective_fd=${ZBUILD_STAGE_IO_FD:-unset}"
) >"$sub_out2" 2>"$sub_err2"
set -e

assert_contains "T2 source rc=0 in test-mode" "$(cat "$sub_out2")" "rc=0"
assert_contains "T2 effective fd=2 in test-mode" "$(cat "$sub_out2")" "effective_fd=2"
assert_contains_regex "T2 warn still fires" "$(cat "$sub_err2")" "fallback|fall.*back|fd 2"
if [[ -f "$ZBUILD_EVENTS_JSONL" ]] && grep -q '"stage_io.fd_fallback"' "$ZBUILD_EVENTS_JSONL"; then
    assert_fail "T2 stage_io.fd_fallback event should be suppressed in test-mode"
else
    assert_pass "T2 stage_io.fd_fallback event suppressed in test-mode"
fi

# ─── T3: idempotency — re-validate twice → warn only once ──────────────────
sub_err3="$(mktemp -t fdfb3.XXXXXX)"
set +e
(
    unset ZBUILD_TEST_MODE
    # Use fd 17 (guaranteed closed in a fresh subshell) so the fallback path
    # triggers regardless of whether the parent harness pre-opens fd 3.
    export ZBUILD_STAGE_IO_FD=17
    # shellcheck disable=SC1090
    source "$STAGE_IO_SH"
    # Reset close fd and call again manually (module-load guard runs once).
    # We test idempotency by direct call:
    _stage_io_validate_fd
    _stage_io_validate_fd
) 2>"$sub_err3" >/dev/null
set -e

warn_count="$(grep -c -E 'fallback|fall.*back' "$sub_err3" || true)"
assert_eq "T3 warn emitted exactly once across multiple validate calls" "1" "$warn_count"

rm -f "$sub_out" "$sub_err" "$sub_out2" "$sub_err2" "$sub_err3"
cleanup_test_env
print_test_results
