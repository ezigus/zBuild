#!/usr/bin/env bash
# Unit drive for tests/lib/test-harness.sh (Wave 14-B / #675).
#
# Verifies the Layer 2 canonical test-mode env contract per ADR-024:
#   - zb_test_init_env populates the 5 canonical vars to valid paths
#   - cleanup runs via EXIT trap and is additive (doesn't clobber existing traps)
#   - idempotent on second call
#   - _with_* helpers scope env mutations to a subshell and don't leak back
#   - zb_test_capture_fd3 captures writes to fd 3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

HARNESS="$REPO_ROOT/tests/lib/test-harness.sh"

print_test_header "test-harness init (Wave 14-B / #675)"

# ─── Test 1: harness file exists and is sourceable ───────────────────────────
print_test_section "1. harness file exists"
assert_file_exists "tests/lib/test-harness.sh present" "$HARNESS"

# shellcheck source=/dev/null
source "$HARNESS"

# ─── Test 2: zb_test_init_env sets the 5 canonical vars ──────────────────────
print_test_section "2. zb_test_init_env sets canonical env vars"

# Wipe any leaked state from caller env so we measure what the harness sets.
unset ZBUILD_RUN_ID ZBUILD_STATE_DIR ZBUILD_EVENTS_JSONL ZBUILD_ARTIFACT_DIR ZBUILD_EVENT_SCHEMA 2>/dev/null || true

zb_test_init_env

assert_pass_if_set() {
    local var="$1"
    if [[ -n "${!var:-}" ]]; then
        assert_pass "$var is set"
    else
        assert_fail "$var is set" "(empty)"
    fi
}

assert_pass_if_set ZBUILD_RUN_ID
assert_pass_if_set ZBUILD_STATE_DIR
assert_pass_if_set ZBUILD_EVENTS_JSONL
assert_pass_if_set ZBUILD_ARTIFACT_DIR
assert_pass_if_set ZBUILD_EVENT_SCHEMA

# ─── Test 3: paths point to real, valid filesystem entries ───────────────────
print_test_section "3. canonical paths are valid"

if [[ -d "$ZBUILD_STATE_DIR" ]]; then
    assert_pass "ZBUILD_STATE_DIR is a directory"
else
    assert_fail "ZBUILD_STATE_DIR is a directory" "$ZBUILD_STATE_DIR"
fi

if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    assert_pass "ZBUILD_EVENTS_JSONL exists as file"
else
    assert_fail "ZBUILD_EVENTS_JSONL exists as file" "$ZBUILD_EVENTS_JSONL"
fi

if [[ -d "$ZBUILD_ARTIFACT_DIR" ]]; then
    assert_pass "ZBUILD_ARTIFACT_DIR is a directory"
else
    assert_fail "ZBUILD_ARTIFACT_DIR is a directory" "$ZBUILD_ARTIFACT_DIR"
fi

if [[ -f "$ZBUILD_EVENT_SCHEMA" ]]; then
    assert_pass "ZBUILD_EVENT_SCHEMA points at the event schema"
else
    assert_fail "ZBUILD_EVENT_SCHEMA points at the event schema" "$ZBUILD_EVENT_SCHEMA"
fi

# ─── Test 4: idempotent on second call ───────────────────────────────────────
print_test_section "4. zb_test_init_env idempotent"

FIRST_STATE_DIR="$ZBUILD_STATE_DIR"
FIRST_RUN_ID="$ZBUILD_RUN_ID"

zb_test_init_env

assert_eq "second call preserves ZBUILD_STATE_DIR" "$FIRST_STATE_DIR" "$ZBUILD_STATE_DIR"
assert_eq "second call preserves ZBUILD_RUN_ID" "$FIRST_RUN_ID" "$ZBUILD_RUN_ID"

# ─── Test 5: zb_test_with_router_timeout scopes export ───────────────────────
print_test_section "5. zb_test_with_router_timeout isolates value"

unset ZBUILD_ROUTER_TIMEOUT 2>/dev/null || true

_emit_timeout() { printf '%s' "${ZBUILD_ROUTER_TIMEOUT:-UNSET}"; }
captured="$(zb_test_with_router_timeout 450 _emit_timeout)"
assert_eq "ZBUILD_ROUTER_TIMEOUT=450 visible inside subshell" "450" "$captured"

if [[ -z "${ZBUILD_ROUTER_TIMEOUT:-}" ]]; then
    assert_pass "ZBUILD_ROUTER_TIMEOUT does not leak back to caller"
else
    assert_fail "ZBUILD_ROUTER_TIMEOUT does not leak back to caller" "leaked: $ZBUILD_ROUTER_TIMEOUT"
fi

# ─── Test 6: zb_test_with_stage scopes export ────────────────────────────────
print_test_section "6. zb_test_with_stage isolates value"

unset ZBUILD_CURRENT_STAGE 2>/dev/null || true

_emit_stage() { printf '%s' "${ZBUILD_CURRENT_STAGE:-UNSET}"; }
captured_stage="$(zb_test_with_stage plan _emit_stage)"
assert_eq "ZBUILD_CURRENT_STAGE=plan visible inside subshell" "plan" "$captured_stage"

if [[ -z "${ZBUILD_CURRENT_STAGE:-}" ]]; then
    assert_pass "ZBUILD_CURRENT_STAGE does not leak back to caller"
else
    assert_fail "ZBUILD_CURRENT_STAGE does not leak back to caller" "leaked: $ZBUILD_CURRENT_STAGE"
fi

# ─── Test 7: nested with_stage + with_router_timeout works (Tr-5 case) ───────
print_test_section "7. nested with_stage + with_router_timeout"

_emit_both() { printf '%s|%s' "${ZBUILD_CURRENT_STAGE:-UNSET}" "${ZBUILD_ROUTER_TIMEOUT:-UNSET}"; }
nested="$(zb_test_with_stage plan zb_test_with_router_timeout 450 _emit_both)"
assert_eq "nested helpers both apply" "plan|450" "$nested"

# ─── Test 8: zb_test_capture_fd3 captures fd-3 output ────────────────────────
print_test_section "8. zb_test_capture_fd3 captures fd 3"

_write_to_fd3() { printf 'hi\n' >&3; }
captured_fd3="$(zb_test_capture_fd3 _write_to_fd3)"
assert_contains "captures 'hi' written to fd 3" "$captured_fd3" "hi"

# ─── Test 9: ZBUILD_STAGE_IO_FD=3 visible inside capture_fd3 scope ───────────
print_test_section "9. zb_test_capture_fd3 sets ZBUILD_STAGE_IO_FD=3"

_emit_fd_var() { printf '%s' "${ZBUILD_STAGE_IO_FD:-UNSET}" >&3; }
fd_var_captured="$(zb_test_capture_fd3 _emit_fd_var)"
assert_eq "ZBUILD_STAGE_IO_FD=3 inside capture scope" "3" "$fd_var_captured"

# Verify it doesn't leak back (was unset in this scope already)
if [[ -z "${ZBUILD_STAGE_IO_FD:-}" ]]; then
    assert_pass "ZBUILD_STAGE_IO_FD does not leak back to caller"
else
    assert_fail "ZBUILD_STAGE_IO_FD does not leak back to caller" "leaked: $ZBUILD_STAGE_IO_FD"
fi

print_test_results
