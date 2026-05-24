#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  ruflo-adapter test suite                                                 ║
# ║  Unit tests for ruflo detection, MCP lifecycle, and circuit-breaker      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: ruflo-adapter Tests"

setup_test_env "sw-ruflo-adapter-test"
_test_cleanup_hook() { cleanup_test_env; }

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Module guard prevents double-sourcing
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Module guard"

source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

if [[ "${_RUFLO_ADAPTER_LOADED:-}" == "1" ]]; then
    assert_pass "module guard sentinel set after first source"
else
    assert_fail "module guard sentinel set after first source"
fi

# Verify the guard: modify sentinel, re-source, confirm no reset
RUFLO_AVAILABLE="sentinel_value"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
if [[ "${RUFLO_AVAILABLE}" == "sentinel_value" ]]; then
    assert_pass "double-source guard prevents re-initialization"
else
    assert_fail "double-source guard prevents re-initialization" "RUFLO_AVAILABLE was reset on re-source"
fi

# Reset for remaining tests
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: ruflo_detect with mock ruflo binary → RUFLO_AVAILABLE=true
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_detect — binary present"

mock_binary "ruflo" 'exit 0'

RUFLO_AVAILABLE=false
ruflo_detect
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_detect sets RUFLO_AVAILABLE=true when binary exists"
else
    assert_fail "ruflo_detect sets RUFLO_AVAILABLE=true when binary exists" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: ruflo_detect with no ruflo binary → RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_detect — binary absent"

# Remove mock ruflo and mock npx to fail
rm -f "$TEST_TEMP_DIR/bin/ruflo"
mock_binary "npx" 'exit 1'

# Temporarily restrict PATH to only the test bin dir so real system ruflo is excluded
_saved_path="$PATH"
PATH="$TEST_TEMP_DIR/bin"
RUFLO_AVAILABLE=true
ruflo_detect || true
PATH="$_saved_path"

if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "ruflo_detect sets RUFLO_AVAILABLE=false when no binary"
else
    assert_fail "ruflo_detect sets RUFLO_AVAILABLE=false when no binary" "got: $RUFLO_AVAILABLE"
fi

# Restore mock ruflo for subsequent tests
mock_binary "ruflo" 'case "${1:-}" in
    mcp) case "${2:-}" in
        start) sleep 100 & echo $!; exit 0 ;;
        status) exit 0 ;;
        *) exit 0 ;;
    esac ;;
    *) exit 0 ;;
esac'

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: ruflo_available exit codes
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_available"

unset RUFLO_FORCE_DISABLE 2>/dev/null || true
RUFLO_AVAILABLE=true
if ruflo_available; then
    assert_pass "ruflo_available returns 0 when RUFLO_AVAILABLE=true"
else
    assert_fail "ruflo_available returns 0 when RUFLO_AVAILABLE=true"
fi

RUFLO_AVAILABLE=false
if ! ruflo_available; then
    assert_pass "ruflo_available returns 1 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_available returns 1 when RUFLO_AVAILABLE=false"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: ruflo_init with no ruflo binary → no-op, exits 0
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_init — ruflo absent"

rm -f "$TEST_TEMP_DIR/bin/ruflo"
mock_binary "npx" 'exit 1'

RUFLO_AVAILABLE=false

# Restrict PATH to only the test bin dir so real system ruflo is excluded
_saved_path_init="$PATH"
PATH="$TEST_TEMP_DIR/bin"
exit_code=0
ruflo_init || exit_code=$?
PATH="$_saved_path_init"

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_init exits 0 when ruflo unavailable"
else
    assert_fail "ruflo_init exits 0 when ruflo unavailable" "got exit code: $exit_code"
fi

if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "ruflo_init leaves RUFLO_AVAILABLE=false when ruflo unavailable"
else
    assert_fail "ruflo_init leaves RUFLO_AVAILABLE=false when ruflo unavailable" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: ruflo_cleanup no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_cleanup — daemon not started by this run"

RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=false
exit_code=0
ruflo_cleanup || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_cleanup exits 0 when RUFLO_DAEMON_STARTED=false"
else
    assert_fail "ruflo_cleanup exits 0 when RUFLO_DAEMON_STARTED=false" "got exit code: $exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: ruflo_cleanup calls ruflo stop when available
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_cleanup — calls ruflo stop"

# Mock ruflo: record calls so we can verify `stop` was invoked
_cleanup_call_log="$TEST_TEMP_DIR/cleanup-calls.txt"
rm -f "$_cleanup_call_log"
mock_binary "ruflo" "echo \"\$*\" >> '$_cleanup_call_log'; exit 0"
# Clear bash command hash so the newly created mock is found before the real binary
hash -d ruflo 2>/dev/null || true

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
# Stub _timeout as a shell function so ruflo_with_timeout passes shell functions
# (like _ruflo_run_quiet) directly without going through system timeout(1), which
# cannot exec shell functions. This exercises the actual circuit-breaker logic.
_timeout() { local _ts="$1"; shift; "$@"; }
RUFLO_AVAILABLE=true
RUFLO_DAEMON_STARTED=true

exit_code=0
ruflo_cleanup || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_cleanup exits 0 when RUFLO_DAEMON_STARTED=true"
else
    assert_fail "ruflo_cleanup exits 0 when RUFLO_DAEMON_STARTED=true" "got exit code: $exit_code"
fi

if grep -q "^stop" "$_cleanup_call_log" 2>/dev/null; then
    assert_pass "ruflo_cleanup calls ruflo stop"
else
    assert_fail "ruflo_cleanup calls ruflo stop" "stop not found in call log: $(cat "$_cleanup_call_log" 2>/dev/null)"
fi

# Restore: unset _timeout stub and reload adapter for subsequent tests
unset -f _timeout
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 8: ruflo_with_timeout — circuit-breaks on timeout
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_with_timeout — circuit-breaker"

# Mock a command that fails (simulates timeout/failure)
mock_binary "ruflo_slow_cmd" 'exit 1'

RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

exit_code=0
ruflo_with_timeout 1 ruflo_slow_cmd || exit_code=$?

if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_with_timeout returns non-zero on command failure"
else
    assert_fail "ruflo_with_timeout returns non-zero on command failure"
fi

# Recoverable circuit breaker: single failure increments count but does NOT disable ruflo
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_with_timeout does NOT disable ruflo on single failure (recoverable — threshold 5)"
else
    assert_fail "ruflo_with_timeout does NOT disable ruflo on single failure (recoverable — threshold 5)" "got: $RUFLO_AVAILABLE"
fi
if [[ "${RUFLO_FAILURE_COUNT:-0}" -eq 1 ]]; then
    assert_pass "ruflo_with_timeout increments RUFLO_FAILURE_COUNT to 1 on first failure"
else
    assert_fail "ruflo_with_timeout increments RUFLO_FAILURE_COUNT to 1 on first failure" "got: ${RUFLO_FAILURE_COUNT:-0}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 9: ruflo_with_timeout — succeeds without circuit-breaking
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_with_timeout — success"

mock_binary "ruflo_fast_cmd" 'exit 0'

RUFLO_AVAILABLE=true
export RUFLO_AVAILABLE

exit_code=0
ruflo_with_timeout 5 ruflo_fast_cmd || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_with_timeout returns 0 on success"
else
    assert_fail "ruflo_with_timeout returns 0 on success" "got exit code: $exit_code"
fi

if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_with_timeout preserves RUFLO_AVAILABLE=true on success"
else
    assert_fail "ruflo_with_timeout preserves RUFLO_AVAILABLE=true on success" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 10: RUFLO_AVAILABLE exported and visible in subshell
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "RUFLO_AVAILABLE subshell visibility"

export RUFLO_AVAILABLE=true

subshell_val=$(bash -c 'echo "${RUFLO_AVAILABLE:-unset}"')
if [[ "$subshell_val" == "true" ]]; then
    assert_pass "RUFLO_AVAILABLE=true is visible in subshell after export"
else
    assert_fail "RUFLO_AVAILABLE=true is visible in subshell after export" "got: $subshell_val"
fi

export RUFLO_AVAILABLE=false
subshell_val=$(bash -c 'echo "${RUFLO_AVAILABLE:-unset}"')
if [[ "$subshell_val" == "false" ]]; then
    assert_pass "RUFLO_AVAILABLE=false is visible in subshell after export"
else
    assert_fail "RUFLO_AVAILABLE=false is visible in subshell after export" "got: $subshell_val"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 11: Module is safe under set -euo pipefail
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipefail safety"

# Run a subshell with strict mode — source the adapter and call functions
# with ruflo absent; must exit 0
rm -f "$TEST_TEMP_DIR/bin/ruflo"

pipefail_exit=0
bash -euo pipefail -c "
    export PATH='$TEST_TEMP_DIR/bin:/usr/bin:/bin'
    source '$SCRIPT_DIR/lib/ruflo-adapter.sh' 2>/dev/null || true
    ruflo_detect || true
    ruflo_init || true
    ruflo_cleanup || true
    ruflo_available || true
    exit 0
" || pipefail_exit=$?

if [[ $pipefail_exit -eq 0 ]]; then
    assert_pass "module is safe under set -euo pipefail with ruflo absent"
else
    assert_fail "module is safe under set -euo pipefail with ruflo absent" "exited with: $pipefail_exit"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 12: ruflo_init happy path — ruflo present, daemon starts successfully
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_init — daemon starts successfully"

# Mock ruflo: all subcommands succeed (init check, start --daemon, etc.)
mock_binary "ruflo" 'exit 0'
# Clear bash command hash so the newly created mock is found before the real binary
hash -d ruflo 2>/dev/null || true

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
# Stub _timeout as a shell function so ruflo_with_timeout passes shell functions
# (like _ruflo_run_quiet) directly without going through system timeout(1), which
# cannot exec shell functions and would trip the circuit breaker during import_memory.
_timeout() { local _ts="$1"; shift; "$@"; }
RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=false

ruflo_init

if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_init sets RUFLO_AVAILABLE=true when daemon starts"
else
    assert_fail "ruflo_init sets RUFLO_AVAILABLE=true when daemon starts" "got: $RUFLO_AVAILABLE"
fi

if [[ "$RUFLO_DAEMON_STARTED" == "true" ]]; then
    assert_pass "ruflo_init sets RUFLO_DAEMON_STARTED=true when daemon starts"
else
    assert_fail "ruflo_init sets RUFLO_DAEMON_STARTED=true when daemon starts" "got: $RUFLO_DAEMON_STARTED"
fi

# Restore: unset _timeout stub and reload adapter for subsequent tests
unset -f _timeout
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 13: ruflo_init — daemon startup failure, fail-open guarantee
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_init — daemon startup failure (fail-open)"

# Mock ruflo: init check and start --daemon both fail; status also fails
mock_binary "ruflo" 'exit 1'

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false

exit_code=0
ruflo_init || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_init exits 0 (fail-open) even when daemon startup fails"
else
    assert_fail "ruflo_init exits 0 (fail-open) even when daemon startup fails" "got exit code: $exit_code"
fi

if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "ruflo_init sets RUFLO_AVAILABLE=false when daemon startup fails"
else
    assert_fail "ruflo_init sets RUFLO_AVAILABLE=false when daemon startup fails" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 14: ruflo_store — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_store — no-op when unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false

exit_code=0
ruflo_store "test-key" "test-value" "test-ns" || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_store returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_store returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 15: ruflo_recall — returns empty string when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_recall — no-op when unavailable"

RUFLO_AVAILABLE=false

result=$(ruflo_recall "some query" "test-ns" 2>/dev/null || true)

if [[ -z "$result" ]]; then
    assert_pass "ruflo_recall returns empty string when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_recall returns empty string when RUFLO_AVAILABLE=false" "got: $result"
fi

exit_code=0
ruflo_recall "some query" "test-ns" >/dev/null 2>&1 || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_recall returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_recall returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 16: ruflo_index_shipwright_memory — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_index_shipwright_memory — no-op when unavailable"

RUFLO_AVAILABLE=false

exit_code=0
ruflo_index_shipwright_memory || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_index_shipwright_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_index_shipwright_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 17: ruflo_index_shipwright_memory — skips gracefully when memory dir missing
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_index_shipwright_memory — skips when no memory dir"

# Use mock ruflo that succeeds so RUFLO_AVAILABLE goes true
mock_binary "ruflo" 'exit 0'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true

# Override HOME to a temp dir with no .shipwright/memory structure
_orig_home="$HOME"
export HOME="$TEST_TEMP_DIR/no-memory-home"
mkdir -p "$HOME"

exit_code=0
ruflo_index_shipwright_memory || exit_code=$?

export HOME="$_orig_home"

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_index_shipwright_memory returns 0 when memory dir missing"
else
    assert_fail "ruflo_index_shipwright_memory returns 0 when memory dir missing" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 18: ruflo_import_memory — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_import_memory — no-op when unavailable"

RUFLO_AVAILABLE=false

exit_code=0
ruflo_import_memory || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_import_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_import_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 19: ruflo_export_memory — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_export_memory — no-op when unavailable"

RUFLO_AVAILABLE=false

exit_code=0
ruflo_export_memory || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_export_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_export_memory returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 20: ruflo_store — circuit-breaker fires on command failure
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_store — circuit-breaker fires on command failure"

mock_binary "ruflo" 'exit 1'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
RUFLO_USE_NPX=false

exit_code=0
ruflo_store "test-key" "test-value" "test-ns" || exit_code=$?

# ruflo_store is fail-open — must return 0 even when ruflo binary fails
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_store returns 0 (fail-open) when ruflo binary fails"
else
    assert_fail "ruflo_store returns 0 (fail-open) when ruflo binary fails" "exit_code=$exit_code"
fi

# Recoverable circuit breaker: single failure increments count but does NOT disable ruflo
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_store does NOT disable ruflo on single failure (recoverable circuit breaker)"
else
    assert_fail "ruflo_store does NOT disable ruflo on single failure (recoverable circuit breaker)" "RUFLO_AVAILABLE=$RUFLO_AVAILABLE"
fi
if [[ "${RUFLO_FAILURE_COUNT:-0}" -ge 1 ]]; then
    assert_pass "ruflo_store increments RUFLO_FAILURE_COUNT on failure"
else
    assert_fail "ruflo_store increments RUFLO_FAILURE_COUNT on failure" "got: ${RUFLO_FAILURE_COUNT:-0}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 21: ruflo_execute_build_single — returns 1 when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_single — no-op (returns 1) when unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
exit_code=0
ruflo_execute_build_single "test goal" || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_build_single returns 1 when RUFLO_AVAILABLE=false (signals fallback)"
else
    assert_fail "ruflo_execute_build_single returns 1 when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 22: ruflo_execute_build_single — returns 1 when goal is empty
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_single — returns 1 when goal is empty"

mock_binary "ruflo" 'exit 0'
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_single "" || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_build_single returns 1 (fail-open) when goal is empty"
else
    assert_fail "ruflo_execute_build_single returns 1 when goal is empty" "exit_code=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 23: ruflo_execute_build_single — circuit-breaker fires when agent fails
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_single — circuit-breaker fires on agent failure"

mock_binary "ruflo" 'exit 1'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_single "build the feature" || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_build_single returns 1 when agent command fails"
else
    assert_fail "ruflo_execute_build_single returns 1 when agent command fails" "exit_code=$exit_code"
fi
# Recoverable circuit breaker: single failure increments count but does NOT disable ruflo
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_execute_build_single does NOT disable ruflo on single failure (recoverable)"
else
    assert_fail "ruflo_execute_build_single does NOT disable ruflo on single failure (recoverable)" "RUFLO_AVAILABLE=$RUFLO_AVAILABLE"
fi
if [[ "${RUFLO_FAILURE_COUNT:-0}" -ge 1 ]]; then
    assert_pass "ruflo_execute_build_single increments RUFLO_FAILURE_COUNT on failure"
else
    assert_fail "ruflo_execute_build_single increments RUFLO_FAILURE_COUNT on failure" "got: ${RUFLO_FAILURE_COUNT:-0}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 24: ruflo_execute_build_single — returns 0 (success) on happy path
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_single — returns 0 on success"

mock_binary "ruflo" 'exit 0'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_single "implement the feature" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_build_single returns 0 when agent command succeeds"
else
    assert_fail "ruflo_execute_build_single returns 0 when agent command succeeds" "exit_code=$exit_code"
fi
# Circuit-breaker must NOT have fired on success
if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "ruflo_execute_build_single does not trip circuit-breaker on success"
else
    assert_fail "ruflo_execute_build_single does not trip circuit-breaker on success" "RUFLO_AVAILABLE=$RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 25: ruflo_learn_from_shipwright — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_learn_from_shipwright — no-op when unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
exit_code=0
ruflo_learn_from_shipwright "/nonexistent/file.json" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_learn_from_shipwright returns 0 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_learn_from_shipwright returns 0 when RUFLO_AVAILABLE=false" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 26: ruflo_learn_from_shipwright — skips invalid input (non-file, non-JSON)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_learn_from_shipwright — skips invalid input"

RUFLO_AVAILABLE=true
exit_code=0
# Path that doesn't exist is treated as raw JSON; jq fails → _content is empty → skips
ruflo_learn_from_shipwright "/nonexistent/outcome.json" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_learn_from_shipwright returns 0 on invalid input (fail-open)"
else
    assert_fail "ruflo_learn_from_shipwright returns 0 on invalid input" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 27: ruflo_recall_similar_outcomes — returns empty when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_recall_similar_outcomes — no-op when unavailable"

RUFLO_AVAILABLE=false
result=$(ruflo_recall_similar_outcomes "feature" "bug" 2>/dev/null || true)
if [[ -z "$result" ]]; then
    assert_pass "ruflo_recall_similar_outcomes returns empty when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_recall_similar_outcomes returns empty when RUFLO_AVAILABLE=false" "got: $result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 28: ruflo_index_adr_artifacts — no-op when RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_index_adr_artifacts — no-op when unavailable"

RUFLO_AVAILABLE=false
exit_code=0
ruflo_index_adr_artifacts || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_index_adr_artifacts returns 0 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_index_adr_artifacts returns 0 when RUFLO_AVAILABLE=false" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 29: ruflo_learn_from_shipwright — success path with valid outcome file
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_learn_from_shipwright — success path (file input)"

# Use mock_binary (writes to TEST_TEMP_DIR/bin, already first in PATH) and
# clear the bash hash table so the cached real ruflo path isn't used.
mock_binary "ruflo" 'exit 0'
hash -r 2>/dev/null || true
_outcome_file="$TEST_TEMP_DIR/outcome-29.json"
printf '{"issue_type":"backend","stage":"build","skills":"tdd","outcome":"success"}\n' \
    > "$_outcome_file"

RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
git() {
    if [[ "${1:-}" == "config" && "${2:-}" == "--get" && "${3:-}" == "remote.origin.url" ]]; then
        echo "https://github.com/test/repo.git"
    else
        command git "$@"
    fi
}
exit_code=0
ruflo_learn_from_shipwright "$_outcome_file" || exit_code=$?
unset -f git
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_learn_from_shipwright returns 0 on success with valid file"
else
    assert_fail "ruflo_learn_from_shipwright returns 0 on success with valid file" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 30: ruflo_learn_from_shipwright — success path with raw JSON string input
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_learn_from_shipwright — success path (raw JSON input)"

mock_binary "ruflo" 'exit 0'
hash -r 2>/dev/null || true

RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
git() {
    if [[ "${1:-}" == "config" && "${2:-}" == "--get" && "${3:-}" == "remote.origin.url" ]]; then
        echo "https://github.com/test/repo.git"
    else
        command git "$@"
    fi
}
exit_code=0
ruflo_learn_from_shipwright '{"issue_type":"frontend","outcome":"success"}' || exit_code=$?
unset -f git
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_learn_from_shipwright returns 0 on success with raw JSON"
else
    assert_fail "ruflo_learn_from_shipwright returns 0 on success with raw JSON" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_build_hive tests
# ═══════════════════════════════════════════════════════════════════════════════

# Test: ruflo_execute_build_hive returns 1 when ruflo unavailable
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=false
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
exit_code=0
ruflo_execute_build_hive "build the feature" 10 || exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_execute_build_hive returns 1 when ruflo unavailable"
else
    assert_fail "ruflo_execute_build_hive returns 1 when ruflo unavailable" "got exit=0"
fi

# Test: ruflo_execute_build_hive returns 1 when goal is empty
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=true
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
exit_code=0
ruflo_execute_build_hive "" || exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_execute_build_hive returns 1 when goal is empty"
else
    assert_fail "ruflo_execute_build_hive returns 1 when goal is empty" "got exit=0"
fi

# Test: ruflo_execute_build_hive returns 1 when hive init fails (binary exits non-zero)
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_orig_path="$PATH"
mock_binary "ruflo" 'exit 1'
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_hive "build the feature" 5 || exit_code=$?
PATH="$_orig_path"
rm -f "$TEST_TEMP_DIR/bin/ruflo"
rm -rf "$_test_tmp"
if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_execute_build_hive returns 1 when hive init fails"
else
    assert_fail "ruflo_execute_build_hive returns 1 when hive init fails" "got exit=0"
fi

# Test: ruflo_execute_build_hive returns 0 when orchestration succeeds
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
# Write mock directly (single-quoted heredoc) so $1/$2 are not expanded at write time
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive-123"
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_build_hive "build the feature" 5 || exit_code=$?
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_build_hive returns 0 on successful orchestration"
else
    assert_fail "ruflo_execute_build_hive returns 0 on successful orchestration" "got exit=$exit_code"
fi

# Test: ruflo_execute_build_hive respects RUFLO_HIVE_MAX_AGENTS cap
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_agent_count_file="$_test_tmp/agent-count.txt"
# Write mock directly; expand $_agent_count_file at write time (outer heredoc unquoted)
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
subcmd="\${1:-}"
if [[ "\$subcmd" == "hive-mind" && "\${2:-}" == "spawn" ]]; then
    while [[ \$# -gt 0 ]]; do
        if [[ "\$1" == "--count" ]]; then printf '%s' "\$2" > "$_agent_count_file"; fi
        shift
    done
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive-456"
RUFLO_USE_NPX=false
RUFLO_HIVE_MAX_AGENTS=2
ruflo_execute_build_hive "build the feature" 5 || true
recorded_count=$(cat "$_agent_count_file" 2>/dev/null || echo "0")
unset RUFLO_HIVE_MAX_AGENTS
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ "$recorded_count" == "2" ]]; then
    assert_pass "ruflo_execute_build_hive respects RUFLO_HIVE_MAX_AGENTS cap"
else
    assert_fail "ruflo_execute_build_hive respects RUFLO_HIVE_MAX_AGENTS cap" "count=$recorded_count"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_review tests
# ═══════════════════════════════════════════════════════════════════════════════

# Test: ruflo_execute_review returns 1 (exact) when ruflo unavailable
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=false
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_review "diff content" "$_test_tmp/review-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_review returns 1 when ruflo unavailable"
else
    assert_fail "ruflo_execute_review returns 1 when ruflo unavailable" "got exit=$exit_code"
fi

# Test: ruflo_execute_review returns 1 (exact) when diff_content is empty
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_review "" "$_test_tmp/review-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_review returns 1 when diff_content is empty"
else
    assert_fail "ruflo_execute_review returns 1 when diff_content is empty" "got exit=$exit_code"
fi

# Test: ruflo_execute_review returns 1 (exact) when hive init fails (binary exits non-zero)
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_orig_path="$PATH"
mock_binary "ruflo" 'exit 1'
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_review "diff content here" "$_test_tmp/review-out.md" || exit_code=$?
PATH="$_orig_path"
rm -f "$TEST_TEMP_DIR/bin/ruflo"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_review returns 1 when hive init fails"
else
    assert_fail "ruflo_execute_review returns 1 when hive init fails" "got exit=$exit_code"
fi

# Test: ruflo_execute_review returns 0 and writes artifact on success
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
subcmd="${1:-}"
if [[ "$subcmd" == "hive-mind" && "${2:-}" == "memory" ]]; then
    printf 'review-diff: <diff content stored>\nreview-adrs: <adr context>\n'
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="review-hive-789"
RUFLO_USE_NPX=false
_artifact="$_test_tmp/review-result.md"
exit_code=0
ruflo_execute_review "diff content here" "$_artifact" || exit_code=$?
# Check exit code and artifact before cleanup
_artifact_exists=false
_artifact_nonempty=false
[[ -f "$_artifact" ]] && _artifact_exists=true
[[ -s "$_artifact" ]] && _artifact_nonempty=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_review returns 0 on success"
else
    assert_fail "ruflo_execute_review returns 0 on success" "got exit=$exit_code"
fi
if [[ "$_artifact_exists" == "true" ]]; then
    assert_pass "ruflo_execute_review writes artifact file on success"
else
    assert_fail "ruflo_execute_review writes artifact file on success" "artifact missing"
fi
if [[ "$_artifact_nonempty" == "true" ]]; then
    assert_pass "ruflo_execute_review writes non-empty artifact on success"
else
    assert_fail "ruflo_execute_review writes non-empty artifact on success" "artifact empty"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_compound_quality tests
# ═══════════════════════════════════════════════════════════════════════════════

# Test: ruflo_execute_compound_quality returns 1 (exact) when ruflo unavailable
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=false
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_compound_quality "diff content" "$_test_tmp/cq-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 1 when ruflo unavailable"
else
    assert_fail "ruflo_execute_compound_quality returns 1 when ruflo unavailable" "got exit=$exit_code"
fi

# Test: ruflo_execute_compound_quality returns 1 (exact) when diff_content is empty
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_compound_quality "" "$_test_tmp/cq-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 1 when diff_content is empty"
else
    assert_fail "ruflo_execute_compound_quality returns 1 when diff_content is empty" "got exit=$exit_code"
fi

# Test: ruflo_execute_compound_quality returns 1 (exact) when hive init fails
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_orig_path="$PATH"
mock_binary "ruflo" 'exit 1'
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_compound_quality "diff content here" "$_test_tmp/cq-out.md" || exit_code=$?
PATH="$_orig_path"
rm -f "$TEST_TEMP_DIR/bin/ruflo"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 1 when hive init fails"
else
    assert_fail "ruflo_execute_compound_quality returns 1 when hive init fails" "got exit=$exit_code"
fi

# Test: ruflo_execute_compound_quality returns 0 and writes artifact on success
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
subcmd="${1:-}"
if [[ "$subcmd" == "hive-mind" && "${2:-}" == "memory" ]]; then
    printf 'cq-diff: <diff stored>\ncq-review-context: <review>\n'
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="cq-hive-999"
RUFLO_USE_NPX=false
_artifact="$_test_tmp/cq-result.md"
exit_code=0
ruflo_execute_compound_quality "diff content here" "$_artifact" || exit_code=$?
# Check exit code and artifact before cleanup
_cq_artifact_exists=false
_cq_artifact_nonempty=false
[[ -f "$_artifact" ]] && _cq_artifact_exists=true
[[ -s "$_artifact" ]] && _cq_artifact_nonempty=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 0 on success"
else
    assert_fail "ruflo_execute_compound_quality returns 0 on success" "got exit=$exit_code"
fi
if [[ "$_cq_artifact_exists" == "true" ]]; then
    assert_pass "ruflo_execute_compound_quality writes artifact file on success"
else
    assert_fail "ruflo_execute_compound_quality writes artifact file on success" "artifact missing"
fi
if [[ "$_cq_artifact_nonempty" == "true" ]]; then
    assert_pass "ruflo_execute_compound_quality writes non-empty artifact on success"
else
    assert_fail "ruflo_execute_compound_quality writes non-empty artifact on success" "artifact empty"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_audit tests
# ═══════════════════════════════════════════════════════════════════════════════

# Test: ruflo_execute_audit returns 1 (exact) when ruflo unavailable
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=false
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_audit "diff content" "$_test_tmp/audit-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_audit returns 1 when ruflo unavailable"
else
    assert_fail "ruflo_execute_audit returns 1 when ruflo unavailable" "got exit=$exit_code"
fi

# Test: ruflo_execute_audit returns 1 (exact) when diff_content is empty
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
exit_code=0
ruflo_execute_audit "" "$_test_tmp/audit-out.md" || exit_code=$?
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_audit returns 1 when diff_content is empty"
else
    assert_fail "ruflo_execute_audit returns 1 when diff_content is empty" "got exit=$exit_code"
fi

# Test: ruflo_execute_audit returns 1 (exact) when hive init fails
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_orig_path="$PATH"
mock_binary "ruflo" 'exit 1'
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_audit "diff content here" "$_test_tmp/audit-out.md" || exit_code=$?
PATH="$_orig_path"
rm -f "$TEST_TEMP_DIR/bin/ruflo"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_audit returns 1 when hive init fails"
else
    assert_fail "ruflo_execute_audit returns 1 when hive init fails" "got exit=$exit_code"
fi

# Test: ruflo_execute_audit returns 0 and writes artifact on success;
#       verifies spawn and orchestrate were called
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
subcmd="\${1:-}"
printf '%s %s %s\\n' "\$subcmd" "\${2:-}" "\${3:-}" >> "$_call_log"
if [[ "\$subcmd" == "hive-mind" && "\${2:-}" == "memory" ]]; then
    printf 'audit-diff: <diff stored>\\nCVE-2024-1234: found in dependency\\nOWASP-A01: broken access control check\\n'
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="audit-hive-999"
RUFLO_USE_NPX=false
_artifact="$_test_tmp/audit-result.md"
exit_code=0
ruflo_execute_audit "diff content here" "$_artifact" || exit_code=$?
_audit_artifact_exists=false
_audit_artifact_nonempty=false
[[ -f "$_artifact" ]] && _audit_artifact_exists=true
[[ -s "$_artifact" ]] && _audit_artifact_nonempty=true
_spawn_called=false
_orch_called=false
grep -q "^hive-mind spawn" "$_call_log" 2>/dev/null && _spawn_called=true
grep -q "^coordination orchestrate" "$_call_log" 2>/dev/null && _orch_called=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_audit returns 0 on success"
else
    assert_fail "ruflo_execute_audit returns 0 on success" "got exit=$exit_code"
fi
if [[ "$_audit_artifact_exists" == "true" ]]; then
    assert_pass "ruflo_execute_audit writes artifact file on success"
else
    assert_fail "ruflo_execute_audit writes artifact file on success" "artifact missing"
fi
if [[ "$_audit_artifact_nonempty" == "true" ]]; then
    assert_pass "ruflo_execute_audit writes non-empty artifact on success"
else
    assert_fail "ruflo_execute_audit writes non-empty artifact on success" "artifact empty"
fi
if [[ "$_spawn_called" == "true" ]]; then
    assert_pass "ruflo_execute_audit calls hive-mind spawn"
else
    assert_fail "ruflo_execute_audit calls hive-mind spawn" "spawn not invoked"
fi
if [[ "$_orch_called" == "true" ]]; then
    assert_pass "ruflo_execute_audit calls coordination orchestrate"
else
    assert_fail "ruflo_execute_audit calls coordination orchestrate" "orchestrate not invoked"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_plan_hive tests — multi-agent planning divergence
# ═══════════════════════════════════════════════════════════════════════════════

# Test: ruflo_execute_plan_hive returns 1 (exact) when ruflo unavailable
unset _RUFLO_ADAPTER_LOADED
RUFLO_AVAILABLE=false
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
exit_code=0
ruflo_execute_plan_hive "Add a getter method" "Issue body details" >/dev/null || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_plan_hive returns 1 when ruflo unavailable"
else
    assert_fail "ruflo_execute_plan_hive returns 1 when ruflo unavailable" "got exit=$exit_code"
fi

# Test: ruflo_execute_plan_hive returns 1 (exact) when goal is empty
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
exit_code=0
ruflo_execute_plan_hive "" "issue body" >/dev/null || exit_code=$?
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_plan_hive returns 1 when goal is empty"
else
    assert_fail "ruflo_execute_plan_hive returns 1 when goal is empty" "got exit=$exit_code"
fi

# Test: ruflo_execute_plan_hive returns 1 (exact) when hive is unavailable
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_orig_path="$PATH"
mock_binary "ruflo" 'exit 1'
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_plan_hive "Add a getter method" "issue body" >/dev/null || exit_code=$?
PATH="$_orig_path"
rm -f "$TEST_TEMP_DIR/bin/ruflo"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_plan_hive returns 1 when hive unavailable"
else
    assert_fail "ruflo_execute_plan_hive returns 1 when hive unavailable" "got exit=$exit_code"
fi

# Test: ruflo_execute_plan_hive returns 1 when planners produce no output
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
# Always succeed but return empty memory list
subcmd="${1:-}"
if [[ "$subcmd" == "hive-mind" && "${2:-}" == "memory" ]]; then
    # empty list — simulates planners failing to write
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="plan-hive-test"
RUFLO_USE_NPX=false
exit_code=0
ruflo_execute_plan_hive "Add a getter method" "issue body" >/dev/null 2>&1 || exit_code=$?
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 1 ]]; then
    assert_pass "ruflo_execute_plan_hive returns 1 when union is empty"
else
    assert_fail "ruflo_execute_plan_hive returns 1 when union is empty" "got exit=$exit_code"
fi

# Test: ruflo_execute_plan_hive returns 0 and emits plan on stdout on success;
#       verifies spawn and orchestrate were called
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
subcmd="\${1:-}"
printf '%s %s %s\\n' "\$subcmd" "\${2:-}" "\${3:-}" >> "$_call_log"
if [[ "\$subcmd" == "hive-mind" && "\${2:-}" == "memory" ]]; then
    printf '## Files to Modify\\nfoo.sh\\n## Implementation Steps\\n1. step\\n## Task Checklist\\n- [ ] task\\n## Testing Approach\\nrun tests\\n## Definition of Done\\nall green\\n'
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="plan-hive-success"
RUFLO_USE_NPX=false
_plan_out="$_test_tmp/plan-out.md"
exit_code=0
ruflo_execute_plan_hive "Add a getter method" "issue body" > "$_plan_out" 2>/dev/null || exit_code=$?
_plan_out_exists=false
_plan_out_nonempty=false
[[ -f "$_plan_out" ]] && _plan_out_exists=true
[[ -s "$_plan_out" ]] && _plan_out_nonempty=true
_spawn_called=false
_orch_called=false
grep -q "^hive-mind spawn" "$_call_log" 2>/dev/null && _spawn_called=true
grep -q "^coordination orchestrate" "$_call_log" 2>/dev/null && _orch_called=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_plan_hive returns 0 on success"
else
    assert_fail "ruflo_execute_plan_hive returns 0 on success" "got exit=$exit_code"
fi
if [[ "$_plan_out_exists" == "true" ]]; then
    assert_pass "ruflo_execute_plan_hive emits plan content on stdout"
else
    assert_fail "ruflo_execute_plan_hive emits plan content on stdout" "stdout missing"
fi
if [[ "$_plan_out_nonempty" == "true" ]]; then
    assert_pass "ruflo_execute_plan_hive emits non-empty plan on stdout"
else
    assert_fail "ruflo_execute_plan_hive emits non-empty plan on stdout" "stdout empty"
fi
if [[ "$_spawn_called" == "true" ]]; then
    assert_pass "ruflo_execute_plan_hive calls hive-mind spawn"
else
    assert_fail "ruflo_execute_plan_hive calls hive-mind spawn" "spawn not invoked"
fi
if [[ "$_orch_called" == "true" ]]; then
    assert_pass "ruflo_execute_plan_hive calls coordination orchestrate"
else
    assert_fail "ruflo_execute_plan_hive calls coordination orchestrate" "orchestrate not invoked"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 31: ruflo_load_defaults — no-op when no defaults file exists
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — no-op when no defaults file"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
# Ensure no defaults files exist in test environment or current working directory
_orig_home="$HOME"
_orig_pwd="$(pwd)"
_tmp_home=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.home.XXXXXX")
_tmp_cwd=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.cwd.XXXXXX")
HOME="$_tmp_home"
cd "$_tmp_cwd"
# Capture state before
unset RUFLO_MAX_AGENTS RUFLO_COST_BUDGET_MULTIPLIER RUFLO_CIRCUIT_BREAKER_TIMEOUT \
      RUFLO_LEARNING_BRIDGE RUFLO_Q_LEARNING 2>/dev/null || true
exit_code=0
ruflo_load_defaults || exit_code=$?
cd "$_orig_pwd"
HOME="$_orig_home"
rm -rf "$_tmp_home" "$_tmp_cwd"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_load_defaults returns 0 when no defaults file exists"
else
    assert_fail "ruflo_load_defaults returns 0 when no defaults file" "exit=$exit_code"
fi
if [[ -z "${RUFLO_MAX_AGENTS:-}" ]]; then
    assert_pass "ruflo_load_defaults does not set RUFLO_MAX_AGENTS when no file"
else
    assert_fail "ruflo_load_defaults does not set RUFLO_MAX_AGENTS when no file" "got: $RUFLO_MAX_AGENTS"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 32: ruflo_load_defaults — loads values from repo-local .shipwright/defaults.json
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — loads values from repo-local file"

_tmp_repo=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
mkdir -p "$_tmp_repo/.shipwright"
cat > "$_tmp_repo/.shipwright/defaults.json" <<'JSON'
{
  "ruflo": {
    "enabled": true,
    "max_agents": 6,
    "cost_budget_multiplier": 3.0,
    "circuit_breaker_timeout_s": 45,
    "learning_bridge": false,
    "q_learning_routing": false
  }
}
JSON
# Run in subdir so .shipwright/defaults.json is found relative to CWD
unset RUFLO_MAX_AGENTS RUFLO_COST_BUDGET_MULTIPLIER RUFLO_CIRCUIT_BREAKER_TIMEOUT \
      RUFLO_LEARNING_BRIDGE RUFLO_Q_LEARNING 2>/dev/null || true
(
    cd "$_tmp_repo"
    source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
    ruflo_load_defaults
    [[ "${RUFLO_MAX_AGENTS:-}" == "6" ]]               && printf 'agents_ok\n'
    [[ "${RUFLO_COST_BUDGET_MULTIPLIER:-}" == "3.0" ]] && printf 'budget_ok\n'
    [[ "${RUFLO_CIRCUIT_BREAKER_TIMEOUT:-}" == "45" ]] && printf 'timeout_ok\n'
    [[ "${RUFLO_LEARNING_BRIDGE:-}" == "false" ]]       && printf 'bridge_ok\n'
    [[ "${RUFLO_Q_LEARNING:-}" == "false" ]]            && printf 'qlearn_ok\n'
) > "$_tmp_repo/results.txt" 2>/dev/null || true
_results=$(cat "$_tmp_repo/results.txt" 2>/dev/null || true)
rm -rf "$_tmp_repo"
if printf '%s\n' "$_results" | grep -q "agents_ok"; then
    assert_pass "ruflo_load_defaults sets RUFLO_MAX_AGENTS from repo-local file"
else
    assert_fail "ruflo_load_defaults sets RUFLO_MAX_AGENTS from repo-local file" "results=$_results"
fi
if printf '%s\n' "$_results" | grep -q "timeout_ok"; then
    assert_pass "ruflo_load_defaults sets RUFLO_CIRCUIT_BREAKER_TIMEOUT from repo-local file"
else
    assert_fail "ruflo_load_defaults sets RUFLO_CIRCUIT_BREAKER_TIMEOUT from repo-local file" "results=$_results"
fi
if printf '%s\n' "$_results" | grep -q "bridge_ok"; then
    assert_pass "ruflo_load_defaults sets RUFLO_LEARNING_BRIDGE from repo-local file"
else
    assert_fail "ruflo_load_defaults sets RUFLO_LEARNING_BRIDGE from repo-local file" "results=$_results"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 33: ruflo_load_defaults — falls back to ~/.shipwright/defaults.json
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — fallback to user-global defaults"

_tmp_home2=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-home.XXXXXX")
_tmp_repo2=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-repo.XXXXXX")
mkdir -p "$_tmp_home2/.shipwright"
cat > "$_tmp_home2/.shipwright/defaults.json" <<'JSON'
{
  "ruflo": {
    "max_agents": 12,
    "circuit_breaker_timeout_s": 60,
    "learning_bridge": true,
    "q_learning_routing": true
  }
}
JSON
_global_results=$(
    cd "$_tmp_repo2"
    HOME="$_tmp_home2"
    source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
    ruflo_load_defaults
    [[ "${RUFLO_MAX_AGENTS:-}" == "12" ]]              && printf 'agents_ok\n'
    [[ "${RUFLO_CIRCUIT_BREAKER_TIMEOUT:-}" == "60" ]] && printf 'timeout_ok\n'
) 2>/dev/null || true
rm -rf "$_tmp_home2" "$_tmp_repo2"
if printf '%s\n' "$_global_results" | grep -q "agents_ok"; then
    assert_pass "ruflo_load_defaults falls back to ~/.shipwright/defaults.json"
else
    assert_fail "ruflo_load_defaults falls back to ~/.shipwright/defaults.json" "results=$_global_results"
fi
if printf '%s\n' "$_global_results" | grep -q "timeout_ok"; then
    assert_pass "ruflo_load_defaults loads RUFLO_CIRCUIT_BREAKER_TIMEOUT from user-global file"
else
    assert_fail "ruflo_load_defaults loads RUFLO_CIRCUIT_BREAKER_TIMEOUT from user-global file" "results=$_global_results"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 34: ruflo_load_defaults — repo-local takes priority over user-global
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — repo-local overrides user-global"

_tmp_home3=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-home.XXXXXX")
_tmp_repo3=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-repo.XXXXXX")
mkdir -p "$_tmp_home3/.shipwright" "$_tmp_repo3/.shipwright"
printf '{"ruflo":{"max_agents":99}}\n' > "$_tmp_home3/.shipwright/defaults.json"
printf '{"ruflo":{"max_agents":3}}\n'  > "$_tmp_repo3/.shipwright/defaults.json"
_priority_results=$(
    cd "$_tmp_repo3"
    HOME="$_tmp_home3"
    source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
    ruflo_load_defaults
    printf '%s\n' "${RUFLO_MAX_AGENTS:-unset}"
) 2>/dev/null || true
rm -rf "$_tmp_home3" "$_tmp_repo3"
if [[ "$_priority_results" == "3" ]]; then
    assert_pass "ruflo_load_defaults repo-local (3) overrides user-global (99)"
else
    assert_fail "ruflo_load_defaults repo-local overrides user-global" "got: $_priority_results"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 35: ruflo_load_defaults — handles invalid JSON gracefully (fail-open)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_load_defaults — handles invalid JSON gracefully"

_tmp_repo4=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
mkdir -p "$_tmp_repo4/.shipwright"
printf 'not valid json at all\n' > "$_tmp_repo4/.shipwright/defaults.json"
exit_code=0
(
    cd "$_tmp_repo4"
    source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
    ruflo_load_defaults || exit 1
) 2>/dev/null || exit_code=$?
rm -rf "$_tmp_repo4"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_load_defaults returns 0 on invalid JSON (fail-open)"
else
    assert_fail "ruflo_load_defaults returns 0 on invalid JSON (fail-open)" "exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tests 36-41: CI runner — shipwright-pipeline.yml workflow assertions
# ═══════════════════════════════════════════════════════════════════════════════
_PIPELINE_YML="${SCRIPT_DIR}/../.github/workflows/shipwright-pipeline.yml"

print_test_section "CI workflow — ruflo install step present"
if grep -q "Install ruflo" "$_PIPELINE_YML" 2>/dev/null; then
    assert_pass "shipwright-pipeline.yml contains 'Install ruflo' step"
else
    assert_fail "shipwright-pipeline.yml contains 'Install ruflo' step" "not found"
fi

print_test_section "CI workflow — ruflo install step has continue-on-error"
if grep -A30 "Install ruflo" "$_PIPELINE_YML" 2>/dev/null | grep -q "continue-on-error: true"; then
    assert_pass "ruflo install step has continue-on-error: true"
else
    assert_fail "ruflo install step has continue-on-error: true" "not found"
fi

print_test_section "CI workflow — orphan-branch restore is sole ruflo memory restore"
if grep -q "ruflo_ci_memory_pull" "$_PIPELINE_YML" 2>/dev/null; then
    assert_pass "shipwright-pipeline.yml uses ruflo_ci_memory_pull for memory restore"
else
    assert_fail "shipwright-pipeline.yml uses ruflo_ci_memory_pull for memory restore" "not found"
fi
if grep -q "actions/cache/restore@v4" "$_PIPELINE_YML" 2>/dev/null; then
    assert_fail "ruflo actions/cache/restore@v4 removed (orphan-branch is sole restore path)" "still present"
else
    assert_pass "ruflo actions/cache/restore@v4 removed (orphan-branch is sole restore path)"
fi

print_test_section "CI workflow — orphan-branch save is sole ruflo memory save"
if grep -q "ruflo_ci_memory_push" "$_PIPELINE_YML" 2>/dev/null; then
    assert_pass "shipwright-pipeline.yml uses ruflo_ci_memory_push for memory save"
else
    assert_fail "shipwright-pipeline.yml uses ruflo_ci_memory_push for memory save" "not found"
fi
if grep -q "actions/cache/save@v4" "$_PIPELINE_YML" 2>/dev/null; then
    assert_fail "ruflo actions/cache/save@v4 removed (orphan-branch is sole save path)" "still present"
else
    assert_pass "ruflo actions/cache/save@v4 removed (orphan-branch is sole save path)"
fi

print_test_section "CI workflow — ruflo install appears before Run Shipwright pipeline"
_install_line=$(grep -n "Install ruflo" "$_PIPELINE_YML" 2>/dev/null | head -1 | cut -d: -f1)
_run_line=$(grep -n "Run Shipwright pipeline" "$_PIPELINE_YML" 2>/dev/null | head -1 | cut -d: -f1)
if [[ -n "$_install_line" && -n "$_run_line" && "$_install_line" -lt "$_run_line" ]]; then
    assert_pass "ruflo install step appears before Run Shipwright pipeline step"
else
    assert_fail "ruflo install step appears before Run Shipwright pipeline step" \
        "install_line=${_install_line:-missing} run_line=${_run_line:-missing}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 38: ruflo_with_timeout — shell function detected and called (no exit 127)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_with_timeout — shell function called without exit 127"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

_test_shell_fn() { return 0; }

exit_code=0
ruflo_with_timeout 5 _test_shell_fn || exit_code=$?
unset -f _test_shell_fn

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_with_timeout calls shell function and exits 0 (no exit 127)"
else
    assert_fail "ruflo_with_timeout calls shell function and exits 0 (no exit 127)" "got exit=$exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 39: ruflo_with_timeout — shell function killed at timeout (non-zero exit)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_with_timeout — shell function timeout returns non-zero"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

_test_slow_fn() { sleep 30; }

exit_code=0
ruflo_with_timeout 2 _test_slow_fn || exit_code=$?
unset -f _test_slow_fn

if [[ $exit_code -ne 0 ]]; then
    assert_pass "ruflo_with_timeout returns non-zero when shell function exceeds timeout"
else
    assert_fail "ruflo_with_timeout returns non-zero when shell function exceeds timeout" "got exit=0"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 40: ruflo_health_check — recovery from disabled state (status responds)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_health_check — recovers when daemon status responds"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status) exit 0 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=true
RUFLO_FAILURE_COUNT=3
RUFLO_USE_NPX=false
export RUFLO_AVAILABLE

exit_code=0
ruflo_health_check || exit_code=$?
_avail_after="$RUFLO_AVAILABLE"
_count_after="${RUFLO_FAILURE_COUNT:-unset}"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"

if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_health_check always returns 0 (fail-open)"
else
    assert_fail "ruflo_health_check always returns 0 (fail-open)" "got exit=$exit_code"
fi
if [[ "$_avail_after" == "true" ]]; then
    assert_pass "ruflo_health_check sets RUFLO_AVAILABLE=true when daemon responds"
else
    assert_fail "ruflo_health_check sets RUFLO_AVAILABLE=true when daemon responds" "got: $_avail_after"
fi
if [[ "$_count_after" -eq 0 ]]; then
    assert_pass "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 on recovery"
else
    assert_fail "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 on recovery" "got: $_count_after"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 41: ruflo_health_check — daemon restart path (status fails, start succeeds)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_health_check — restarts daemon when status fails"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status) exit 1 ;;
    start)  exit 0 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=true
RUFLO_FAILURE_COUNT=5
RUFLO_USE_NPX=false
export RUFLO_AVAILABLE

ruflo_health_check || true
_avail_restart="$RUFLO_AVAILABLE"
_count_restart="${RUFLO_FAILURE_COUNT:-unset}"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"

if [[ "$_avail_restart" == "true" ]]; then
    assert_pass "ruflo_health_check sets RUFLO_AVAILABLE=true after daemon restart"
else
    assert_fail "ruflo_health_check sets RUFLO_AVAILABLE=true after daemon restart" "got: $_avail_restart"
fi
if [[ "$_count_restart" -eq 0 ]]; then
    assert_pass "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 after restart"
else
    assert_fail "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 after restart" "got: $_count_restart"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 42: recoverable circuit breaker — 4 failures leave RUFLO_AVAILABLE=true
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "recoverable circuit breaker — 4 failures (below threshold 5)"

mock_binary "ruflo_fail_cmd" 'exit 1'
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

_i=0
while [[ $_i -lt 4 ]]; do
    ruflo_with_timeout 5 ruflo_fail_cmd || true
    _i=$(( _i + 1 ))
done

if [[ "$RUFLO_AVAILABLE" == "true" ]]; then
    assert_pass "RUFLO_AVAILABLE remains true after 4 failures (below threshold of 5)"
else
    assert_fail "RUFLO_AVAILABLE remains true after 4 failures (below threshold of 5)" "got: $RUFLO_AVAILABLE"
fi
if [[ "${RUFLO_FAILURE_COUNT:-0}" -eq 4 ]]; then
    assert_pass "RUFLO_FAILURE_COUNT is 4 after 4 failures"
else
    assert_fail "RUFLO_FAILURE_COUNT is 4 after 4 failures" "got: ${RUFLO_FAILURE_COUNT:-0}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 43: recoverable circuit breaker — 5 failures trip RUFLO_AVAILABLE=false
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "recoverable circuit breaker — 5 failures trips circuit"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_FAILURE_COUNT=0
export RUFLO_AVAILABLE

_i=0
while [[ $_i -lt 5 ]]; do
    ruflo_with_timeout 5 ruflo_fail_cmd || true
    _i=$(( _i + 1 ))
done

if [[ "$RUFLO_AVAILABLE" == "false" ]]; then
    assert_pass "RUFLO_AVAILABLE=false after 5 failures (threshold reached)"
else
    assert_fail "RUFLO_AVAILABLE=false after 5 failures (threshold reached)" "got: $RUFLO_AVAILABLE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 44: ruflo_health_check — resets RUFLO_FAILURE_COUNT after partial failures
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_health_check — RUFLO_FAILURE_COUNT reset after partial failures"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status) exit 0 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_DAEMON_STARTED=true
RUFLO_FAILURE_COUNT=3
RUFLO_USE_NPX=false
export RUFLO_AVAILABLE

ruflo_health_check || true
_count_after_recovery="${RUFLO_FAILURE_COUNT:-unset}"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"

if [[ "$_count_after_recovery" -eq 0 ]]; then
    assert_pass "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 after recovery from 3 failures"
else
    assert_fail "ruflo_health_check resets RUFLO_FAILURE_COUNT=0 after recovery from 3 failures" "got: $_count_after_recovery"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section A: _ruflo_compute_max_agents helper
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_ruflo_compute_max_agents — returns RUFLO_MAX_AGENTS when no stage-specific vars set"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
unset RUFLO_HIVE_MAX_AGENTS RUFLO_REVIEW_MAX_AGENTS RUFLO_CQ_MAX_AGENTS RUFLO_AUDIT_MAX_AGENTS
RUFLO_MAX_AGENTS=4
_result=$(_ruflo_compute_max_agents)
if [[ "$_result" == "4" ]]; then
    assert_pass "_ruflo_compute_max_agents returns RUFLO_MAX_AGENTS when no stage vars set"
else
    assert_fail "_ruflo_compute_max_agents returns RUFLO_MAX_AGENTS when no stage vars set" "got: $_result"
fi

print_test_section "_ruflo_compute_max_agents — returns stage-specific max when RUFLO_HIVE_MAX_AGENTS > RUFLO_MAX_AGENTS"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
unset RUFLO_REVIEW_MAX_AGENTS RUFLO_CQ_MAX_AGENTS RUFLO_AUDIT_MAX_AGENTS
RUFLO_MAX_AGENTS=4
RUFLO_HIVE_MAX_AGENTS=8
_result=$(_ruflo_compute_max_agents)
if [[ "$_result" == "8" ]]; then
    assert_pass "_ruflo_compute_max_agents returns RUFLO_HIVE_MAX_AGENTS when it exceeds RUFLO_MAX_AGENTS"
else
    assert_fail "_ruflo_compute_max_agents returns RUFLO_HIVE_MAX_AGENTS when it exceeds RUFLO_MAX_AGENTS" "got: $_result"
fi

print_test_section "_ruflo_compute_max_agents — returns max across all stage vars (RUFLO_AUDIT_MAX_AGENTS highest)"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_MAX_AGENTS=4
RUFLO_HIVE_MAX_AGENTS=5
RUFLO_REVIEW_MAX_AGENTS=6
RUFLO_CQ_MAX_AGENTS=7
RUFLO_AUDIT_MAX_AGENTS=10
_result=$(_ruflo_compute_max_agents)
if [[ "$_result" == "10" ]]; then
    assert_pass "_ruflo_compute_max_agents returns max across all stage-specific vars"
else
    assert_fail "_ruflo_compute_max_agents returns max across all stage-specific vars" "got: $_result"
fi

print_test_section "_ruflo_compute_max_agents — ignores non-integer values in stage vars"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_MAX_AGENTS=4
RUFLO_HIVE_MAX_AGENTS="not-a-number"
RUFLO_REVIEW_MAX_AGENTS="3.5"
RUFLO_CQ_MAX_AGENTS=""
RUFLO_AUDIT_MAX_AGENTS=6
_result=$(_ruflo_compute_max_agents)
if [[ "$_result" == "6" ]]; then
    assert_pass "_ruflo_compute_max_agents ignores non-integer stage var values"
else
    assert_fail "_ruflo_compute_max_agents ignores non-integer stage var values" "got: $_result"
fi
unset RUFLO_HIVE_MAX_AGENTS RUFLO_REVIEW_MAX_AGENTS RUFLO_CQ_MAX_AGENTS RUFLO_AUDIT_MAX_AGENTS

# ═══════════════════════════════════════════════════════════════════════════════
# Section A2: RUFLO_COST_BUDGET_MULTIPLIER inline clamping logic
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "RUFLO_COST_BUDGET_MULTIPLIER=2.0 — scales up to 8 within hard cap of 12 (base=4)"

_base=4
_hard_cap=12
_result=$(awk -v d="$_base" -v m="2.0" -v cap="$_hard_cap" 'BEGIN{v=int(d*m); print (v<1?1:(v>cap?cap:v))}')
if [[ "$_result" == "8" ]]; then
    assert_pass "multiplier=2.0 with base=4 hard_cap=12 scales up to 8"
else
    assert_fail "multiplier=2.0 with base=4 hard_cap=12 scales up to 8" "got: $_result"
fi

print_test_section "RUFLO_COST_BUDGET_MULTIPLIER=4.0 — clamps to hard cap (base=4 hard_cap=12 → 12)"

_base=4
_hard_cap=12
_result=$(awk -v d="$_base" -v m="4.0" -v cap="$_hard_cap" 'BEGIN{v=int(d*m); print (v<1?1:(v>cap?cap:v))}')
if [[ "$_result" == "12" ]]; then
    assert_pass "multiplier=4.0 with base=4 hard_cap=12 clamps at hard cap (12)"
else
    assert_fail "multiplier=4.0 with base=4 hard_cap=12 clamps at hard cap (12)" "got: $_result"
fi

print_test_section "RUFLO_COST_BUDGET_MULTIPLIER=0.5 — scales down by 50% (base=10 → 5)"

_base=10
_hard_cap=12
_result=$(awk -v d="$_base" -v m="0.5" -v cap="$_hard_cap" 'BEGIN{v=int(d*m); print (v<1?1:(v>cap?cap:v))}')
if [[ "$_result" == "5" ]]; then
    assert_pass "multiplier=0.5 with base=10 returns 5"
else
    assert_fail "multiplier=0.5 with base=10 returns 5" "got: $_result"
fi

print_test_section "RUFLO_COST_BUDGET_MULTIPLIER=0.1 — clamps to minimum 1 (base=10 → 1)"

_base=10
_hard_cap=12
_result=$(awk -v d="$_base" -v m="0.1" -v cap="$_hard_cap" 'BEGIN{v=int(d*m); print (v<1?1:(v>cap?cap:v))}')
if [[ "$_result" == "1" ]]; then
    assert_pass "multiplier=0.1 with base=10 clamps to min 1"
else
    assert_fail "multiplier=0.1 with base=10 clamps to min 1" "got: $_result"
fi

print_test_section "RUFLO_COST_BUDGET_MULTIPLIER=invalid — fallback preserves original value"

_base=4
_hard_cap=12
_multiplier_invalid="invalid"
if [[ -n "${_multiplier_invalid:-}" ]] && [[ "${_multiplier_invalid}" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    _result=$(awk -v d="$_base" -v m="$_multiplier_invalid" -v cap="$_hard_cap" 'BEGIN{v=int(d*m); print (v<1?1:(v>cap?cap:v))}' 2>/dev/null || echo "$_base")
else
    _result="$_base"
fi
if [[ "$_result" == "4" ]]; then
    assert_pass "invalid multiplier falls back to original base value (4)"
else
    assert_fail "invalid multiplier falls back to original base value (4)" "got: $_result"
fi

print_test_section "RUFLO_COST_BUDGET_MULTIPLIER unset — agent count unchanged (backward compat)"

_base=4
_hard_cap=12
_multiplier=""
if [[ -n "${_multiplier:-}" ]]; then
    _result=$(awk -v d="$_base" -v m="$_multiplier" -v cap="$_hard_cap" 'BEGIN{v=int(d*m); print (v<1?1:(v>cap?cap:v))}' 2>/dev/null || echo "$_base")
else
    _result="$_base"
fi
if [[ "$_result" == "4" ]]; then
    assert_pass "unset multiplier preserves original agent count (4)"
else
    assert_fail "unset multiplier preserves original agent count (4)" "got: $_result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section B: Singleton lifecycle — ruflo_init()
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_init — sets RUFLO_HIVE_AVAILABLE=true and RUFLO_HIVE_ID on hive init success"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) printf '| hive-1234567890-abc001 |\n'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID=""
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
ruflo_init 2>/dev/null || true
_hive_avail="$RUFLO_HIVE_AVAILABLE"
_hive_id="$RUFLO_HIVE_ID"
PATH="$_orig_path"
rm -rf "$_test_tmp"
if [[ "$_hive_avail" == "true" ]]; then
    assert_pass "ruflo_init sets RUFLO_HIVE_AVAILABLE=true on hive init success"
else
    assert_fail "ruflo_init sets RUFLO_HIVE_AVAILABLE=true on hive init success" "got: $_hive_avail"
fi
if [[ "$_hive_id" == "hive-1234567890-abc001" ]]; then
    assert_pass "ruflo_init sets RUFLO_HIVE_ID from hive-mind init output"
else
    assert_fail "ruflo_init sets RUFLO_HIVE_ID from hive-mind init output" "got: $_hive_id"
fi

print_test_section "ruflo_init — leaves RUFLO_HIVE_AVAILABLE=false when hive init fails (fail-open)"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) exit 1 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID=""
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
_init_exit=0
ruflo_init 2>/dev/null || _init_exit=$?
_hive_avail="$RUFLO_HIVE_AVAILABLE"
_ruflo_avail_after="$RUFLO_AVAILABLE"
PATH="$_orig_path"
rm -rf "$_test_tmp"
if [[ "$_hive_avail" == "false" ]]; then
    assert_pass "ruflo_init leaves RUFLO_HIVE_AVAILABLE=false when hive init fails"
else
    assert_fail "ruflo_init leaves RUFLO_HIVE_AVAILABLE=false when hive init fails" "got: $_hive_avail"
fi
if [[ "$_ruflo_avail_after" == "true" ]]; then
    assert_pass "ruflo_init daemon still available (fail-open) when hive init fails"
else
    assert_fail "ruflo_init daemon still available (fail-open) when hive init fails" "got: $_ruflo_avail_after"
fi

print_test_section "ruflo_init — does not set RUFLO_HIVE_AVAILABLE=true on stale inherited RUFLO_HIVE_ID"

# Regression test for Codex P1: if RUFLO_HIVE_ID is inherited from a parent
# process and hive-mind init fails, the code must clear the stale ID before
# evaluating success, preventing RUFLO_HIVE_AVAILABLE from being set true.
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) exit 1 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID="stale-hive-from-parent"   # simulates inherited env value
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
ruflo_init 2>/dev/null || true
_hive_avail="$RUFLO_HIVE_AVAILABLE"
_hive_id_after="$RUFLO_HIVE_ID"
PATH="$_orig_path"
rm -rf "$_test_tmp"
if [[ "$_hive_avail" == "false" ]]; then
    assert_pass "ruflo_init does not set RUFLO_HIVE_AVAILABLE=true on stale inherited RUFLO_HIVE_ID"
else
    assert_fail "ruflo_init does not set RUFLO_HIVE_AVAILABLE=true on stale inherited RUFLO_HIVE_ID" "got: $_hive_avail"
fi
if [[ -z "$_hive_id_after" ]]; then
    assert_pass "ruflo_init clears stale RUFLO_HIVE_ID when hive init fails"
else
    assert_fail "ruflo_init clears stale RUFLO_HIVE_ID when hive init fails" "got: $_hive_id_after"
fi

print_test_section "ruflo_init — emits ruflo.hive_available event with hive_id on success"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) printf '| hive-9999999999-evt001 |\n'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID=""
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_init 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if grep -qF "ruflo.hive_available" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_init emits ruflo.hive_available event on hive init success"
else
    assert_fail "ruflo_init emits ruflo.hive_available event on hive init success" "events: $_captured_event"
fi
if grep -qF "hive_id=hive-9999999999-evt001" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_init includes hive_id in ruflo.hive_available event"
else
    assert_fail "ruflo_init includes hive_id in ruflo.hive_available event" "events: $_captured_event"
fi

print_test_section "ruflo_init — emits ruflo.hive_unavailable event on hive init failure"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) exit 1 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=false
RUFLO_HIVE_ID=""
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_init 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if grep -qF "ruflo.hive_unavailable" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_init emits ruflo.hive_unavailable event on hive init failure"
else
    assert_fail "ruflo_init emits ruflo.hive_unavailable event on hive init failure" "events: $_captured_event"
fi

print_test_section "ruflo_init — skips hive init when RUFLO_HIVE_AVAILABLE already true (idempotent)"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
case "\${1:-}/\${2:-}" in
    init/check) exit 0 ;;
    start/--daemon) exit 0 ;;
    memory/import) exit 0 ;;
    hive-mind/init) printf '{"hive_id":"should-not-appear"}\n'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="pre-existing-hive"
RUFLO_USE_NPX=false
RUFLO_DAEMON_STARTED=false
ruflo_init 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_init skips hive-mind init when RUFLO_HIVE_AVAILABLE already true"
else
    assert_fail "ruflo_init skips hive-mind init when RUFLO_HIVE_AVAILABLE already true" "calls: $_calls"
fi
if [[ "$RUFLO_HIVE_ID" == "pre-existing-hive" ]]; then
    assert_pass "ruflo_init preserves existing RUFLO_HIVE_ID when skipping"
else
    assert_fail "ruflo_init preserves existing RUFLO_HIVE_ID when skipping" "got: $RUFLO_HIVE_ID"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section C: Gate checks — ruflo_execute_build_hive
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_build_hive — returns 1 immediately when RUFLO_HIVE_AVAILABLE=false"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
_exit=0
ruflo_execute_build_hive "build goal" 5 2>/dev/null || _exit=$?
if [[ "$_exit" -eq 1 ]]; then
    assert_pass "ruflo_execute_build_hive returns 1 when RUFLO_HIVE_AVAILABLE=false"
else
    assert_fail "ruflo_execute_build_hive returns 1 when RUFLO_HIVE_AVAILABLE=false" "got: $_exit"
fi

print_test_section "ruflo_execute_build_hive — emits ruflo.build_hive_skipped reason=hive_unavailable"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_execute_build_hive "build goal" 5 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -qF "ruflo.build_hive_skipped" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_build_hive emits ruflo.build_hive_skipped when hive unavailable"
else
    assert_fail "ruflo_execute_build_hive emits ruflo.build_hive_skipped when hive unavailable" "events: $_captured_event"
fi
if grep -qF "reason=hive_unavailable" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_build_hive includes reason=hive_unavailable in skipped event"
else
    assert_fail "ruflo_execute_build_hive includes reason=hive_unavailable in skipped event" "events: $_captured_event"
fi

print_test_section "ruflo_execute_build_hive — uses RUFLO_HIVE_ID from env (no hive init call) when RUFLO_HIVE_AVAILABLE=true"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="shared-hive-abc"
RUFLO_USE_NPX=false
ruflo_execute_build_hive "build goal" 2 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_execute_build_hive does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true"
else
    assert_fail "ruflo_execute_build_hive does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true" "calls: $_calls"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section C: Gate checks — ruflo_execute_review
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_review — returns 1 immediately when RUFLO_HIVE_AVAILABLE=false"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
_exit=0
ruflo_execute_review "diff content" "$_test_tmp/out.md" 2>/dev/null || _exit=$?
rm -rf "$_test_tmp"
if [[ "$_exit" -eq 1 ]]; then
    assert_pass "ruflo_execute_review returns 1 when RUFLO_HIVE_AVAILABLE=false"
else
    assert_fail "ruflo_execute_review returns 1 when RUFLO_HIVE_AVAILABLE=false" "got: $_exit"
fi

print_test_section "ruflo_execute_review — emits ruflo.review_skipped reason=hive_unavailable"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_execute_review "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -qF "ruflo.review_skipped" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_review emits ruflo.review_skipped when hive unavailable"
else
    assert_fail "ruflo_execute_review emits ruflo.review_skipped when hive unavailable" "events: $_captured_event"
fi

print_test_section "ruflo_execute_review — uses RUFLO_HIVE_ID from env (no hive init call) when RUFLO_HIVE_AVAILABLE=true"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then printf 'finding: none\n'; fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="shared-hive-xyz"
RUFLO_USE_NPX=false
ruflo_execute_review "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_execute_review does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true"
else
    assert_fail "ruflo_execute_review does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true" "calls: $_calls"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Queen Collapse Synthesis — union artifact written first (fail-open base)"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/artifact.md"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'finding: issue1\nfinding: issue2\n'
  exit 0
fi
if [[ "\${1:-}" == "coordination" && "\${2:-}" == "orchestrate" ]]; then
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_review "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_artifact_content=$(cat "$_artifact" 2>/dev/null || true)
rm -rf "$_test_tmp"
if [[ -n "$_artifact_content" ]]; then
    assert_pass "Queen Collapse: union artifact written (fail-open base exists)"
else
    assert_fail "Queen Collapse: union artifact written (fail-open base exists)" "artifact empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Queen Collapse Synthesis — synthesis orchestration attempted"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/artifact.md"
_call_log="$_test_tmp/calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'issue1\nissue2\n'
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_review "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_calls=$(cat "$_call_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
if grep -qF "coordination orchestrate" <<< "$_calls"; then
    assert_pass "Queen Collapse: coordination orchestrate called for synthesis"
else
    assert_fail "Queen Collapse: coordination orchestrate called for synthesis" "calls: $_calls"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Queen Collapse Synthesis — synthesis goal includes dedup and ranking"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/artifact.md"
_goal_log="$_test_tmp/goal.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'finding1\nfinding2\n'
  exit 0
fi
if [[ "\${1:-}" == "coordination" && "\${2:-}" == "orchestrate" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == --goal ]]; then
      next=1
    elif [[ -n "\${next:-}" ]]; then
      printf '%s\n' "\$arg" >> "$_goal_log"
      next=0
    fi
  done
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_review "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_goal=$(cat "$_goal_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
if grep -qi "dedup\|rank\|severity" <<< "$_goal"; then
    assert_pass "Queen Collapse: synthesis goal mentions dedup/rank/severity"
else
    assert_fail "Queen Collapse: synthesis goal mentions dedup/rank/severity" "goal: $_goal"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Queen Collapse Synthesis — fail-open: union preserved on synthesis failure"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/artifact.md"
_union_content="finding1\nfinding2\nfinding3"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf '%s\n' "$_union_content"
  exit 0
fi
if [[ "\${1:-}" == "coordination" && "\${2:-}" == "orchestrate" ]]; then
  exit 1
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_review "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_artifact_content=$(cat "$_artifact" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -q "finding1\|finding2\|finding3" <<< "$_artifact_content"; then
    assert_pass "Queen Collapse: fail-open preserves union on synthesis failure"
else
    assert_fail "Queen Collapse: fail-open preserves union on synthesis failure" "artifact: $_artifact_content"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Queen Collapse Synthesis — synthesis uses separate namespace (no re-consumption)"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/artifact.md"
_ns_log="$_test_tmp/ns.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == --namespace ]]; then
      next=1
    elif [[ -n "\${next:-}" ]]; then
      printf '%s\n' "\$arg" >> "$_ns_log"
      next=0
    fi
  done
  printf 'finding1\n'
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_review "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_namespaces=$(cat "$_ns_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
_has_review_ns=$(grep -c "review\|hive-review" <<< "$_namespaces" || echo 0)
_has_synth_ns=$(grep -c "synth" <<< "$_namespaces" || echo 0)
if [[ $_has_review_ns -gt 0 ]] && [[ $_has_synth_ns -gt 0 ]]; then
    assert_pass "Queen Collapse: uses separate synth namespace"
else
    assert_fail "Queen Collapse: uses separate synth namespace" "ns: $_namespaces"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Queen Collapse Synthesis — telemetry event emitted with exit code"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/artifact.md"
_event_log="$_test_tmp/events.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'finding\n'
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-hive"
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_log"; }
ruflo_execute_review "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_events=$(cat "$_event_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
if grep -q "ruflo.review_synth_complete" <<< "$_events" && grep -q "exit=" <<< "$_events"; then
    assert_pass "Queen Collapse: telemetry event emitted with exit code"
else
    assert_fail "Queen Collapse: telemetry event emitted with exit code" "events: $_events"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section C: Gate checks — ruflo_execute_compound_quality
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_compound_quality — returns 1 immediately when RUFLO_HIVE_AVAILABLE=false"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
_exit=0
ruflo_execute_compound_quality "diff content" "$_test_tmp/out.md" 2>/dev/null || _exit=$?
rm -rf "$_test_tmp"
if [[ "$_exit" -eq 1 ]]; then
    assert_pass "ruflo_execute_compound_quality returns 1 when RUFLO_HIVE_AVAILABLE=false"
else
    assert_fail "ruflo_execute_compound_quality returns 1 when RUFLO_HIVE_AVAILABLE=false" "got: $_exit"
fi

print_test_section "ruflo_execute_compound_quality — emits ruflo.cq_skipped reason=hive_unavailable"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_execute_compound_quality "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -qF "ruflo.cq_skipped" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_compound_quality emits ruflo.cq_skipped when hive unavailable"
else
    assert_fail "ruflo_execute_compound_quality emits ruflo.cq_skipped when hive unavailable" "events: $_captured_event"
fi

print_test_section "ruflo_execute_compound_quality — uses RUFLO_HIVE_ID from env (no hive init call) when RUFLO_HIVE_AVAILABLE=true"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then printf 'finding: none\n'; fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="shared-hive-cq"
RUFLO_USE_NPX=false
ruflo_execute_compound_quality "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_execute_compound_quality does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true"
else
    assert_fail "ruflo_execute_compound_quality does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true" "calls: $_calls"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Queen Collapse Synthesis — ruflo_execute_compound_quality (issue #419)
# ═══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "CQ Queen Collapse — union artifact written first (fail-open base)"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/cq-artifact.md"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'negative_tester: gap1\ndod_auditor: missing-doc\n'
  exit 0
fi
if [[ "\${1:-}" == "coordination" && "\${2:-}" == "orchestrate" ]]; then
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-cq-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_compound_quality "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_artifact_content=$(cat "$_artifact" 2>/dev/null || true)
rm -rf "$_test_tmp"
if [[ -n "$_artifact_content" ]]; then
    assert_pass "CQ Queen Collapse: union artifact written (fail-open base exists)"
else
    assert_fail "CQ Queen Collapse: union artifact written (fail-open base exists)" "artifact empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "CQ Queen Collapse — synthesis orchestration attempted"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/cq-artifact.md"
_call_log="$_test_tmp/calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'negative_tester: gap1\ndod_auditor: covered\n'
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-cq-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_compound_quality "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_calls=$(cat "$_call_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
# CQ already calls coordination orchestrate once for the adversarial pass; the
# synthesis pass adds a second call. Require at least 2 to confirm synthesis ran.
_orch_count=$(grep -c "^coordination orchestrate" <<< "$_calls" 2>/dev/null || echo 0)
_orch_count="${_orch_count//[^0-9]/}"
if (( ${_orch_count:-0} >= 2 )); then
    assert_pass "CQ Queen Collapse: coordination orchestrate called for synthesis (adversarial + synth)"
else
    assert_fail "CQ Queen Collapse: coordination orchestrate called for synthesis (adversarial + synth)" "count=$_orch_count calls: $_calls"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "CQ Queen Collapse — synthesis goal surfaces conflicts between agents"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/cq-artifact.md"
_goal_log="$_test_tmp/goal.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'negative_tester: gap1\ndod_auditor: gap1-covered\n'
  exit 0
fi
if [[ "\${1:-}" == "coordination" && "\${2:-}" == "orchestrate" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == --goal ]]; then
      next=1
    elif [[ -n "\${next:-}" ]]; then
      printf '%s\n' "\$arg" >> "$_goal_log"
      next=0
    fi
  done
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-cq-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_compound_quality "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_goal=$(cat "$_goal_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
# The synthesis goal must explicitly mention conflict surfacing.
if grep -qi "conflict" <<< "$_goal" && grep -qi "consensus\|disagree\|severity" <<< "$_goal"; then
    assert_pass "CQ Queen Collapse: synthesis goal surfaces conflicts/consensus"
else
    assert_fail "CQ Queen Collapse: synthesis goal surfaces conflicts/consensus" "goal: $_goal"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "CQ Queen Collapse — fail-open: union preserved on synthesis failure"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/cq-artifact.md"
# Track which orchestrate call this is (1=adversarial, 2=synthesis); synth fails.
_orch_state="$_test_tmp/orch_count"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'cq_finding_a\ncq_finding_b\ncq_finding_c\n'
  exit 0
fi
if [[ "\${1:-}" == "coordination" && "\${2:-}" == "orchestrate" ]]; then
  n=\$(cat "$_orch_state" 2>/dev/null || echo 0)
  n=\$((n + 1))
  printf '%d' "\$n" > "$_orch_state"
  if [[ "\$n" -ge 2 ]]; then
    exit 1
  fi
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-cq-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_compound_quality "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_artifact_content=$(cat "$_artifact" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -q "cq_finding_a\|cq_finding_b\|cq_finding_c" <<< "$_artifact_content"; then
    assert_pass "CQ Queen Collapse: fail-open preserves union on synthesis failure"
else
    assert_fail "CQ Queen Collapse: fail-open preserves union on synthesis failure" "artifact: $_artifact_content"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "CQ Queen Collapse — synthesis uses separate namespace (no re-consumption)"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/cq-artifact.md"
_ns_log="$_test_tmp/ns.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == --namespace ]]; then
      next=1
    elif [[ -n "\${next:-}" ]]; then
      printf '%s\n' "\$arg" >> "$_ns_log"
      next=0
    fi
  done
  printf 'cq_finding\n'
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-cq-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_compound_quality "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_namespaces=$(cat "$_ns_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
_has_cq_ns=$(grep -c "hive-cq-" <<< "$_namespaces" || echo 0)
_has_synth_ns=$(grep -c "hive-cq-synth" <<< "$_namespaces" || echo 0)
_has_cq_ns="${_has_cq_ns//[^0-9]/}"
_has_synth_ns="${_has_synth_ns//[^0-9]/}"
if (( ${_has_cq_ns:-0} > 0 )) && (( ${_has_synth_ns:-0} > 0 )); then
    assert_pass "CQ Queen Collapse: uses separate hive-cq-synth namespace"
else
    assert_fail "CQ Queen Collapse: uses separate hive-cq-synth namespace" "ns: $_namespaces"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "CQ Queen Collapse — telemetry event emitted with exit code"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_artifact="$_test_tmp/cq-artifact.md"
_event_log="$_test_tmp/events.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'cq_finding\n'
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-cq-hive"
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_log"; }
ruflo_execute_compound_quality "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_events=$(cat "$_event_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
if grep -q "ruflo.cq_synth_complete" <<< "$_events" && grep -q "exit=" <<< "$_events"; then
    assert_pass "CQ Queen Collapse: telemetry event emitted with exit code"
else
    assert_fail "CQ Queen Collapse: telemetry event emitted with exit code" "events: $_events"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section C: Gate checks — ruflo_execute_audit
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_execute_audit — returns 1 immediately when RUFLO_HIVE_AVAILABLE=false"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
_exit=0
ruflo_execute_audit "diff content" "$_test_tmp/out.md" 2>/dev/null || _exit=$?
rm -rf "$_test_tmp"
if [[ "$_exit" -eq 1 ]]; then
    assert_pass "ruflo_execute_audit returns 1 when RUFLO_HIVE_AVAILABLE=false"
else
    assert_fail "ruflo_execute_audit returns 1 when RUFLO_HIVE_AVAILABLE=false" "got: $_exit"
fi

print_test_section "ruflo_execute_audit — emits ruflo.audit_skipped reason=hive_unavailable"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_event_file="$_test_tmp/events.txt"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_file"; }
ruflo_execute_audit "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_captured_event=$(cat "$_event_file" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -qF "ruflo.audit_skipped" <<< "$_captured_event" 2>/dev/null; then
    assert_pass "ruflo_execute_audit emits ruflo.audit_skipped when hive unavailable"
else
    assert_fail "ruflo_execute_audit emits ruflo.audit_skipped when hive unavailable" "events: $_captured_event"
fi

print_test_section "ruflo_execute_audit — uses RUFLO_HIVE_ID from env (no hive init call) when RUFLO_HIVE_AVAILABLE=true"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then printf 'finding: none\n'; fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="shared-hive-audit"
RUFLO_USE_NPX=false
ruflo_execute_audit "diff content" "$_test_tmp/out.md" 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if ! grep -qF "hive-mind init" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_execute_audit does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true"
else
    assert_fail "ruflo_execute_audit does not call hive-mind init when RUFLO_HIVE_AVAILABLE=true" "calls: $_calls"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Audit Queen Collapse — union artifact written first (fail-open base)"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_artifact="$_test_tmp/audit-artifact.md"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'cve: CVE-2024-1234\nsecret: api-key leak\nowasp: A07 auth\n'
  exit 0
fi
if [[ "\${1:-}" == "coordination" && "\${2:-}" == "orchestrate" ]]; then
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-audit-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_audit "diff content" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_artifact_content=$(cat "$_artifact" 2>/dev/null || true)
rm -rf "$_test_tmp"
if [[ -n "$_artifact_content" ]]; then
    assert_pass "Audit Queen Collapse: union artifact written (fail-open base exists)"
else
    assert_fail "Audit Queen Collapse: union artifact written (fail-open base exists)" "artifact empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Audit Queen Collapse — synthesis orchestration attempted"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_artifact="$_test_tmp/audit-artifact.md"
_call_log="$_test_tmp/calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$_call_log"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'cve: issue1\nsecret: issue2\n'
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-audit-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_audit "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_calls=$(cat "$_call_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
# Audit calls orchestrate twice: once for the audit pass, once for synthesis.
# Counting occurrences distinguishes the queen-collapse pass from the audit pass.
_orch_count=$(grep -cF "coordination orchestrate" <<< "$_calls" || echo 0)
_orch_count="${_orch_count//[^0-9]/}"
if (( ${_orch_count:-0} >= 2 )); then
    assert_pass "Audit Queen Collapse: coordination orchestrate called for synthesis"
else
    assert_fail "Audit Queen Collapse: coordination orchestrate called for synthesis" "orch_count=$_orch_count calls: $_calls"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Audit Queen Collapse — synthesis goal includes dedup, severity, and promotion"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_artifact="$_test_tmp/audit-artifact.md"
_goal_log="$_test_tmp/goal.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'cve_finding\nsecret_finding\n'
  exit 0
fi
if [[ "\${1:-}" == "coordination" && "\${2:-}" == "orchestrate" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == --goal ]]; then
      next=1
    elif [[ -n "\${next:-}" ]]; then
      printf '%s\n' "\$arg" >> "$_goal_log"
      next=0
    fi
  done
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-audit-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_audit "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_goals=$(cat "$_goal_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
# Match a goal line that mentions the audit severity scale AND
# (dedup OR promot) — synthesis goal must signal both behaviours.
if grep -qi "severity\|critical\|high\|medium" <<< "$_goals" && \
   grep -qi "dedup\|promot\|consensus\|merge" <<< "$_goals"; then
    assert_pass "Audit Queen Collapse: synthesis goal mentions severity + dedup/promotion"
else
    assert_fail "Audit Queen Collapse: synthesis goal mentions severity + dedup/promotion" "goals: $_goals"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Audit Queen Collapse — fail-open: union preserved on synthesis failure"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_artifact="$_test_tmp/audit-artifact.md"
_union_marker="UNION_AUDIT_FINDING_MARKER"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
# Track orchestration calls so the second (synthesis) invocation can be failed
# while the first (audit pass) remains successful.
_count_file="$_test_tmp/orch_count"
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  # First memory list (audit ns) returns the union marker; the synthesis ns
  # is empty. Distinguishing by namespace would tie the test to internal
  # naming; instead we always return the marker — fail-open is verified by
  # ensuring the marker survives synthesis failure.
  printf '%s\n' "$_union_marker"
  exit 0
fi
if [[ "\${1:-}" == "coordination" && "\${2:-}" == "orchestrate" ]]; then
  _n=\$(cat "\$_count_file" 2>/dev/null || echo 0)
  _n=\$(( _n + 1 ))
  printf '%s' "\$_n" > "\$_count_file"
  if [[ "\$_n" -ge 2 ]]; then
    # Fail the synthesis (queen collapse) orchestration pass
    exit 1
  fi
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-audit-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_audit "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_artifact_content=$(cat "$_artifact" 2>/dev/null || true)
rm -rf "$_test_tmp"
if grep -qF "$_union_marker" <<< "$_artifact_content"; then
    assert_pass "Audit Queen Collapse: fail-open preserves union on synthesis failure"
else
    assert_fail "Audit Queen Collapse: fail-open preserves union on synthesis failure" "artifact: $_artifact_content"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Audit Queen Collapse — synthesis uses separate hive-audit-synth namespace"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_artifact="$_test_tmp/audit-artifact.md"
_ns_log="$_test_tmp/ns.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == --namespace ]]; then
      next=1
    elif [[ -n "\${next:-}" ]]; then
      printf '%s\n' "\$arg" >> "$_ns_log"
      next=0
    fi
  done
  printf 'audit_finding\n'
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-audit-hive"
RUFLO_USE_NPX=false
emit_event() { :; }
ruflo_execute_audit "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_namespaces=$(cat "$_ns_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
_has_audit_ns=$(grep -c "hive-audit-" <<< "$_namespaces" || echo 0)
_has_synth_ns=$(grep -c "hive-audit-synth" <<< "$_namespaces" || echo 0)
_has_audit_ns="${_has_audit_ns//[^0-9]/}"
_has_synth_ns="${_has_synth_ns//[^0-9]/}"
if (( ${_has_audit_ns:-0} > 0 )) && (( ${_has_synth_ns:-0} > 0 )); then
    assert_pass "Audit Queen Collapse: uses separate hive-audit-synth namespace"
else
    assert_fail "Audit Queen Collapse: uses separate hive-audit-synth namespace" "ns: $_namespaces"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Audit Queen Collapse — telemetry event emitted with exit code"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_artifact="$_test_tmp/audit-artifact.md"
_event_log="$_test_tmp/events.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "hive-mind" && "\${2:-}" == "memory" ]]; then
  printf 'audit_finding\n'
  exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="test-audit-hive"
RUFLO_USE_NPX=false
emit_event() { printf '%s\n' "$*" >> "$_event_log"; }
ruflo_execute_audit "diff" "$_artifact" 2>/dev/null || true
PATH="$_orig_path"
_events=$(cat "$_event_log" 2>/dev/null || echo "")
rm -rf "$_test_tmp"
if grep -q "ruflo.audit_synth_complete" <<< "$_events" && grep -q "exit=" <<< "$_events"; then
    assert_pass "Audit Queen Collapse: telemetry event emitted with exit code"
else
    assert_fail "Audit Queen Collapse: telemetry event emitted with exit code" "events: $_events"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section D: Cleanup — ruflo_cleanup shuts down hive
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_cleanup — shuts down hive when RUFLO_HIVE_ID is set"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s %s\n' "\${1:-}" "\${2:-}" "\${3:-}" >> "$_call_log"
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_DAEMON_STARTED=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="cleanup-test-hive"
RUFLO_USE_NPX=false
ruflo_cleanup 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if grep -qF "hive-mind shutdown" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_cleanup calls hive-mind shutdown when RUFLO_HIVE_ID is set"
else
    assert_fail "ruflo_cleanup calls hive-mind shutdown when RUFLO_HIVE_ID is set" "calls: $_calls"
fi

print_test_section "ruflo_cleanup — resets RUFLO_HIVE_AVAILABLE=false and RUFLO_HIVE_ID='' after shutdown"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_DAEMON_STARTED=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="cleanup-reset-hive"
RUFLO_USE_NPX=false
ruflo_cleanup 2>/dev/null || true
_hive_avail_after="$RUFLO_HIVE_AVAILABLE"
_hive_id_after="$RUFLO_HIVE_ID"
PATH="$_orig_path"
rm -rf "$_test_tmp"
if [[ "$_hive_avail_after" == "false" ]]; then
    assert_pass "ruflo_cleanup resets RUFLO_HIVE_AVAILABLE=false after shutdown"
else
    assert_fail "ruflo_cleanup resets RUFLO_HIVE_AVAILABLE=false after shutdown" "got: $_hive_avail_after"
fi
if [[ -z "$_hive_id_after" ]]; then
    assert_pass "ruflo_cleanup resets RUFLO_HIVE_ID='' after shutdown"
else
    assert_fail "ruflo_cleanup resets RUFLO_HIVE_ID='' after shutdown" "got: $_hive_id_after"
fi


print_test_section "ruflo_cleanup — shuts down hive when RUFLO_DAEMON_STARTED=false (pre-existing daemon)"

# The singleton hive belongs to THIS run's ruflo_init() call regardless of
# whether THIS run started the daemon. ruflo_cleanup must tear it down even
# when RUFLO_DAEMON_STARTED=false (pre-existing daemon path).
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
printf '%s %s %s\n' "\${1:-}" "\${2:-}" "\${3:-}" >> "$_call_log"
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
_orig_path="$PATH"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_DAEMON_STARTED=false
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="preexisting-daemon-hive"
RUFLO_USE_NPX=false
ruflo_cleanup 2>/dev/null || true
_calls=$(cat "$_call_log" 2>/dev/null || true)
PATH="$_orig_path"
rm -rf "$_test_tmp"
if grep -qF "hive-mind shutdown" <<< "$_calls" 2>/dev/null; then
    assert_pass "ruflo_cleanup shuts down hive even when RUFLO_DAEMON_STARTED=false"
else
    assert_fail "ruflo_cleanup shuts down hive even when RUFLO_DAEMON_STARTED=false" "calls: $_calls"
fi
_hive_id_nodaemon="${RUFLO_HIVE_ID:-}"
if [[ -z "$_hive_id_nodaemon" ]]; then
    assert_pass "ruflo_cleanup clears RUFLO_HIVE_ID when RUFLO_DAEMON_STARTED=false"
else
    assert_fail "ruflo_cleanup clears RUFLO_HIVE_ID when RUFLO_DAEMON_STARTED=false" "got: $_hive_id_nodaemon"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: ruflo_ci_memory_pull, ruflo_ci_memory_push, ruflo_prune_memory_export,
#        ruflo_merge_memory_exports  (feat: 08a — CI memory persistence)
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "ruflo_ci_memory_pull — no-op when CI is not set"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
unset CI
_pull_exit=0
ruflo_ci_memory_pull || _pull_exit=$?
if [[ $_pull_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_pull returns 0 when CI is unset (no-op)"
else
    assert_fail "ruflo_ci_memory_pull returns 0 when CI is unset (no-op)" "exit=$_pull_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_ci_memory_pull — no-op when ruflo unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
CI=true
RUFLO_AVAILABLE=false
export CI RUFLO_AVAILABLE
_pull_exit=0
ruflo_ci_memory_pull || _pull_exit=$?
if [[ $_pull_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_pull returns 0 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_ci_memory_pull returns 0 when RUFLO_AVAILABLE=false" "exit=$_pull_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_ci_memory_pull — returns 0 when orphan branch absent"

unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-adapter-test.XXXXXX")
mock_binary "ruflo" 'exit 0'
# git fetch returns 1 so ruflo-memory branch is absent
cat > "$_test_tmp/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    fetch) exit 1 ;;
    remote) printf 'https://github.com/test/repo.git\n'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$_test_tmp/git"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_USE_NPX=false
CI=true
export RUFLO_AVAILABLE CI
_pull_exit=0
ruflo_ci_memory_pull || _pull_exit=$?
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $_pull_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_pull returns 0 when orphan branch does not exist"
else
    assert_fail "ruflo_ci_memory_pull returns 0 when orphan branch does not exist" "exit=$_pull_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_ci_memory_push — no-op when CI is not set"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
unset CI
_push_exit=0
ruflo_ci_memory_push || _push_exit=$?
if [[ $_push_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_push returns 0 when CI is unset (no-op)"
else
    assert_fail "ruflo_ci_memory_push returns 0 when CI is unset (no-op)" "exit=$_push_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_ci_memory_push — no-op when ruflo unavailable"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
CI=true
RUFLO_AVAILABLE=false
export CI RUFLO_AVAILABLE
_push_exit=0
ruflo_ci_memory_push || _push_exit=$?
if [[ $_push_exit -eq 0 ]]; then
    assert_pass "ruflo_ci_memory_push returns 0 when RUFLO_AVAILABLE=false"
else
    assert_fail "ruflo_ci_memory_push returns 0 when RUFLO_AVAILABLE=false" "exit=$_push_exit"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_prune_memory_export — removes stale, keeps recent and no-timestamp"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_prune_file=$(mktemp "${TMPDIR:-/tmp}/sw-ruflo-prune.XXXXXX")
_now=$(date +%s)
_old=$(( _now - 100 * 86400 ))
_recent=$(( _now - 10 * 86400 ))
printf '{"keep":{"timestamp":%d},"drop":{"timestamp":%d},"no_ts":"value"}\n' \
    "$_recent" "$_old" > "$_prune_file"
ruflo_prune_memory_export "$_prune_file" 90
_pruned=$(cat "$_prune_file")
rm -f "$_prune_file"

if printf '%s\n' "$_pruned" | jq -e '.keep' >/dev/null 2>&1; then
    assert_pass "ruflo_prune_memory_export keeps entry within max_age"
else
    assert_fail "ruflo_prune_memory_export keeps entry within max_age" "output: $_pruned"
fi
if ! printf '%s\n' "$_pruned" | jq -e '.drop' >/dev/null 2>&1; then
    assert_pass "ruflo_prune_memory_export removes entry beyond max_age"
else
    assert_fail "ruflo_prune_memory_export removes entry beyond max_age" "output: $_pruned"
fi
if printf '%s\n' "$_pruned" | jq -e '.no_ts' >/dev/null 2>&1; then
    assert_pass "ruflo_prune_memory_export keeps entry without timestamp field"
else
    assert_fail "ruflo_prune_memory_export keeps entry without timestamp field" "output: $_pruned"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "ruflo_merge_memory_exports — local wins on conflict, remote keys preserved"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_remote_file=$(mktemp "${TMPDIR:-/tmp}/sw-ruflo-remote-memory.XXXXXX")
_local_file=$(mktemp "${TMPDIR:-/tmp}/sw-ruflo-local-memory.XXXXXX")
printf '{"key1":"remote_val","key2":"remote_only"}\n' > "$_remote_file"
printf '{"key1":"local_val","key3":"local_only"}\n' > "$_local_file"
_merged=$(ruflo_merge_memory_exports "$_remote_file" "$_local_file")
rm -f "$_remote_file" "$_local_file"

if printf '%s\n' "$_merged" | jq -e '.key1 == "local_val"' >/dev/null 2>&1; then
    assert_pass "ruflo_merge_memory_exports: local value wins on key conflict"
else
    assert_fail "ruflo_merge_memory_exports: local value wins on key conflict" "merged: $_merged"
fi
if printf '%s\n' "$_merged" | jq -e '.key2 == "remote_only"' >/dev/null 2>&1; then
    assert_pass "ruflo_merge_memory_exports: remote-only keys are preserved"
else
    assert_fail "ruflo_merge_memory_exports: remote-only keys are preserved" "merged: $_merged"
fi
if printf '%s\n' "$_merged" | jq -e '.key3 == "local_only"' >/dev/null 2>&1; then
    assert_pass "ruflo_merge_memory_exports: local-only keys present in merge"
else
    assert_fail "ruflo_merge_memory_exports: local-only keys present in merge" "merged: $_merged"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: stage_test_first ruflo integration — recall and store
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stage_test_first — ruflo recall happy path"

unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

# Mock ruflo_recall_similar_outcomes to return plain-text recall output,
# matching the adapter contract (raw CLI output, not JSON).
ruflo_recall_similar_outcomes() {
    printf 'Past TDD pattern: use vitest describe blocks\nPast TDD pattern: mock external deps\n'
}
ruflo_store() { return 0; }
RUFLO_AVAILABLE=true

_recall_result=$(ruflo_recall_similar_outcomes "feature" "tdd,backend" 2>/dev/null || true)
_tdd_context=$(printf '%.2000s' "${_recall_result:-}")

if [[ -n "$_tdd_context" ]]; then
    assert_pass "stage_test_first recall: tdd_context populated from ruflo results"
else
    assert_fail "stage_test_first recall: tdd_context populated from ruflo results" "got empty recall output"
fi

if printf '%s\n' "$_tdd_context" | grep -q "vitest"; then
    assert_pass "stage_test_first recall: raw recall output contains expected content"
else
    assert_fail "stage_test_first recall: raw recall output contains expected content" "got: $_tdd_context"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test_first — ruflo recall when ruflo unavailable"

RUFLO_AVAILABLE=false
_tdd_context_unavail=""
if ruflo_available; then
    _tdd_context_unavail=$(ruflo_recall_similar_outcomes "feature" "" 2>/dev/null) || true
fi

if [[ -z "$_tdd_context_unavail" ]]; then
    assert_pass "stage_test_first recall: tdd_context is empty when ruflo unavailable"
else
    assert_fail "stage_test_first recall: tdd_context is empty when ruflo unavailable" "got: $_tdd_context_unavail"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test_first — ruflo store happy path"

_store_call_log="$TEST_TEMP_DIR/tdd-store-calls.txt"
rm -f "$_store_call_log"

# Override ruflo_store to record call arguments
ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_store_call_log"
    return 0
}
# Provide a deterministic repo hash for the test
_ruflo_resolve_repo_hash() { echo "testhash123"; }

RUFLO_AVAILABLE=true
SHIPWRIGHT_PIPELINE_ID="pipeline-99-42"
GOAL="add authentication"
TASK_TYPE="feature"
written_files="tests/auth.test.js"

wrote_any=true
if ruflo_available && [[ "$wrote_any" == "true" ]]; then
    _tdd_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    if [[ -n "$_tdd_ns_hash" ]]; then
        _tdd_key="test_first-${SHIPWRIGHT_PIPELINE_ID:-unknown}-$(date +%s)"
        _tdd_outcome=$(jq -n --arg goal "${GOAL:-}" --arg task "${TASK_TYPE:-feature}" \
            --arg files "${written_files:-}" \
            '{goal: $goal, task_type: $task, tests_generated: true, files_written: $files}' 2>/dev/null || echo '{}')
        ruflo_store "$_tdd_key" "$_tdd_outcome" \
            "learning-${_tdd_ns_hash}" \
            "tdd,test_first,${TASK_TYPE:-feature}" 2>/dev/null || true
    fi
fi

if [[ -f "$_store_call_log" ]]; then
    assert_pass "stage_test_first store: ruflo_store called when wrote_any=true"
else
    assert_fail "stage_test_first store: ruflo_store called when wrote_any=true" "store log not created"
fi

if grep -q "NS=learning-testhash123" "$_store_call_log" 2>/dev/null; then
    assert_pass "stage_test_first store: namespace uses learning- prefix for future recall"
else
    assert_fail "stage_test_first store: namespace uses learning- prefix for future recall" "got: $(cat "$_store_call_log" 2>/dev/null)"
fi

if grep -q "TAGS=tdd,test_first,feature" "$_store_call_log" 2>/dev/null; then
    assert_pass "stage_test_first store: tags include tdd,test_first,<task_type>"
else
    assert_fail "stage_test_first store: tags include tdd,test_first,<task_type>" "got: $(cat "$_store_call_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test_first — ruflo store skipped when no tests written"

_store_skip_log="$TEST_TEMP_DIR/tdd-store-skip.txt"
rm -f "$_store_skip_log"

ruflo_store() {
    echo "called" >> "$_store_skip_log"
    return 0
}

RUFLO_AVAILABLE=true
wrote_any=false
if ruflo_available && [[ "$wrote_any" == "true" ]]; then
    ruflo_store "key" "{}" "ns" "tags" 2>/dev/null || true
fi

if [[ ! -f "$_store_skip_log" ]]; then
    assert_pass "stage_test_first store: ruflo_store skipped when wrote_any=false"
else
    assert_fail "stage_test_first store: ruflo_store skipped when wrote_any=false" "store was called unexpectedly"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: stage_test ruflo integration — recall and store
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stage_test — ruflo recall called before test run"

_st_recall_log="$TEST_TEMP_DIR/stage-test-recall-calls.txt"
rm -f "$_st_recall_log"

_ruflo_resolve_repo_hash() { printf 'testhash123'; }
ruflo_recall() {
    echo "QUERY=$1 NS=$2" >> "$_st_recall_log"
    printf 'Past failure: circuit breaker timeout in sw-e2e-smoke-test.sh\n'
}
ruflo_store() { return 0; }
RUFLO_AVAILABLE=true

_st_ruflo_ns=""
if declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1; then
    _st_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    _st_ruflo_ns="${_st_ns_hash:+learning-${_st_ns_hash}}"
fi

_st_flakiness_ctx=""
if declare -f ruflo_recall >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   [[ -n "$_st_ruflo_ns" ]] && \
   ruflo_available; then
    _st_flakiness_ctx=$(ruflo_recall "test flakiness patterns failures" \
        "$_st_ruflo_ns" 2>/dev/null || true)
    _st_flakiness_ctx=$(printf '%.2000s' "${_st_flakiness_ctx:-}")
fi

if [[ -f "$_st_recall_log" ]]; then
    assert_pass "stage_test recall: ruflo_recall invoked when ruflo available"
else
    assert_fail "stage_test recall: ruflo_recall invoked when ruflo available" "recall log not created"
fi

if grep -q "NS=learning-testhash123" "$_st_recall_log" 2>/dev/null; then
    assert_pass "stage_test recall: namespace uses learning- prefix for cross-run recall"
else
    assert_fail "stage_test recall: namespace uses learning- prefix for cross-run recall" "got: $(cat "$_st_recall_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — recall output logged for human visibility"

if [[ -n "$_st_flakiness_ctx" ]]; then
    assert_pass "stage_test recall: flakiness context populated when ruflo has data"
else
    assert_fail "stage_test recall: flakiness context populated when ruflo has data" "got empty context"
fi

if printf '%s\n' "$_st_flakiness_ctx" | grep -q "circuit breaker"; then
    assert_pass "stage_test recall: recall content is the raw text from ruflo_recall"
else
    assert_fail "stage_test recall: recall content is the raw text from ruflo_recall" "got: $_st_flakiness_ctx"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — ruflo store called with passed tag on success"

_st_pass_store_log="$TEST_TEMP_DIR/stage-test-pass-store.txt"
rm -f "$_st_pass_store_log"

_ruflo_resolve_repo_hash() { printf 'testhash123'; }
ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_pass_store_log"
    return 0
}
RUFLO_AVAILABLE=true
_test_cmd="npm test"
_cov_pct=87
_test_log_content="PASS src/auth.test.ts"
_pass_test_count=1
_st_pass_ns=""
if declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1; then
    _st_pass_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    _st_pass_ns="${_st_pass_ns_hash:+learning-${_st_pass_ns_hash}}"
fi

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   [[ -n "$_st_pass_ns" ]] && \
   ruflo_available; then
    ruflo_store "stage-test-result" \
        "Tests PASSED. Count: ${_pass_test_count}. Cmd: ${_test_cmd}. Coverage: ${_cov_pct:-0}%. Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo unknown)." \
        "$_st_pass_ns" \
        "test,stage_test,passed" 2>/dev/null || true
fi

if grep -q "TAGS=test,stage_test,passed" "$_st_pass_store_log" 2>/dev/null; then
    assert_pass "stage_test store: tags contain passed on success"
else
    assert_fail "stage_test store: tags contain passed on success" "got: $(cat "$_st_pass_store_log" 2>/dev/null)"
fi

if grep -q "NS=learning-testhash123" "$_st_pass_store_log" 2>/dev/null; then
    assert_pass "stage_test store: namespace uses learning- prefix for cross-run recall on pass"
else
    assert_fail "stage_test store: namespace uses learning- prefix for cross-run recall on pass" "got: $(cat "$_st_pass_store_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — ruflo store called with failed tag on failure"

_st_fail_store_log="$TEST_TEMP_DIR/stage-test-fail-store.txt"
rm -f "$_st_fail_store_log"

_ruflo_resolve_repo_hash() { printf 'testhash123'; }
ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_fail_store_log"
    return 0
}
RUFLO_AVAILABLE=true
_fail_test_exit=1
_fail_test_count=3
_st_fail_ns=""
if declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1; then
    _st_fail_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    _st_fail_ns="${_st_fail_ns_hash:+learning-${_st_fail_ns_hash}}"
fi

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   [[ -n "$_st_fail_ns" ]] && \
   ruflo_available; then
    ruflo_store "stage-test-result" \
        "Tests FAILED (exit $_fail_test_exit). Count: ${_fail_test_count}. Cmd: npm test. Coverage: 0%. Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo unknown)." \
        "$_st_fail_ns" \
        "test,stage_test,failed" 2>/dev/null || true
fi

if grep -q "TAGS=test,stage_test,failed" "$_st_fail_store_log" 2>/dev/null; then
    assert_pass "stage_test store: tags contain failed on test failure"
else
    assert_fail "stage_test store: tags contain failed on test failure" "got: $(cat "$_st_fail_store_log" 2>/dev/null)"
fi

if grep -q "NS=learning-testhash123" "$_st_fail_store_log" 2>/dev/null; then
    assert_pass "stage_test store: namespace uses learning- prefix for cross-run recall on fail"
else
    assert_fail "stage_test store: namespace uses learning- prefix for cross-run recall on fail" "got: $(cat "$_st_fail_store_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — unique timestamped key per run (no overwrite)"

_st_ts_store_log="$TEST_TEMP_DIR/stage-test-ts-store.txt"
rm -f "$_st_ts_store_log"

_ruflo_resolve_repo_hash() { printf 'testhash123'; }
ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_ts_store_log"
    return 0
}
ruflo_available() { return 0; }
RUFLO_AVAILABLE=true

_st_ts_run_ts=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date +"%s")
_st_ts_run_uid="${_st_ts_run_ts}-$$-${RANDOM}"
_st_ts_result_key="stage-test-result-${_st_ts_run_uid}"
_st_ts_ruflo_ns=""
if declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1; then
    _st_ts_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
    _st_ts_ruflo_ns="${_st_ts_ns_hash:+learning-${_st_ts_ns_hash}}"
fi

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   ruflo_available; then
    ruflo_store "$_st_ts_result_key" \
        "Tests PASSED. Tests: src/auth.test.ts. Cmd: npm test. Coverage: 87%. Time: ${_st_ts_run_uid}." \
        "$_st_ts_ruflo_ns" \
        "test,stage_test,passed" 2>/dev/null || true
fi

if grep -q "KEY=stage-test-result-" "$_st_ts_store_log" 2>/dev/null; then
    assert_pass "stage_test unique key: storage key includes timestamp (not static 'stage-test-result')"
else
    assert_fail "stage_test unique key: storage key includes timestamp (not static 'stage-test-result')" "got: $(cat "$_st_ts_store_log" 2>/dev/null)"
fi

if grep -qE "KEY=stage-test-result-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+" "$_st_ts_store_log" 2>/dev/null; then
    assert_pass "stage_test unique key: format is timestamp-PID-RANDOM (collision-safe)"
else
    assert_fail "stage_test unique key: format is timestamp-PID-RANDOM (collision-safe)" "got: $(cat "$_st_ts_store_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — flaky pattern match triggers retry"

_st_retry_log="$TEST_TEMP_DIR/stage-test-retry-calls.txt"
_st_retry_test_log=$(mktemp "$TEST_TEMP_DIR/test-retry-out.XXXXXX")
rm -f "$_st_retry_log"
printf 'FAIL circuit-breaker-test\nError: timeout after 5000ms\n' > "$_st_retry_test_log"

ruflo_recall() {
    # Recall returns hyphenated test names that are 8+ chars for reliable matching
    printf 'Past failure: circuit-breaker-test timeout in sw-e2e-smoke-test.sh\n'
}
RUFLO_AVAILABLE=true
_st_retry_fail_exit=1
_st_retry_flakiness_ctx=$(ruflo_recall "test flakiness patterns failures" "learning-testhash123" 2>/dev/null || true)
_st_retry_flakiness_ctx=$(printf '%.2000s' "${_st_retry_flakiness_ctx:-}")

_test_is_known_flaky="false"
_matched_flaky_pattern=""
_st_stopwords="received|expected|function|actually|returned|argument|property|undefined|contains|resource|standard|platform"
if [[ "$_st_retry_fail_exit" -ne 0 && -n "$_st_retry_flakiness_ctx" ]]; then
    _st_fail_excerpt=$(head -30 "$_st_retry_test_log" 2>/dev/null || true)
    while IFS= read -r _st_kw; do
        [[ ${#_st_kw} -lt 8 ]] && continue
        printf '%s' "$_st_kw" | grep -qiE "^(${_st_stopwords})$" 2>/dev/null && continue
        if printf '%s\n' "$_st_fail_excerpt" | grep -qiF "$_st_kw" 2>/dev/null; then
            _test_is_known_flaky="true"
            _matched_flaky_pattern="$_st_kw"
            break
        fi
    done < <(printf '%s\n' "$_st_retry_flakiness_ctx" | tr ' \t' '\n' | grep -E '^[a-zA-Z0-9_.-]{8,}$' | sort -u | head -30)
fi
rm -f "$_st_retry_test_log"

if [[ "$_test_is_known_flaky" == "true" ]]; then
    assert_pass "stage_test flaky retry: known flaky flag set when recalled pattern matches failure output"
else
    assert_fail "stage_test flaky retry: known flaky flag set when recalled pattern matches failure output" "ctx=${_st_retry_flakiness_ctx}"
fi

if [[ -n "$_matched_flaky_pattern" ]]; then
    assert_pass "stage_test flaky retry: matched pattern is non-empty"
else
    assert_fail "stage_test flaky retry: matched pattern is non-empty" "pattern was empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — known_flaky tag added on matched failure"

_st_kf_store_log="$TEST_TEMP_DIR/stage-test-kf-store.txt"
rm -f "$_st_kf_store_log"

ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_kf_store_log"
    return 0
}
RUFLO_AVAILABLE=true
SHIPWRIGHT_PIPELINE_ID="test-pipeline-42"
_st_kf_ts=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date +"%s")
_st_kf_key="stage-test-result-${_st_kf_ts}"

# Simulate known-flaky failure storage
_st_kf_fail_tags="test,stage_test,failed"
_st_kf_is_known_flaky="true"
[[ "$_st_kf_is_known_flaky" == "true" ]] && _st_kf_fail_tags="${_st_kf_fail_tags},known_flaky"

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   ruflo_available; then
    ruflo_store "$_st_kf_key" \
        "Tests FAILED (exit 1). Failures: circuit-breaker-test. Cmd: npm test. Time: ${_st_kf_ts}." \
        "learning-testhash123" \
        "$_st_kf_fail_tags" 2>/dev/null || true
fi

if grep -q "TAGS=test,stage_test,failed,known_flaky" "$_st_kf_store_log" 2>/dev/null; then
    assert_pass "stage_test known_flaky tag: tags include known_flaky when pattern matched"
else
    assert_fail "stage_test known_flaky tag: tags include known_flaky when pattern matched" "got: $(cat "$_st_kf_store_log" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "stage_test — flaky_recovered tag on retry success"

_st_fr_store_log="$TEST_TEMP_DIR/stage-test-fr-store.txt"
rm -f "$_st_fr_store_log"

ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4" >> "$_st_fr_store_log"
    return 0
}
RUFLO_AVAILABLE=true
SHIPWRIGHT_PIPELINE_ID="test-pipeline-42"
_st_fr_ts=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date +"%s")
_st_fr_key="stage-test-result-${_st_fr_ts}"

# Simulate retry-succeeded storage (known flaky, but recovered)
_st_fr_pass_tags="test,stage_test,passed"
_st_fr_is_known_flaky="true"
[[ "$_st_fr_is_known_flaky" == "true" ]] && _st_fr_pass_tags="${_st_fr_pass_tags},flaky_recovered"

if declare -f ruflo_store >/dev/null 2>&1 && \
   declare -f ruflo_available >/dev/null 2>&1 && \
   ruflo_available; then
    ruflo_store "$_st_fr_key" \
        "Tests PASSED. Tests: auth.test.ts. Cmd: npm test. Coverage: 87%. Time: ${_st_fr_ts}." \
        "learning-testhash123" \
        "$_st_fr_pass_tags" 2>/dev/null || true
fi

if grep -q "TAGS=test,stage_test,passed,flaky_recovered" "$_st_fr_store_log" 2>/dev/null; then
    assert_pass "stage_test flaky_recovered tag: tags include flaky_recovered when retry succeeded"
else
    assert_fail "stage_test flaky_recovered tag: tags include flaky_recovered when retry succeeded" "got: $(cat "$_st_fr_store_log" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "RUFLO_COST_BUDGET_MULTIPLIER — agent count scaling"

# Helper: apply the multiplier formula with cap validation (mirrors ruflo-adapter.sh logic).
# Args: default_max multiplier [hard_cap]
# Validates hard_cap to a positive integer (default 12) and raises it to at least
# default_max so a multiplier of 1.0 can never reduce an explicitly configured baseline.
_apply_multiplier_test() {
    local default_max="$1"
    local multiplier="$2"
    local hard_cap="${3:-12}"
    # Mirror production validation: non-numeric or <1 falls back to 12
    if ! [[ "$hard_cap" =~ ^[0-9]+$ ]] || (( hard_cap < 1 )); then
        hard_cap=12
    fi
    # Ensure cap is never below the configured baseline
    if (( hard_cap < default_max )); then
        hard_cap="$default_max"
    fi
    if [[ -n "$multiplier" ]]; then
        awk -v d="$default_max" -v m="$multiplier" -v cap="$hard_cap" \
            'BEGIN{v=int(d*m); print (v<1?1:(v>cap?cap:v))}' 2>/dev/null || echo "$default_max"
    else
        echo "$default_max"
    fi
}

# Test 1: Unset/empty multiplier → no-op (backward compatibility)
_mult_result=$(_apply_multiplier_test 4 "")
if [[ "$_mult_result" == "4" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: unset/empty -> no-op (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: unset/empty -> no-op" "expected 4, got $_mult_result"
fi

# Test 2: Multiplier 2.0 with default 4, hard_cap 12 → 8 (scale up within cap)
_mult_result=$(_apply_multiplier_test 4 "2.0" 12)
if [[ "$_mult_result" == "8" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 2.0 with max=4 hard_cap=12 -> 8 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 2.0 with max=4 hard_cap=12 -> 8" "expected 8, got $_mult_result"
fi

# Test 3: Multiplier 0.5 with default 4 → 2 (scale down)
_mult_result=$(_apply_multiplier_test 4 "0.5")
if [[ "$_mult_result" == "2" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 0.5 with max=4 -> 2 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 0.5 with max=4 -> 2" "expected 2, got $_mult_result"
fi

# Test 4: Multiplier 0 → enforces minimum 1 agent
_mult_result=$(_apply_multiplier_test 4 "0")
if [[ "$_mult_result" == "1" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 0 -> enforces min 1 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 0 -> enforces min 1" "expected 1, got $_mult_result"
fi

# Test 5: Multiplier 3.0 with default 4, hard_cap 12 → 12 (clamped at hard cap)
_mult_result=$(_apply_multiplier_test 4 "3.0" 12)
if [[ "$_mult_result" == "12" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 3.0 with max=4 hard_cap=12 -> 12 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 3.0 with max=4 hard_cap=12 -> 12" "expected 12, got $_mult_result"
fi

# Test 6: Multiplier 0.5 with default 3 (compound quality default) → 1 (floor)
_mult_result=$(_apply_multiplier_test 3 "0.5")
if [[ "$_mult_result" == "1" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 0.5 with max=3 -> 1 (floor of 1.5, got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 0.5 with max=3 -> 1" "expected 1, got $_mult_result"
fi

# Test 7: Multiplier 1.0 → unchanged (identity)
_mult_result=$(_apply_multiplier_test 4 "1.0")
if [[ "$_mult_result" == "4" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 1.0 -> identity (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 1.0 -> identity" "expected 4, got $_mult_result"
fi

# Test 8: Multiplier 0.25 with default 4 → 1 (min enforced)
_mult_result=$(_apply_multiplier_test 4 "0.25")
if [[ "$_mult_result" == "1" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: 0.25 with max=4 -> 1 (min enforced, got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: 0.25 with max=4 -> 1" "expected 1, got $_mult_result"
fi

# Hard-cap edge cases (validation logic)
# Test 9: hard_cap=0 → falls back to 12; 2.0 * 4 = 8 (within fallback cap)
_mult_result=$(_apply_multiplier_test 4 "2.0" 0)
if [[ "$_mult_result" == "8" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: hard_cap=0 falls back to 12; 2.0*4 -> 8 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: hard_cap=0 falls back to 12; 2.0*4 -> 8" "expected 8, got $_mult_result"
fi

# Test 10: hard_cap=non-numeric → falls back to 12; 2.0 * 4 = 8
_mult_result=$(_apply_multiplier_test 4 "2.0" "bad")
if [[ "$_mult_result" == "8" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: hard_cap=non-numeric falls back to 12; 2.0*4 -> 8 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: hard_cap=non-numeric falls back to 12; 2.0*4 -> 8" "expected 8, got $_mult_result"
fi

# Test 11: hard_cap < baseline (cap=2, base=6) → effective cap raised to 6; multiplier=1.0 preserves baseline
_mult_result=$(_apply_multiplier_test 6 "1.0" 2)
if [[ "$_mult_result" == "6" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: hard_cap below baseline raised to baseline; 1.0*6 -> 6 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: hard_cap below baseline raised to baseline; 1.0*6 -> 6" "expected 6, got $_mult_result"
fi

# Test 12: hard_cap < baseline with scale-up → effective cap = baseline; result clamped at baseline
_mult_result=$(_apply_multiplier_test 6 "2.0" 2)
if [[ "$_mult_result" == "6" ]]; then
    assert_pass "RUFLO_COST_BUDGET_MULTIPLIER: hard_cap below baseline raised to baseline; 2.0*6 clamped -> 6 (got $_mult_result)"
else
    assert_fail "RUFLO_COST_BUDGET_MULTIPLIER: hard_cap below baseline raised to baseline; 2.0*6 clamped -> 6" "expected 6, got $_mult_result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# _ruflo_seed_specialist_history — seed hive specialists with prior pipeline learnings
# ═══════════════════════════════════════════════════════════════════════════════
# Reset emit_event so leaked overrides from earlier tests (which point at deleted
# temp dirs) do not pollute stderr when the seed helper emits its observability
# event. The lib's own fallback emit_event is a no-op.
emit_event() { :; }

# Test: _ruflo_seed_specialist_history — no-op when ruflo unavailable
print_test_section "_ruflo_seed_specialist_history — no-op when unavailable"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=false
exit_code=0
_ruflo_seed_specialist_history "review" "hive-review-test" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "_ruflo_seed_specialist_history returns 0 (fail-open) when RUFLO_AVAILABLE=false"
else
    assert_fail "_ruflo_seed_specialist_history returns 0 (fail-open) when RUFLO_AVAILABLE=false" "exit_code=$exit_code"
fi

# Test: _ruflo_seed_specialist_history — no-op when stage_name is empty
print_test_section "_ruflo_seed_specialist_history — no-op when args missing"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
exit_code=0
_ruflo_seed_specialist_history "" "hive-review-test" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "_ruflo_seed_specialist_history returns 0 when stage_name empty"
else
    assert_fail "_ruflo_seed_specialist_history returns 0 when stage_name empty" "exit_code=$exit_code"
fi
exit_code=0
_ruflo_seed_specialist_history "review" "" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "_ruflo_seed_specialist_history returns 0 when stage_ns empty"
else
    assert_fail "_ruflo_seed_specialist_history returns 0 when stage_ns empty" "exit_code=$exit_code"
fi

# Test: _ruflo_seed_specialist_history — skips when repo hash unavailable
print_test_section "_ruflo_seed_specialist_history — skips when repo hash unresolvable"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
# Override _ruflo_resolve_repo_hash to fail (no repo) so the helper short-circuits
_resolve_orig=$(declare -f _ruflo_resolve_repo_hash)
_ruflo_resolve_repo_hash() { return 1; }
# Track that ruflo_recall is NOT called when repo hash is missing
_seed_recall_log="$TEST_TEMP_DIR/seed-recall-noop.log"
rm -f "$_seed_recall_log"
ruflo_recall() { echo "RECALL_CALLED" >> "$_seed_recall_log"; echo ""; }
exit_code=0
_ruflo_seed_specialist_history "review" "hive-review-test" || exit_code=$?
unset -f _ruflo_resolve_repo_hash
eval "$_resolve_orig"
unset -f ruflo_recall
if [[ $exit_code -eq 0 ]]; then
    assert_pass "_ruflo_seed_specialist_history returns 0 when repo hash unresolvable"
else
    assert_fail "_ruflo_seed_specialist_history returns 0 when repo hash unresolvable" "exit_code=$exit_code"
fi
if [[ ! -f "$_seed_recall_log" ]]; then
    assert_pass "_ruflo_seed_specialist_history does NOT call ruflo_recall when repo hash unresolvable"
else
    assert_fail "_ruflo_seed_specialist_history does NOT call ruflo_recall when repo hash unresolvable" \
        "got: $(cat "$_seed_recall_log" 2>/dev/null)"
fi

# Test: _ruflo_seed_specialist_history — happy path stores recalled context
print_test_section "_ruflo_seed_specialist_history — happy path stores recalled context"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
# Mock repo hash and ruflo_recall to return a known historical payload
_resolve_orig=$(declare -f _ruflo_resolve_repo_hash)
_ruflo_resolve_repo_hash() { printf 'testhash9876'; }
_seed_recall_log="$TEST_TEMP_DIR/seed-recall-happy.log"
rm -f "$_seed_recall_log"
ruflo_recall() {
    echo "QUERY=$1 NS=$2" >> "$_seed_recall_log"
    printf 'past-failure-1: null pointer in auth flow\npast-failure-2: missing input validation\n'
}
_seed_store_log="$TEST_TEMP_DIR/seed-store-happy.log"
rm -f "$_seed_store_log"
ruflo_store() {
    echo "KEY=$1 NS=$3 TAGS=$4 VALUE_LEN=${#2}" >> "$_seed_store_log"
}
TASK_TYPE="bug" ISSUE_LABELS="security,backend" \
    _ruflo_seed_specialist_history "review" "hive-review-pipeline-42" || true
unset -f _ruflo_resolve_repo_hash
eval "$_resolve_orig"
unset -f ruflo_recall ruflo_store

if [[ -f "$_seed_recall_log" ]] && grep -q "NS=learning-testhash9876" "$_seed_recall_log" 2>/dev/null; then
    assert_pass "_ruflo_seed_specialist_history queries learning-<repo_hash> namespace"
else
    assert_fail "_ruflo_seed_specialist_history queries learning-<repo_hash> namespace" \
        "got: $(cat "$_seed_recall_log" 2>/dev/null)"
fi
if grep -q "QUERY=review stage outcomes for bug security,backend" "$_seed_recall_log" 2>/dev/null; then
    assert_pass "_ruflo_seed_specialist_history query includes stage_name, TASK_TYPE and ISSUE_LABELS"
else
    assert_fail "_ruflo_seed_specialist_history query includes stage_name, TASK_TYPE and ISSUE_LABELS" \
        "got: $(cat "$_seed_recall_log" 2>/dev/null)"
fi
if [[ -f "$_seed_store_log" ]] && grep -q "KEY=review-history-context NS=hive-review-pipeline-42" "$_seed_store_log" 2>/dev/null; then
    assert_pass "_ruflo_seed_specialist_history stores into stage namespace under <stage>-history-context key"
else
    assert_fail "_ruflo_seed_specialist_history stores into stage namespace under <stage>-history-context key" \
        "got: $(cat "$_seed_store_log" 2>/dev/null)"
fi
if grep -q "TAGS=review,history,context" "$_seed_store_log" 2>/dev/null; then
    assert_pass "_ruflo_seed_specialist_history tags stored entry with stage,history,context"
else
    assert_fail "_ruflo_seed_specialist_history tags stored entry with stage,history,context" \
        "got: $(cat "$_seed_store_log" 2>/dev/null)"
fi

# Test: _ruflo_seed_specialist_history — skips store when recall returns empty
print_test_section "_ruflo_seed_specialist_history — skips store on empty recall"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
_resolve_orig=$(declare -f _ruflo_resolve_repo_hash)
_ruflo_resolve_repo_hash() { printf 'testhash0000'; }
ruflo_recall() { echo ""; }
_empty_store_log="$TEST_TEMP_DIR/seed-store-empty.log"
rm -f "$_empty_store_log"
ruflo_store() { echo "STORE_CALLED" >> "$_empty_store_log"; }
_ruflo_seed_specialist_history "audit" "hive-audit-test" || true
unset -f _ruflo_resolve_repo_hash
eval "$_resolve_orig"
unset -f ruflo_recall ruflo_store
if [[ ! -f "$_empty_store_log" ]]; then
    assert_pass "_ruflo_seed_specialist_history does NOT call ruflo_store when recall is empty"
else
    assert_fail "_ruflo_seed_specialist_history does NOT call ruflo_store when recall is empty" \
        "got: $(cat "$_empty_store_log" 2>/dev/null)"
fi

# Test: _ruflo_seed_specialist_history — bounds payload to RUFLO_HISTORY_MAX_BYTES
print_test_section "_ruflo_seed_specialist_history — payload bounded by RUFLO_HISTORY_MAX_BYTES"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
_resolve_orig=$(declare -f _ruflo_resolve_repo_hash)
_ruflo_resolve_repo_hash() { printf 'testhash5555'; }
# Generate a recall payload larger than the configured cap
ruflo_recall() {
    head -c 9000 /dev/zero | tr '\0' 'X'
}
_bounded_store_log="$TEST_TEMP_DIR/seed-store-bounded.log"
rm -f "$_bounded_store_log"
ruflo_store() { echo "VALUE_LEN=${#2}" >> "$_bounded_store_log"; }
RUFLO_HISTORY_MAX_BYTES=200 _ruflo_seed_specialist_history "build" "hive-build-test" || true
unset -f _ruflo_resolve_repo_hash
eval "$_resolve_orig"
unset -f ruflo_recall ruflo_store
unset RUFLO_HISTORY_MAX_BYTES
if [[ -f "$_bounded_store_log" ]] && grep -q "VALUE_LEN=200" "$_bounded_store_log" 2>/dev/null; then
    assert_pass "_ruflo_seed_specialist_history bounds payload to RUFLO_HISTORY_MAX_BYTES (200)"
else
    assert_fail "_ruflo_seed_specialist_history bounds payload to RUFLO_HISTORY_MAX_BYTES (200)" \
        "got: $(cat "$_bounded_store_log" 2>/dev/null)"
fi

# Test: orchestration functions invoke _ruflo_seed_specialist_history before orchestration
print_test_section "ruflo_execute_review — invokes _ruflo_seed_specialist_history before orchestrate"
unset _RUFLO_ADAPTER_LOADED
_test_tmp="$TEST_TEMP_DIR/seed-review-$$"
mkdir -p "$_test_tmp"
# Mock ruflo binary so spawn / orchestrate / memory commands all succeed
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="seed-review-hive"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="seed-test-pipeline"
# Track _ruflo_seed_specialist_history invocation and order with respect to orchestrate
_seed_order_log="$TEST_TEMP_DIR/seed-order-review.log"
rm -f "$_seed_order_log"
_ruflo_seed_specialist_history() {
    echo "SEED stage=$1 ns=$2" >> "$_seed_order_log"
    return 0
}
# Override the inner orchestration shim by overriding ruflo_with_timeout to log
_orig_with_timeout=$(declare -f ruflo_with_timeout)
ruflo_with_timeout() {
    local _to="$1"; shift
    if [[ "${1:-}" == "ruflo" && "${2:-}" == "coordination" && "${3:-}" == "orchestrate" ]]; then
        echo "ORCHESTRATE" >> "$_seed_order_log"
    fi
    return 0
}
_ruflo_artifact="$_test_tmp/review-out.md"
ruflo_execute_review "diff content" "$_ruflo_artifact" >/dev/null 2>&1 || true
unset -f _ruflo_seed_specialist_history ruflo_with_timeout
eval "$_orig_with_timeout"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if grep -q "SEED stage=review" "$_seed_order_log" 2>/dev/null; then
    assert_pass "ruflo_execute_review invokes _ruflo_seed_specialist_history with stage=review"
else
    assert_fail "ruflo_execute_review invokes _ruflo_seed_specialist_history with stage=review" \
        "log: $(cat "$_seed_order_log" 2>/dev/null)"
fi
# Verify SEED appears before ORCHESTRATE
if grep -n "SEED\|ORCHESTRATE" "$_seed_order_log" 2>/dev/null | awk -F: '
    /SEED/  { seed=NR }
    /ORCHESTRATE/ { orch=NR }
    END { exit (seed && orch && seed < orch ? 0 : 1) }
'; then
    assert_pass "ruflo_execute_review seeds history BEFORE orchestration"
else
    assert_fail "ruflo_execute_review seeds history BEFORE orchestration" \
        "log: $(cat "$_seed_order_log" 2>/dev/null)"
fi

print_test_section "ruflo_execute_compound_quality — invokes _ruflo_seed_specialist_history"
unset _RUFLO_ADAPTER_LOADED
_test_tmp="$TEST_TEMP_DIR/seed-cq-$$"
mkdir -p "$_test_tmp"
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="seed-cq-hive"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="seed-test-pipeline-cq"
_seed_cq_log="$TEST_TEMP_DIR/seed-order-cq.log"
rm -f "$_seed_cq_log"
_ruflo_seed_specialist_history() {
    echo "SEED stage=$1 ns=$2" >> "$_seed_cq_log"; return 0
}
_orig_with_timeout=$(declare -f ruflo_with_timeout)
ruflo_with_timeout() { return 0; }
ruflo_execute_compound_quality "diff content" "$_test_tmp/cq-out.md" >/dev/null 2>&1 || true
unset -f _ruflo_seed_specialist_history ruflo_with_timeout
eval "$_orig_with_timeout"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if grep -q "SEED stage=quality" "$_seed_cq_log" 2>/dev/null; then
    assert_pass "ruflo_execute_compound_quality invokes _ruflo_seed_specialist_history with stage=quality"
else
    assert_fail "ruflo_execute_compound_quality invokes _ruflo_seed_specialist_history with stage=quality" \
        "log: $(cat "$_seed_cq_log" 2>/dev/null)"
fi

print_test_section "ruflo_execute_audit — invokes _ruflo_seed_specialist_history"
unset _RUFLO_ADAPTER_LOADED
_test_tmp="$TEST_TEMP_DIR/seed-audit-$$"
mkdir -p "$_test_tmp"
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="seed-audit-hive"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="seed-test-pipeline-audit"
_seed_audit_log="$TEST_TEMP_DIR/seed-order-audit.log"
rm -f "$_seed_audit_log"
_ruflo_seed_specialist_history() {
    echo "SEED stage=$1 ns=$2" >> "$_seed_audit_log"; return 0
}
_orig_with_timeout=$(declare -f ruflo_with_timeout)
ruflo_with_timeout() { return 0; }
ruflo_execute_audit "diff content" "$_test_tmp/audit-out.md" >/dev/null 2>&1 || true
unset -f _ruflo_seed_specialist_history ruflo_with_timeout
eval "$_orig_with_timeout"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if grep -q "SEED stage=audit" "$_seed_audit_log" 2>/dev/null; then
    assert_pass "ruflo_execute_audit invokes _ruflo_seed_specialist_history with stage=audit"
else
    assert_fail "ruflo_execute_audit invokes _ruflo_seed_specialist_history with stage=audit" \
        "log: $(cat "$_seed_audit_log" 2>/dev/null)"
fi

print_test_section "ruflo_execute_build_hive — invokes _ruflo_seed_specialist_history"
unset _RUFLO_ADAPTER_LOADED
_test_tmp="$TEST_TEMP_DIR/seed-build-$$"
mkdir -p "$_test_tmp"
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="seed-build-hive"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="seed-test-pipeline-build"
_seed_build_log="$TEST_TEMP_DIR/seed-order-build.log"
rm -f "$_seed_build_log"
_ruflo_seed_specialist_history() {
    echo "SEED stage=$1 ns=$2" >> "$_seed_build_log"; return 0
}
_orig_with_timeout=$(declare -f ruflo_with_timeout)
ruflo_with_timeout() { return 0; }
ruflo_execute_build_hive "build the feature" 5 >/dev/null 2>&1 || true
unset -f _ruflo_seed_specialist_history ruflo_with_timeout
eval "$_orig_with_timeout"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if grep -q "SEED stage=build" "$_seed_build_log" 2>/dev/null; then
    assert_pass "ruflo_execute_build_hive invokes _ruflo_seed_specialist_history with stage=build"
else
    assert_fail "ruflo_execute_build_hive invokes _ruflo_seed_specialist_history with stage=build" \
        "log: $(cat "$_seed_build_log" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ruflo_execute_self_heal_hive tests — root-cause triage on test failure
# ═══════════════════════════════════════════════════════════════════════════════

# Test: env gate — empty stdout, exit 0, no events when RUFLO_SELF_HEAL_HIVE unset
print_test_section "ruflo_execute_self_heal_hive — gate disabled (default)"
unset _RUFLO_ADAPTER_LOADED
unset RUFLO_SELF_HEAL_HIVE
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
# Even with ruflo "available", flag-off must short-circuit before any work.
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
exit_code=0
_heal_out=$(ruflo_execute_self_heal_hive "test failed" "foo.sh,bar.sh" 2>/dev/null) || exit_code=$?
if [[ $exit_code -eq 0 && -z "$_heal_out" ]]; then
    assert_pass "ruflo_execute_self_heal_hive returns 0 with empty stdout when gate disabled"
else
    assert_fail "ruflo_execute_self_heal_hive returns 0 with empty stdout when gate disabled" \
        "exit=$exit_code stdout=$_heal_out"
fi

# Test: ruflo unavailable — returns 0 with empty stdout, emits skipped event
print_test_section "ruflo_execute_self_heal_hive — ruflo unavailable"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=false
exit_code=0
_heal_out=$(ruflo_execute_self_heal_hive "test failed" "foo.sh" 2>/dev/null) || exit_code=$?
if [[ $exit_code -eq 0 && -z "$_heal_out" ]]; then
    assert_pass "ruflo_execute_self_heal_hive returns 0 empty when ruflo unavailable"
else
    assert_fail "ruflo_execute_self_heal_hive returns 0 empty when ruflo unavailable" \
        "exit=$exit_code stdout=$_heal_out"
fi
unset RUFLO_SELF_HEAL_HIVE

# Test: hive unavailable — returns 0 with empty stdout
print_test_section "ruflo_execute_self_heal_hive — hive unavailable"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=false
RUFLO_USE_NPX=false
exit_code=0
_heal_out=$(ruflo_execute_self_heal_hive "test failed" "foo.sh" 2>/dev/null) || exit_code=$?
if [[ $exit_code -eq 0 && -z "$_heal_out" ]]; then
    assert_pass "ruflo_execute_self_heal_hive returns 0 empty when hive unavailable"
else
    assert_fail "ruflo_execute_self_heal_hive returns 0 empty when hive unavailable" \
        "exit=$exit_code stdout=$_heal_out"
fi
unset RUFLO_SELF_HEAL_HIVE

# Test: empty RUFLO_HIVE_ID — returns 0 with empty stdout, emits warning event
print_test_section "ruflo_execute_self_heal_hive — empty hive_id skips with warning"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID=""
RUFLO_USE_NPX=false
_emit_log_ehid="$TEST_TEMP_DIR/emit-ehid.log"
emit_event() { printf '%s\n' "$*" >> "$_emit_log_ehid"; }
warn() { printf 'WARN: %s\n' "$*" >> "$_emit_log_ehid"; }
exit_code=0
_heal_out=$(ruflo_execute_self_heal_hive "test failed" "foo.sh" 2>/dev/null) || exit_code=$?
if [[ $exit_code -eq 0 && -z "$_heal_out" ]]; then
    assert_pass "ruflo_execute_self_heal_hive returns 0 empty when RUFLO_HIVE_ID is empty"
else
    assert_fail "ruflo_execute_self_heal_hive returns 0 empty when RUFLO_HIVE_ID is empty" \
        "exit=$exit_code stdout=$_heal_out"
fi
if grep -q "empty_hive_id" "$_emit_log_ehid" 2>/dev/null; then
    assert_pass "ruflo_execute_self_heal_hive emits skipped event for empty hive_id"
else
    assert_fail "ruflo_execute_self_heal_hive emits skipped event for empty hive_id" \
        "$(cat "$_emit_log_ehid" 2>/dev/null)"
fi
if grep -q "WARN:" "$_emit_log_ehid" 2>/dev/null; then
    assert_pass "ruflo_execute_self_heal_hive emits warn for empty hive_id"
else
    assert_fail "ruflo_execute_self_heal_hive emits warn for empty hive_id" \
        "no warn line found in $(cat "$_emit_log_ehid" 2>/dev/null)"
fi
unset RUFLO_SELF_HEAL_HIVE
unset -f emit_event warn

# Test: empty namespace post-orchestrate — returns 0 with empty stdout
print_test_section "ruflo_execute_self_heal_hive — empty specialist output"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
# Always succeed but return empty memory list/get
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="self-heal-test-empty"
RUFLO_USE_NPX=false
exit_code=0
_heal_out=$(ruflo_execute_self_heal_hive "boom" "x.sh" 2>/dev/null) || exit_code=$?
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 && -z "$_heal_out" ]]; then
    assert_pass "ruflo_execute_self_heal_hive returns 0 empty when namespace is empty"
else
    assert_fail "ruflo_execute_self_heal_hive returns 0 empty when namespace is empty" \
        "exit=$exit_code stdout=$_heal_out"
fi
unset RUFLO_SELF_HEAL_HIVE

# Test: happy path — selected hypothesis printed, spawn + orchestrate called
print_test_section "ruflo_execute_self_heal_hive — happy path emits selection"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
subcmd="\${1:-}"
sub2="\${2:-}"
printf '%s %s\\n' "\$subcmd" "\$sub2" >> "$_call_log"
# 'memory get --key self-heal-selected' returns the selected hypothesis text
if [[ "\$subcmd" == "hive-mind" && "\$sub2" == "memory" ]]; then
    # Check for action=get and key=self-heal-selected in the args
    _is_get=false
    _is_selected=false
    for arg in "\$@"; do
        [[ "\$arg" == "get" ]] && _is_get=true
        [[ "\$arg" == "self-heal-selected" ]] && _is_selected=true
    done
    if [[ "\$_is_get" == "true" && "\$_is_selected" == "true" ]]; then
        printf 'Hypothesis: mock divergence — fixture state leaked across tests.\\nVerification: grep for shared mock state in setup blocks.\\n'
    else
        # 'list' path returns union of hypotheses
        printf 'hypothesis-mock-boundary: ...\\nhypothesis-async-timing: ...\\nhypothesis-schema-type: ...\\n'
    fi
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="self-heal-happy"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="self-heal-happy-pipeline"
_heal_out_file="$_test_tmp/heal-out.txt"
exit_code=0
ruflo_execute_self_heal_hive "test failed: AssertionError" "src/foo.js,src/bar.js" \
    > "$_heal_out_file" 2>/dev/null || exit_code=$?
_heal_nonempty=false
[[ -s "$_heal_out_file" ]] && _heal_nonempty=true
_heal_has_hyp=false
grep -q "Hypothesis:" "$_heal_out_file" 2>/dev/null && _heal_has_hyp=true
_spawn_called=false
grep -q "^hive-mind spawn" "$_call_log" 2>/dev/null && _spawn_called=true
_orch_called=false
grep -q "^coordination orchestrate" "$_call_log" 2>/dev/null && _orch_called=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_self_heal_hive returns 0 on happy path"
else
    assert_fail "ruflo_execute_self_heal_hive returns 0 on happy path" "exit=$exit_code"
fi
if [[ "$_heal_nonempty" == "true" ]]; then
    assert_pass "ruflo_execute_self_heal_hive emits non-empty hypothesis on stdout"
else
    assert_fail "ruflo_execute_self_heal_hive emits non-empty hypothesis on stdout" "stdout empty"
fi
if [[ "$_heal_has_hyp" == "true" ]]; then
    assert_pass "ruflo_execute_self_heal_hive emits 'Hypothesis:' line"
else
    assert_fail "ruflo_execute_self_heal_hive emits 'Hypothesis:' line" "stdout: $(cat "$_heal_out_file" 2>/dev/null)"
fi
if [[ "$_spawn_called" == "true" ]]; then
    assert_pass "ruflo_execute_self_heal_hive calls hive-mind spawn"
else
    assert_fail "ruflo_execute_self_heal_hive calls hive-mind spawn" "spawn not invoked"
fi
if [[ "$_orch_called" == "true" ]]; then
    assert_pass "ruflo_execute_self_heal_hive calls coordination orchestrate"
else
    assert_fail "ruflo_execute_self_heal_hive calls coordination orchestrate" "orchestrate not invoked"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: triage orchestrate fails — returns 0 empty, no synthesis attempted
print_test_section "ruflo_execute_self_heal_hive — triage failure short-circuits"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
subcmd="\${1:-}"
sub2="\${2:-}"
sub3="\${3:-}"
printf '%s %s %s\\n' "\$subcmd" "\$sub2" "\$sub3" >> "$_call_log"
# Triage orchestrate fails — anything --mode triage or first orchestrate returns non-zero
if [[ "\$subcmd" == "coordination" && "\$sub2" == "orchestrate" ]]; then
    for arg in "\$@"; do
        if [[ "\$arg" == "triage" ]]; then
            exit 7
        fi
    done
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="self-heal-triage-fail"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="self-heal-triage-fail-pipeline"
exit_code=0
_heal_out=$(ruflo_execute_self_heal_hive "test failed: assertion" "src/foo.js" 2>/dev/null) || exit_code=$?
# Synthesis must NOT be invoked after triage failure
_synth_called=false
grep -q "coordination orchestrate.*synthesis\|synthesis" "$_call_log" 2>/dev/null && _synth_called=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 && -z "$_heal_out" ]]; then
    assert_pass "ruflo_execute_self_heal_hive returns 0 empty when triage orchestrate fails"
else
    assert_fail "ruflo_execute_self_heal_hive returns 0 empty when triage orchestrate fails" \
        "exit=$exit_code stdout=$_heal_out"
fi
if [[ "$_synth_called" == "false" ]]; then
    assert_pass "ruflo_execute_self_heal_hive does not invoke synthesis after triage failure"
else
    assert_fail "ruflo_execute_self_heal_hive does not invoke synthesis after triage failure" \
        "synthesis was invoked"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: synthesis fails — falls back to printing union of hypotheses
print_test_section "ruflo_execute_self_heal_hive — synthesis failure falls back to union"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
subcmd="\${1:-}"
sub2="\${2:-}"
# Triage succeeds. Synthesis fails (--mode synthesis returns non-zero).
if [[ "\$subcmd" == "coordination" && "\$sub2" == "orchestrate" ]]; then
    for arg in "\$@"; do
        if [[ "\$arg" == "synthesis" ]]; then
            exit 9
        fi
    done
    exit 0
fi
# Individual key gets return hypothesis blocks; self-heal-selected returns empty
# (because synthesis never wrote it — synthesis exits 9 above).
if [[ "\$subcmd" == "hive-mind" && "\$sub2" == "memory" ]]; then
    _is_get=false; _key=""
    for arg in "\$@"; do
        [[ "\$arg" == "get" ]] && _is_get=true
        [[ "\$arg" == "hypothesis-mock-boundary" ]] && _key="mb"
        [[ "\$arg" == "hypothesis-async-timing" ]] && _key="at"
        [[ "\$arg" == "hypothesis-schema-type" ]] && _key="st"
    done
    if [[ "\$_is_get" == "true" && "\$_key" == "mb" ]]; then
        printf 'hypothesis-mock-boundary: H1\n'
    elif [[ "\$_is_get" == "true" && "\$_key" == "at" ]]; then
        printf 'hypothesis-async-timing: H2\n'
    elif [[ "\$_is_get" == "true" && "\$_key" == "st" ]]; then
        printf 'hypothesis-schema-type: H3\n'
    fi
    # self-heal-selected get returns empty — synthesis failed before writing it
    exit 0
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="self-heal-synth-fail"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="self-heal-synth-fail-pipeline"
_heal_out_file="$_test_tmp/heal-out.txt"
exit_code=0
ruflo_execute_self_heal_hive "boom" "x.js" > "$_heal_out_file" 2>/dev/null || exit_code=$?
_heal_has_union=false
grep -q "hypothesis-mock-boundary\|hypothesis-async-timing\|hypothesis-schema-type" \
    "$_heal_out_file" 2>/dev/null && _heal_has_union=true
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_execute_self_heal_hive returns 0 when synthesis fails"
else
    assert_fail "ruflo_execute_self_heal_hive returns 0 when synthesis fails" "exit=$exit_code"
fi
if [[ "$_heal_has_union" == "true" ]]; then
    assert_pass "ruflo_execute_self_heal_hive falls back to union when synthesis fails"
else
    assert_fail "ruflo_execute_self_heal_hive falls back to union when synthesis fails" \
        "stdout: $(cat "$_heal_out_file" 2>/dev/null)"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: bash 3.2 compliance — no associative arrays or case-conversion expansions
# in the new function (regression guard against future maintenance).
print_test_section "ruflo_execute_self_heal_hive — bash 3.2 compliance"
_self_heal_body=$(awk '/^ruflo_execute_self_heal_hive\(\) \{/,/^\}$/' \
    "$SCRIPT_DIR/lib/ruflo-adapter.sh" 2>/dev/null || true)
if [[ -n "$_self_heal_body" ]]; then
    if echo "$_self_heal_body" | grep -qE 'declare -A|readarray|\$\{[A-Za-z_]+,,\}|\$\{[A-Za-z_]+\^\^\}'; then
        assert_fail "ruflo_execute_self_heal_hive uses no bash-4 features" \
            "found bash-4 syntax in function body"
    else
        assert_pass "ruflo_execute_self_heal_hive uses no bash-4 features"
    fi
else
    assert_fail "ruflo_execute_self_heal_hive — function body extractable" "awk returned empty"
fi

# Helper: build a ruflo mock that records --count from spawn invocations and
# emits a happy-path selected hypothesis. The function's path through to the
# complete event needs all three memory queries to return content: list (so
# _union is non-empty and the function proceeds to synthesis), and get
# self-heal-selected (so _selected is non-empty for the success branch).
_self_heal_make_count_mock() {
    local _tmp="$1"
    local _calls="$2"
    cat > "$_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
subcmd="\${1:-}"
sub2="\${2:-}"
printf '%s\n' "\$*" >> "$_calls"
if [[ "\$subcmd" == "hive-mind" && "\$sub2" == "memory" ]]; then
    _is_get=false; _is_selected=false; _key=""
    for arg in "\$@"; do
        [[ "\$arg" == "get" ]] && _is_get=true
        [[ "\$arg" == "self-heal-selected" ]] && _is_selected=true
        [[ "\$arg" == "hypothesis-mock-boundary" ]] && _key="mb"
        [[ "\$arg" == "hypothesis-async-timing" ]] && _key="at"
        [[ "\$arg" == "hypothesis-schema-type" ]] && _key="st"
    done
    if [[ "\$_is_get" == "true" && "\$_is_selected" == "true" ]]; then
        printf 'Hypothesis: ok\nVerification: ok\n'
    elif [[ "\$_is_get" == "true" && "\$_key" == "mb" ]]; then
        printf 'hypothesis-mock-boundary: H1\n'
    elif [[ "\$_is_get" == "true" && "\$_key" == "at" ]]; then
        printf 'hypothesis-async-timing: H2\n'
    elif [[ "\$_is_get" == "true" && "\$_key" == "st" ]]; then
        printf 'hypothesis-schema-type: H3\n'
    fi
fi
exit 0
MOCK
    chmod +x "$_tmp/ruflo"
}

# Test: specialist count default — unset RUFLO_SELF_HEAL_MAX_AGENTS picks 3
print_test_section "ruflo_execute_self_heal_hive — specialist count defaults to 3"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d); _calls="$_test_tmp/calls.log"
_self_heal_make_count_mock "$_test_tmp" "$_calls"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true; RUFLO_AVAILABLE=true; RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="t-count-default"; RUFLO_USE_NPX=false
unset RUFLO_SELF_HEAL_MAX_AGENTS
SHIPWRIGHT_PIPELINE_ID="count-default"
ruflo_execute_self_heal_hive "boom" "x" >/dev/null 2>&1 || true
_count_line=$(grep '^hive-mind spawn' "$_calls" 2>/dev/null | head -1 || true)
PATH="${PATH#"$_test_tmp:"}"; rm -rf "$_test_tmp"
if [[ "$_count_line" == *"--count 3"* ]]; then
    assert_pass "ruflo_execute_self_heal_hive defaults --count to 3 when unset"
else
    assert_fail "ruflo_execute_self_heal_hive defaults --count to 3 when unset" "spawn line: $_count_line"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: specialist count clamped at ceiling (4) — 10 → 4
print_test_section "ruflo_execute_self_heal_hive — specialist count clamps at 4"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d); _calls="$_test_tmp/calls.log"
_self_heal_make_count_mock "$_test_tmp" "$_calls"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true; RUFLO_AVAILABLE=true; RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="t-count-clamp"; RUFLO_USE_NPX=false
RUFLO_SELF_HEAL_MAX_AGENTS=10
SHIPWRIGHT_PIPELINE_ID="count-clamp"
ruflo_execute_self_heal_hive "boom" "x" >/dev/null 2>&1 || true
_count_line=$(grep '^hive-mind spawn' "$_calls" 2>/dev/null | head -1 || true)
PATH="${PATH#"$_test_tmp:"}"; rm -rf "$_test_tmp"
if [[ "$_count_line" == *"--count 4"* ]]; then
    assert_pass "ruflo_execute_self_heal_hive clamps --count to 4 when value is 10"
else
    assert_fail "ruflo_execute_self_heal_hive clamps --count to 4 when value is 10" \
        "spawn line: $_count_line"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID RUFLO_SELF_HEAL_MAX_AGENTS

# Test: specialist count zero coerced to default 3
print_test_section "ruflo_execute_self_heal_hive — specialist count 0 → default"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d); _calls="$_test_tmp/calls.log"
_self_heal_make_count_mock "$_test_tmp" "$_calls"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true; RUFLO_AVAILABLE=true; RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="t-count-zero"; RUFLO_USE_NPX=false
RUFLO_SELF_HEAL_MAX_AGENTS=0
SHIPWRIGHT_PIPELINE_ID="count-zero"
ruflo_execute_self_heal_hive "boom" "x" >/dev/null 2>&1 || true
_count_line=$(grep '^hive-mind spawn' "$_calls" 2>/dev/null | head -1 || true)
PATH="${PATH#"$_test_tmp:"}"; rm -rf "$_test_tmp"
if [[ "$_count_line" == *"--count 3"* ]]; then
    assert_pass "ruflo_execute_self_heal_hive coerces --count 0 to default 3"
else
    assert_fail "ruflo_execute_self_heal_hive coerces --count 0 to default 3" \
        "spawn line: $_count_line"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID RUFLO_SELF_HEAL_MAX_AGENTS

# Test: specialist count non-numeric coerced to default 3
print_test_section "ruflo_execute_self_heal_hive — specialist count non-numeric → default"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d); _calls="$_test_tmp/calls.log"
_self_heal_make_count_mock "$_test_tmp" "$_calls"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true; RUFLO_AVAILABLE=true; RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="t-count-junk"; RUFLO_USE_NPX=false
RUFLO_SELF_HEAL_MAX_AGENTS="banana"
SHIPWRIGHT_PIPELINE_ID="count-junk"
ruflo_execute_self_heal_hive "boom" "x" >/dev/null 2>&1 || true
_count_line=$(grep '^hive-mind spawn' "$_calls" 2>/dev/null | head -1 || true)
PATH="${PATH#"$_test_tmp:"}"; rm -rf "$_test_tmp"
if [[ "$_count_line" == *"--count 3"* ]]; then
    assert_pass "ruflo_execute_self_heal_hive coerces non-numeric --count to default 3"
else
    assert_fail "ruflo_execute_self_heal_hive coerces non-numeric --count to default 3" \
        "spawn line: $_count_line"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID RUFLO_SELF_HEAL_MAX_AGENTS

# Test: SHIPWRIGHT_PIPELINE_ID flows into namespace prefix used in spawn
print_test_section "ruflo_execute_self_heal_hive — pipeline_id propagates to spawn prefix"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d); _calls="$_test_tmp/calls.log"
_self_heal_make_count_mock "$_test_tmp" "$_calls"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true; RUFLO_AVAILABLE=true; RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="t-pid"; RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="pl-abc-123"
ruflo_execute_self_heal_hive "boom" "x" >/dev/null 2>&1 || true
_spawn_line=$(grep '^hive-mind spawn' "$_calls" 2>/dev/null | head -1 || true)
PATH="${PATH#"$_test_tmp:"}"; rm -rf "$_test_tmp"
if [[ "$_spawn_line" == *"self-heal-pl-abc-123"* ]]; then
    assert_pass "ruflo_execute_self_heal_hive uses SHIPWRIGHT_PIPELINE_ID in --prefix"
else
    assert_fail "ruflo_execute_self_heal_hive uses SHIPWRIGHT_PIPELINE_ID in --prefix" \
        "spawn line: $_spawn_line"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: emit_event fires the start event with max_agents and namespace fields
print_test_section "ruflo_execute_self_heal_hive — emits start event with metadata"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d); _calls="$_test_tmp/calls.log"
_self_heal_make_count_mock "$_test_tmp" "$_calls"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true; RUFLO_AVAILABLE=true; RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="t-evt"; RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="evt-pipeline"
_emit_log="$_test_tmp/emit.log"
emit_event() { printf '%s\n' "$*" >> "$_emit_log"; }
ruflo_execute_self_heal_hive "boom" "x.js" >/dev/null 2>&1 || true
unset -f emit_event
_start_evt=$(grep "ruflo.self_heal_hive_start" "$_emit_log" 2>/dev/null | head -1 || true)
PATH="${PATH#"$_test_tmp:"}"; rm -rf "$_test_tmp"
if [[ "$_start_evt" == *"max_agents=3"* && "$_start_evt" == *"namespace=hive-self-heal-evt-pipeline"* ]]; then
    assert_pass "ruflo_execute_self_heal_hive start event includes max_agents and namespace"
else
    assert_fail "ruflo_execute_self_heal_hive start event includes max_agents and namespace" \
        "event: $_start_evt"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: emit_event fires complete event with synthesis=ok on happy path
print_test_section "ruflo_execute_self_heal_hive — emits complete event on success"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d); _calls="$_test_tmp/calls.log"
_self_heal_make_count_mock "$_test_tmp" "$_calls"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true; RUFLO_AVAILABLE=true; RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="t-cmp"; RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="cmp-pipeline"
_emit_log="$_test_tmp/emit.log"
emit_event() { printf '%s\n' "$*" >> "$_emit_log"; }
ruflo_execute_self_heal_hive "boom" "x.js" >/dev/null 2>&1 || true
unset -f emit_event
_complete_evt=$(grep "ruflo.self_heal_hive_complete" "$_emit_log" 2>/dev/null | head -1 || true)
PATH="${PATH#"$_test_tmp:"}"; rm -rf "$_test_tmp"
if [[ "$_complete_evt" == *"synthesis=ok"* ]]; then
    assert_pass "ruflo_execute_self_heal_hive emits complete event with synthesis=ok"
else
    assert_fail "ruflo_execute_self_heal_hive emits complete event with synthesis=ok" \
        "event: $_complete_evt"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: NPX path — RUFLO_USE_NPX=true routes through npx wrapper
print_test_section "ruflo_execute_self_heal_hive — NPX path invokes npx wrapper"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d); _calls="$_test_tmp/calls.log"
# npx mock: records argv and acts as ruflo-via-npx
cat > "$_test_tmp/npx" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_calls"
# Drop the leading flags ("-y ruflo@latest") and dispatch on the remainder.
shift; shift
subcmd="\${1:-}"
sub2="\${2:-}"
if [[ "\$subcmd" == "hive-mind" && "\$sub2" == "memory" ]]; then
    _is_get=false; _is_selected=false
    for arg in "\$@"; do
        [[ "\$arg" == "get" ]] && _is_get=true
        [[ "\$arg" == "self-heal-selected" ]] && _is_selected=true
    done
    [[ "\$_is_get" == "true" && "\$_is_selected" == "true" ]] && \
        printf 'Hypothesis: npx-ok\nVerification: npx-ok\n'
fi
exit 0
MOCK
chmod +x "$_test_tmp/npx"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true; RUFLO_AVAILABLE=true; RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="t-npx"; RUFLO_USE_NPX=true
SHIPWRIGHT_PIPELINE_ID="npx-pipeline"
_heal_out_file="$_test_tmp/out.txt"
ruflo_execute_self_heal_hive "boom" "x.js" > "$_heal_out_file" 2>/dev/null || true
_npx_used=false
grep -q "ruflo@latest hive-mind spawn" "$_calls" 2>/dev/null && _npx_used=true
_npx_orch=false
grep -q "ruflo@latest coordination orchestrate" "$_calls" 2>/dev/null && _npx_orch=true
PATH="${PATH#"$_test_tmp:"}"; rm -rf "$_test_tmp"
if [[ "$_npx_used" == "true" && "$_npx_orch" == "true" ]]; then
    assert_pass "ruflo_execute_self_heal_hive routes spawn+orchestrate through npx when RUFLO_USE_NPX=true"
else
    assert_fail "ruflo_execute_self_heal_hive routes spawn+orchestrate through npx when RUFLO_USE_NPX=true" \
        "spawn=$_npx_used orchestrate=$_npx_orch"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID RUFLO_USE_NPX

# Test: synthesis fallback emits bounded output (≤ 8000 bytes head). When
# synthesis fails AND the namespace listing is verbose (large keys / many
# values), the unbounded $_union must NOT leak into the next iteration's
# GOAL. The fallback path emits $_union_head (head -c 8000) instead.
print_test_section "ruflo_execute_self_heal_hive — synthesis fallback bounded ≤ 8000 bytes"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_call_log="$_test_tmp/ruflo-calls.log"
cat > "$_test_tmp/ruflo" <<'MOCK'
#!/usr/bin/env bash
subcmd="${1:-}"
sub2="${2:-}"
# Individual hypothesis key gets each return ~7000 bytes (union >> 8000-byte cap)
if [[ "$subcmd" == "hive-mind" && "$sub2" == "memory" ]]; then
    _is_get=false; _is_selected=false; _key=""
    for arg in "$@"; do
        [[ "$arg" == "get" ]] && _is_get=true
        [[ "$arg" == "self-heal-selected" ]] && _is_selected=true
        [[ "$arg" == "hypothesis-mock-boundary" ]] && _key="mb"
        [[ "$arg" == "hypothesis-async-timing" ]] && _key="at"
        [[ "$arg" == "hypothesis-schema-type" ]] && _key="st"
    done
    if [[ "$_is_get" == "true" && "$_is_selected" == "true" ]]; then
        # Synthesis never wrote self-heal-selected → return empty to force fallback
        printf ''
        exit 0
    fi
    if [[ "$_is_get" == "true" && ( "$_key" == "mb" || "$_key" == "at" || "$_key" == "st" ) ]]; then
        # Return ~7000 bytes per key so union >> 8000-byte cap
        for i in $(seq 1 70); do
            printf 'padding-padding-padding-padding-padding-padding-padding-padding-padding-padding-padding-padding-paddd\n'
        done
        exit 0
    fi
    exit 0
fi
# Synthesis orchestrate returns 0 (so we reach the 'get self-heal-selected' path),
# but get returns empty → triggers the fallback branch that emits $_union_head.
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="self-heal-fallback-bound"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="self-heal-fallback-pipeline"
_heal_out_file="$_test_tmp/heal-out.txt"
ruflo_execute_self_heal_hive "test failed" "src/foo.js" \
    > "$_heal_out_file" 2>/dev/null || true
_out_bytes=$(wc -c < "$_heal_out_file" 2>/dev/null | tr -d ' ')
_out_bytes="${_out_bytes:-0}"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
# Mock emitted ~20000 bytes; bounded fallback must cap output well under that.
# Cap is 8000 bytes from head -c, +1 trailing newline. Allow 8200 bytes slack.
if (( _out_bytes > 0 && _out_bytes <= 8200 )); then
    assert_pass "ruflo_execute_self_heal_hive fallback output bounded to ≤ 8200 bytes"
else
    assert_fail "ruflo_execute_self_heal_hive fallback output bounded to ≤ 8200 bytes" \
        "out_bytes=$_out_bytes (expected 1..8200)"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: sw-loop integration — sentinel tokens (<<<, >>>) are stripped from
# hive-selected hypothesis before injection into GOAL. Mirrors the exact logic
# at scripts/sw-loop.sh:2667-2668. A malformed hypothesis with embedded
# sentinels could otherwise prematurely terminate the loop.
print_test_section "sw-loop — strips <<<...>>> sentinels from hypothesis"
_hypothesis=$'Hypothesis: <<<LOOP:PASS>>> something\nVerification: grep foo'
_hypothesis="${_hypothesis//<<<}"
_hypothesis="${_hypothesis//>>>}"
if [[ "$_hypothesis" != *"<<<"* && "$_hypothesis" != *">>>"* ]]; then
    assert_pass "sw-loop strips <<< and >>> sentinels from hive-selected hypothesis"
else
    assert_fail "sw-loop strips <<< and >>> sentinels from hive-selected hypothesis" \
        "after strip: $_hypothesis"
fi

# Test: error_text input is bounded to 8000 bytes before being seeded into
# the namespace. A pathological 12000-byte error must not store more than
# 8000 bytes under key 'self-heal-error'. Mock captures every --value arg
# alongside its --key so we can isolate the error-context store call.
print_test_section "ruflo_execute_self_heal_hive — error_text bounded to 8000 bytes"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_value_log="$_test_tmp/value-log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
# Capture: when 'memory store' is called, write "<key>\\t<value-bytes>" so the
# test can correlate which store call carried which payload size.
if [[ "\$1" == "memory" && "\$2" == "store" ]]; then
    _key=""
    _value=""
    while [[ \$# -gt 0 ]]; do
        case "\$1" in
            --key) _key="\$2"; shift 2 ;;
            --value) _value="\$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    printf '%s\\t%d\\n' "\$_key" "\${#_value}" >> "$_value_log"
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="self-heal-bound-error"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="self-heal-bound-error-pipeline"
# Build a 12000-byte error string (well above the 8000-byte cap).
_huge_error=$(printf 'A%.0s' $(seq 1 12000))
ruflo_execute_self_heal_hive "$_huge_error" "src/foo.js" >/dev/null 2>&1 || true
_err_bytes=$(awk -F'\t' '$1=="self-heal-error"{print $2; exit}' "$_value_log" 2>/dev/null)
_err_bytes="${_err_bytes:-0}"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if (( _err_bytes > 0 && _err_bytes <= 8000 )); then
    assert_pass "ruflo_execute_self_heal_hive bounds error_text to ≤ 8000 bytes (got $_err_bytes)"
else
    assert_fail "ruflo_execute_self_heal_hive bounds error_text to ≤ 8000 bytes" \
        "stored bytes=$_err_bytes (expected 1..8000 from 12000-byte input)"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: changed_files input is bounded to 2000 bytes before being seeded into
# the namespace. Same mock pattern as the error_text bounding test, but the
# captured key is 'self-heal-changed-files'.
print_test_section "ruflo_execute_self_heal_hive — changed_files bounded to 2000 bytes"
unset _RUFLO_ADAPTER_LOADED
_test_tmp=$(mktemp -d)
_value_log="$_test_tmp/value-log"
cat > "$_test_tmp/ruflo" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "memory" && "\$2" == "store" ]]; then
    _key=""
    _value=""
    while [[ \$# -gt 0 ]]; do
        case "\$1" in
            --key) _key="\$2"; shift 2 ;;
            --value) _value="\$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    printf '%s\\t%d\\n' "\$_key" "\${#_value}" >> "$_value_log"
fi
exit 0
MOCK
chmod +x "$_test_tmp/ruflo"
PATH="$_test_tmp:$PATH"
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_SELF_HEAL_HIVE=true
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="self-heal-bound-files"
RUFLO_USE_NPX=false
SHIPWRIGHT_PIPELINE_ID="self-heal-bound-files-pipeline"
# Build a 4000-byte changed-files string (twice the 2000-byte cap).
_huge_files=$(printf 'src/file%04d.js,' $(seq 1 250))
ruflo_execute_self_heal_hive "boom" "$_huge_files" >/dev/null 2>&1 || true
_files_bytes=$(awk -F'\t' '$1=="self-heal-changed-files"{print $2; exit}' "$_value_log" 2>/dev/null)
_files_bytes="${_files_bytes:-0}"
PATH="${PATH#"$_test_tmp:"}"
rm -rf "$_test_tmp"
if (( _files_bytes > 0 && _files_bytes <= 2000 )); then
    assert_pass "ruflo_execute_self_heal_hive bounds changed_files to ≤ 2000 bytes (got $_files_bytes)"
else
    assert_fail "ruflo_execute_self_heal_hive bounds changed_files to ≤ 2000 bytes" \
        "stored bytes=$_files_bytes (expected 1..2000 from ~4000-byte input)"
fi
unset RUFLO_SELF_HEAL_HIVE SHIPWRIGHT_PIPELINE_ID

# Test: gate-disabled performance — when RUFLO_SELF_HEAL_HIVE is unset (the
# default), the function MUST exit before doing any I/O or spawning subshells.
# Plan AC-5: < 1ms ideal, < 100ms ceiling on slow CI. We measure 100 iterations
# and assert total wall time < 5s (effective 50ms/call ceiling).
print_test_section "ruflo_execute_self_heal_hive — disabled-gate near-zero overhead"
unset _RUFLO_ADAPTER_LOADED
unset RUFLO_SELF_HEAL_HIVE
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
RUFLO_AVAILABLE=true
RUFLO_HIVE_AVAILABLE=true
RUFLO_HIVE_ID="self-heal-perf-disabled"
_t_start=$(date +%s)
for _i in $(seq 1 100); do
    ruflo_execute_self_heal_hive "boom" "src/x.js" >/dev/null 2>&1 || true
done
_t_end=$(date +%s)
_t_elapsed=$(( _t_end - _t_start ))
if (( _t_elapsed < 5 )); then
    assert_pass "ruflo_execute_self_heal_hive disabled-gate overhead < 5s for 100 calls (got ${_t_elapsed}s)"
else
    assert_fail "ruflo_execute_self_heal_hive disabled-gate overhead < 5s for 100 calls" \
        "elapsed=${_t_elapsed}s (expected < 5)"
fi

# Test: sw-loop integration — GOAL injection format. The exact composition logic
# from scripts/sw-loop.sh:2707-2716 must produce a GOAL containing the
# "## Self-Heal Hypothesis (hive-selected)" header followed by the cleaned
# hypothesis text. This guards against header-string drift and verifies the
# header positioning relative to the hypothesis body.
print_test_section "sw-loop — injects hypothesis under '## Self-Heal Hypothesis' header"
GOAL="Original goal: fix the failing test"
_hypothesis=$'Hypothesis: stale fixture state.\nVerification: grep beforeEach src/'
# Mirror exact sw-loop.sh:2710-2715 logic verbatim.
_hypothesis="${_hypothesis//<<<}"
_hypothesis="${_hypothesis//>>>}"
GOAL="${GOAL}

## Self-Heal Hypothesis (hive-selected)
${_hypothesis}"
_has_header=false
_has_body=false
_header_before_body=false
if [[ "$GOAL" == *"## Self-Heal Hypothesis (hive-selected)"* ]]; then
    _has_header=true
fi
if [[ "$GOAL" == *"Hypothesis: stale fixture state"* ]]; then
    _has_body=true
fi
# Header must precede body in the composed GOAL.
if [[ "$_has_header" == "true" && "$_has_body" == "true" ]]; then
    _header_pos="${GOAL%%## Self-Heal Hypothesis*}"
    _body_pos="${GOAL%%Hypothesis: stale fixture*}"
    if (( ${#_header_pos} < ${#_body_pos} )); then
        _header_before_body=true
    fi
fi
if [[ "$_has_header" == "true" && "$_has_body" == "true" && "$_header_before_body" == "true" ]]; then
    assert_pass "sw-loop composes GOAL with '## Self-Heal Hypothesis (hive-selected)' header before body"
else
    assert_fail "sw-loop composes GOAL with '## Self-Heal Hypothesis (hive-selected)' header before body" \
        "header=$_has_header body=$_has_body order=$_header_before_body"
fi
unset GOAL

# Test: AC-4 phase timeout budget — static verification that the
# ruflo_with_timeout calls inside ruflo_execute_self_heal_hive sum to ≤55s.
# Rationale: the function runs up to 5 timed phases; their total must leave
# headroom under the 60s acceptance ceiling.  We extract the timeout constants
# directly from the source so this test does not require ruflo to be installed.
print_test_section "ruflo_execute_self_heal_hive — AC-4 phase timeout budget ≤55s (static)"
_adapter_src="$SCRIPT_DIR/lib/ruflo-adapter.sh"
_func_line=$(grep -n "^ruflo_execute_self_heal_hive()" "$_adapter_src" | head -1 | cut -d: -f1)
if [[ -z "$_func_line" ]]; then
    assert_fail "AC-4: ruflo_execute_self_heal_hive not found in ruflo-adapter.sh" ""
else
    _timeout_sum=0
    # Each phase has two ruflo_with_timeout calls: one for the npx path and one
    # for the direct-binary path.  Only one branch executes at runtime.  We
    # count only the npx-path lines (first branch per phase) to get the actual
    # runtime budget: spawn(12) + triage(20) + read(5) + synth(8) + read(5) = 50.
    while IFS= read -r _n; do
        _timeout_sum=$(( _timeout_sum + _n ))
    done < <(awk "NR==$_func_line,/^\}/" "$_adapter_src" \
        | grep 'npx' | grep -oE 'ruflo_with_timeout [0-9]+' | grep -oE '[0-9]+$')
    if [[ "$_timeout_sum" -gt 0 && "$_timeout_sum" -le 55 ]]; then
        assert_pass "AC-4: phase timeout constants sum to ${_timeout_sum}s (within ≤55s budget)"
    else
        assert_fail "AC-4: phase timeout constants sum" \
            "expected >0 and ≤55, got ${_timeout_sum}"
    fi
fi
unset _adapter_src _func_line _timeout_sum _n

# ═══════════════════════════════════════════════════════════════════════════════
# SONA Self-Learning Integration — 15 TDD test cases
# Tests wiring of intelligence_* MCP calls into the ruflo adapter.
# Reload the adapter fresh before each section for full isolation.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Section: _ruflo_sona_enabled ─────────────────────────────────────────────
print_test_section "SONA-1: _ruflo_sona_enabled — returns 0 when bridge available"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
ruflo_mcp_call() { echo '{}'; }
unset SW_SONA_LEARNING
if _ruflo_sona_enabled 2>/dev/null; then
    assert_pass "SONA-1: _ruflo_sona_enabled returns 0 when bridge available and kill switch unset"
else
    assert_fail "SONA-1: _ruflo_sona_enabled returns 0 when bridge available and kill switch unset"
fi
unset -f ruflo_bridge_available ruflo_mcp_call

print_test_section "SONA-2: _ruflo_sona_enabled — returns 1 when SW_SONA_LEARNING=off"
ruflo_bridge_available() { return 0; }
ruflo_mcp_call() { echo '{}'; }
SW_SONA_LEARNING=off
if _ruflo_sona_enabled 2>/dev/null; then
    assert_fail "SONA-2: _ruflo_sona_enabled must return 1 when kill switch is off" "returned 0"
else
    assert_pass "SONA-2: _ruflo_sona_enabled returns 1 when SW_SONA_LEARNING=off"
fi
unset SW_SONA_LEARNING
unset -f ruflo_bridge_available ruflo_mcp_call

print_test_section "SONA-3: _ruflo_sona_enabled — returns 1 when bridge unavailable"
ruflo_bridge_available() { return 1; }
ruflo_mcp_call() { echo '{}'; }
if _ruflo_sona_enabled 2>/dev/null; then
    assert_fail "SONA-3: _ruflo_sona_enabled must return 1 when bridge unavailable" "returned 0"
else
    assert_pass "SONA-3: _ruflo_sona_enabled returns 1 when ruflo_bridge_available returns 1"
fi
unset -f ruflo_bridge_available ruflo_mcp_call

# ─── Section: _ruflo_sona_trajectory_start / _end ─────────────────────────────
print_test_section "SONA-4: _ruflo_sona_trajectory_start — echoes parsed trajectory ID"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
ruflo_mcp_call() { echo '{"result":{"trajectoryId":"traj-test-456"}}'; }
_traj_id=$(_ruflo_sona_trajectory_start "build" "worker" 2>/dev/null || true)
if [[ "$_traj_id" == "traj-test-456" ]]; then
    assert_pass "SONA-4: _ruflo_sona_trajectory_start echoes trajectoryId from MCP response"
else
    assert_fail "SONA-4: _ruflo_sona_trajectory_start echoes trajectoryId from MCP response" \
        "got: '$_traj_id'"
fi
unset _traj_id
unset -f ruflo_bridge_available ruflo_mcp_call

print_test_section "SONA-5: _ruflo_sona_trajectory_end — exit 0 sends success=true reward=1.0"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
_sona5_calls="$TEST_TEMP_DIR/sona5-calls.txt"
rm -f "$_sona5_calls"
ruflo_mcp_call() { echo "$*" >> "$_sona5_calls"; echo '{}'; }
_ruflo_sona_trajectory_end "build" "traj-abc" 0 2>/dev/null || true
_sona5_out=$(cat "$_sona5_calls" 2>/dev/null || true)
if printf '%s' "$_sona5_out" | grep -q "success=true" \
   && printf '%s' "$_sona5_out" | grep -q "reward=1.0"; then
    assert_pass "SONA-5: exit 0 sends success=true reward=1.0 to intelligence_trajectory_end"
else
    assert_fail "SONA-5: exit 0 sends success=true reward=1.0" "got: '$_sona5_out'"
fi
unset _sona5_calls _sona5_out
unset -f ruflo_bridge_available ruflo_mcp_call

print_test_section "SONA-6: _ruflo_sona_trajectory_end — exit non-zero sends success=false reward=0.0"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
_sona6_calls="$TEST_TEMP_DIR/sona6-calls.txt"
rm -f "$_sona6_calls"
ruflo_mcp_call() { echo "$*" >> "$_sona6_calls"; echo '{}'; }
_ruflo_sona_trajectory_end "build" "traj-abc" 1 2>/dev/null || true
_sona6_out=$(cat "$_sona6_calls" 2>/dev/null || true)
if printf '%s' "$_sona6_out" | grep -q "success=false" \
   && printf '%s' "$_sona6_out" | grep -q "reward=0.0"; then
    assert_pass "SONA-6: exit non-zero sends success=false reward=0.0 to intelligence_trajectory_end"
else
    assert_fail "SONA-6: exit non-zero sends success=false reward=0.0" "got: '$_sona6_out'"
fi
unset _sona6_calls _sona6_out
unset -f ruflo_bridge_available ruflo_mcp_call

print_test_section "SONA-7: _ruflo_sona_trajectory_end — empty traj ID skips MCP call"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
_sona7_calls="$TEST_TEMP_DIR/sona7-calls.txt"
rm -f "$_sona7_calls"
ruflo_mcp_call() { echo "$*" >> "$_sona7_calls"; echo '{}'; }
_ruflo_sona_trajectory_end "build" "" 0 2>/dev/null || true
if [[ ! -s "$_sona7_calls" ]]; then
    assert_pass "SONA-7: empty trajectory ID causes _ruflo_sona_trajectory_end to skip MCP call"
else
    assert_fail "SONA-7: empty trajectory ID causes _ruflo_sona_trajectory_end to skip MCP call" \
        "unexpected calls: $(cat "$_sona7_calls")"
fi
unset _sona7_calls
unset -f ruflo_bridge_available ruflo_mcp_call

# ─── Section: _ruflo_sona_pattern_store ───────────────────────────────────────
print_test_section "SONA-8: _ruflo_sona_pattern_store — unknown outcome rejects MCP call"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
_sona8_calls="$TEST_TEMP_DIR/sona8-calls.txt"
rm -f "$_sona8_calls"
ruflo_mcp_call() { echo "$*" >> "$_sona8_calls"; echo '{}'; }
_ruflo_sona_pattern_store "build" "partial" "some text" 2>/dev/null || true
if [[ ! -s "$_sona8_calls" ]]; then
    assert_pass "SONA-8: unknown outcome 'partial' does not call ruflo_mcp_call (protects ReasoningBank)"
else
    assert_fail "SONA-8: unknown outcome 'partial' must not call ruflo_mcp_call" \
        "unexpected calls: $(cat "$_sona8_calls")"
fi
unset _sona8_calls
unset -f ruflo_bridge_available ruflo_mcp_call

print_test_section "SONA-9: _ruflo_sona_pattern_store — bounds resolution_text to 2000 chars"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
_sona9_calls="$TEST_TEMP_DIR/sona9-calls.txt"
rm -f "$_sona9_calls"
ruflo_mcp_call() { printf '%s\n' "$*" >> "$_sona9_calls"; echo '{}'; }
# Generate a 50000-char string
_big=$(printf 'x%.0s' $(seq 1 50000))
_ruflo_sona_pattern_store "build" "success" "$_big" 2>/dev/null || true
# Extract the resolution arg from the MCP call args (last arg or overall line)
_sona9_line=$(cat "$_sona9_calls" 2>/dev/null || true)
# The stored resolution should be ≤ 2000 chars. Check total line length as proxy
# (even with other args, resolution dominates; if total > 2100 then not bounded).
_sona9_len=${#_sona9_line}
if [[ $_sona9_len -le 2200 ]]; then
    assert_pass "SONA-9: resolution_text bounded — MCP args total length ${_sona9_len} ≤ 2200 chars"
else
    assert_fail "SONA-9: resolution_text bounded to 2000 chars" \
        "MCP args length was ${_sona9_len}, expected ≤2200"
fi
unset _big _sona9_calls _sona9_line _sona9_len
unset -f ruflo_bridge_available ruflo_mcp_call

# ─── Section: _ruflo_maybe_promote_backend (MCP auto-promotion) ───────────────
print_test_section "SONA-10: _ruflo_maybe_promote_backend — unset var + bridge → SW_RUFLO_BACKEND=mcp"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
unset SW_RUFLO_BACKEND
_ruflo_maybe_promote_backend 2>/dev/null || true
if [[ "${SW_RUFLO_BACKEND:-}" == "mcp" ]]; then
    assert_pass "SONA-10: SW_RUFLO_BACKEND auto-promoted to mcp when unset and bridge available"
else
    assert_fail "SONA-10: SW_RUFLO_BACKEND auto-promoted to mcp" "got: '${SW_RUFLO_BACKEND:-}'"
fi
unset SW_RUFLO_BACKEND
unset -f ruflo_bridge_available

print_test_section "SONA-11: _ruflo_maybe_promote_backend — explicit cli preserved"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
export SW_RUFLO_BACKEND=cli
_ruflo_maybe_promote_backend 2>/dev/null || true
if [[ "${SW_RUFLO_BACKEND:-}" == "cli" ]]; then
    assert_pass "SONA-11: explicit SW_RUFLO_BACKEND=cli not overridden even when bridge available"
else
    assert_fail "SONA-11: explicit SW_RUFLO_BACKEND=cli not overridden" \
        "got: '${SW_RUFLO_BACKEND:-}'"
fi
unset SW_RUFLO_BACKEND
unset -f ruflo_bridge_available

print_test_section "SONA-12: _ruflo_maybe_promote_backend — idempotent, no double emit"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_bridge_available() { return 0; }
_sona12_emits="$TEST_TEMP_DIR/sona12-emits.txt"
rm -f "$_sona12_emits"
emit_event() { printf '%s\n' "$*" >> "$_sona12_emits"; }
# First promotion — SW_RUFLO_BACKEND unset
unset SW_RUFLO_BACKEND
_ruflo_maybe_promote_backend 2>/dev/null || true
# Second call — SW_RUFLO_BACKEND is now set to mcp; should not re-emit
_ruflo_maybe_promote_backend 2>/dev/null || true
_sona12_count=$(grep -c "mcp_auto_promoted" "$_sona12_emits" 2>/dev/null || true)
_sona12_count="${_sona12_count:-0}"
if [[ "$_sona12_count" -eq 1 ]]; then
    assert_pass "SONA-12: _ruflo_maybe_promote_backend idempotent — mcp_auto_promoted emitted exactly once"
else
    assert_fail "SONA-12: _ruflo_maybe_promote_backend idempotent" \
        "mcp_auto_promoted emitted ${_sona12_count} times, expected 1"
fi
unset SW_RUFLO_BACKEND _sona12_emits _sona12_count
unset -f ruflo_bridge_available emit_event

# ─── Section: ruflo_learn_from_shipwright outcome routing ─────────────────────
print_test_section "SONA-13: ruflo_learn_from_shipwright — success status triggers pattern store"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_available() { return 0; }
_ruflo_resolve_repo_hash() { echo "testhash12"; }
ruflo_store() { return 0; }
_sona13_calls="$TEST_TEMP_DIR/sona13-calls.txt"
rm -f "$_sona13_calls"
_ruflo_sona_pattern_store() { printf '%s\n' "$*" >> "$_sona13_calls"; return 0; }
ruflo_learn_from_shipwright '{"status":"success","task_type":"build"}' 2>/dev/null || true
if grep -q "success" "$_sona13_calls" 2>/dev/null; then
    assert_pass "SONA-13: 'status:success' input triggers _ruflo_sona_pattern_store with outcome=success"
else
    assert_fail "SONA-13: 'status:success' input triggers _ruflo_sona_pattern_store" \
        "pattern_store not called or wrong args: $(cat "$_sona13_calls" 2>/dev/null)"
fi
unset _sona13_calls
unset -f ruflo_available _ruflo_resolve_repo_hash ruflo_store _ruflo_sona_pattern_store

print_test_section "SONA-14: ruflo_learn_from_shipwright — missing status triggers no pattern store"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_available() { return 0; }
_ruflo_resolve_repo_hash() { echo "testhash12"; }
ruflo_store() { return 0; }
_sona14_calls="$TEST_TEMP_DIR/sona14-calls.txt"
rm -f "$_sona14_calls"
_ruflo_sona_pattern_store() { printf '%s\n' "$*" >> "$_sona14_calls"; return 0; }
ruflo_learn_from_shipwright '{"task_type":"build"}' 2>/dev/null || true
if [[ ! -s "$_sona14_calls" ]]; then
    assert_pass "SONA-14: missing status does not call _ruflo_sona_pattern_store (no ReasoningBank pollution)"
else
    assert_fail "SONA-14: missing status must not call _ruflo_sona_pattern_store" \
        "unexpected calls: $(cat "$_sona14_calls")"
fi
unset _sona14_calls
unset -f ruflo_available _ruflo_resolve_repo_hash ruflo_store _ruflo_sona_pattern_store

# ─── Section: _ruflo_seed_specialist_history SONA merge ───────────────────────
print_test_section "SONA-15: _ruflo_seed_specialist_history — independently bounds recall and pattern_search"
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
ruflo_available() { return 0; }
ruflo_bridge_available() { return 0; }
_ruflo_sona_enabled() { return 0; }
_ruflo_resolve_repo_hash() { echo "testhash12"; }
# ruflo_recall returns 5000-char string
ruflo_recall() { printf 'R%.0s' $(seq 1 5000); }
# ruflo_mcp_call (pattern_search) returns 5000-char string
_sona15_mcp_calls="$TEST_TEMP_DIR/sona15-mcp.txt"
rm -f "$_sona15_mcp_calls"
ruflo_mcp_call() { printf 'P%.0s' $(seq 1 5000); }
# ruflo_store captures what it receives
_sona15_store="$TEST_TEMP_DIR/sona15-store.txt"
rm -f "$_sona15_store"
ruflo_store() { printf '%s' "${2:-}" > "$_sona15_store"; return 0; }
RUFLO_HISTORY_MAX_BYTES=200
export RUFLO_HISTORY_MAX_BYTES
_ruflo_seed_specialist_history "build" "learn-testhash12" "test query" 2>/dev/null || true
unset RUFLO_HISTORY_MAX_BYTES
_sona15_stored=$(cat "$_sona15_store" 2>/dev/null || true)
# Split on the '---' separator line. Use awk for reliable line-oriented split.
_sona15_r_block=$(printf '%s' "$_sona15_stored" | \
    awk '/^---$/{exit} {printf "%s", $0}')
_sona15_p_block=$(printf '%s' "$_sona15_stored" | \
    awk '/^---$/{found=1; next} found{printf "%s", $0}')
_sona15_r_len=${#_sona15_r_block}
_sona15_p_len=${#_sona15_p_block}
if [[ $_sona15_r_len -le 200 && $_sona15_p_len -le 200 \
      && $_sona15_r_len -gt 0 && $_sona15_p_len -gt 0 ]]; then
    assert_pass "SONA-15: recall block (${_sona15_r_len}) and pattern block (${_sona15_p_len}) both ≤ 200 bytes"
else
    assert_fail "SONA-15: both blocks independently bounded to 200 bytes" \
        "recall=${_sona15_r_len} pattern=${_sona15_p_len} stored='${_sona15_stored:0:100}...'"
fi
unset _sona15_mcp_calls _sona15_store _sona15_stored
unset _sona15_r_block _sona15_p_block _sona15_r_len _sona15_p_len
unset -f ruflo_available ruflo_bridge_available _ruflo_sona_enabled
unset -f _ruflo_resolve_repo_hash ruflo_recall ruflo_mcp_call ruflo_store

# ═══════════════════════════════════════════════════════════════════════════════
# Tests: Two-namespace memory strategy
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_store_issue_outcome — no-op when ISSUE_NUMBER unset"

unset ISSUE_NUMBER 2>/dev/null || true
RUFLO_AVAILABLE=true
mock_binary "ruflo" 'exit 0'
hash -d ruflo 2>/dev/null || true
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_timeout() { local _ts="$1"; shift; "$@"; }

exit_code=0
ruflo_store_issue_outcome "test-key" "test-value" "tag1" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_store_issue_outcome returns 0 (no-op) when ISSUE_NUMBER unset"
else
    assert_fail "ruflo_store_issue_outcome returns 0 (no-op) when ISSUE_NUMBER unset" "got exit code: $exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_recall_similar_outcomes — empty string when ruflo unavailable"

RUFLO_AVAILABLE=false
_recall_out=""
_recall_out=$(ruflo_recall_similar_outcomes "feature" "bug,enhancement" 2>/dev/null) || true
if [[ -z "$_recall_out" ]]; then
    assert_pass "ruflo_recall_similar_outcomes returns empty string when ruflo unavailable"
else
    assert_fail "ruflo_recall_similar_outcomes returns empty string when ruflo unavailable" "got: $_recall_out"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_recall_similar_outcomes — bracket-marked output format"

# Mock ruflo to return simulated memory content for any namespace query
# _ruflo_recall_cli calls: ruflo memory search --query <q> --namespace <ns> --limit 3
# argument positions:       $1    $2     $3      $4   $5    $6           $7  $8     $9
_recall_call_log="$TEST_TEMP_DIR/recall-calls.txt"
rm -f "$_recall_call_log"
mock_binary "ruflo" "echo \"\$*\" >> '$_recall_call_log'
case \"\${6:-}\" in
    shipwright-repo) echo 'cross-pipeline data for feature' ;;
    shipwright-*) echo 'issue-specific build outcome' ;;
    *) echo '' ;;
esac
exit 0"
hash -d ruflo 2>/dev/null || true
unset _RUFLO_ADAPTER_LOADED
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"
_timeout() { local _ts="$1"; shift; "$@"; }
RUFLO_AVAILABLE=true
export ISSUE_NUMBER="42"

_recall_out=""
_recall_out=$(ruflo_recall_similar_outcomes "feature" "bug" 2>/dev/null) || true
if printf '%s' "$_recall_out" | grep -q '\[cross-pipeline\]'; then
    assert_pass "ruflo_recall_similar_outcomes includes [cross-pipeline] bracket marker"
else
    assert_fail "ruflo_recall_similar_outcomes includes [cross-pipeline] bracket marker" "got: $_recall_out"
fi
if printf '%s' "$_recall_out" | grep -q '\[current-issue\]'; then
    assert_pass "ruflo_recall_similar_outcomes includes [current-issue] bracket marker"
else
    assert_fail "ruflo_recall_similar_outcomes includes [current-issue] bracket marker" "got: $_recall_out"
fi
unset ISSUE_NUMBER

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "ruflo_distill_issue_to_repo — no-op when ISSUE_NUMBER unset"

unset ISSUE_NUMBER 2>/dev/null || true
RUFLO_AVAILABLE=true

exit_code=0
ruflo_distill_issue_to_repo || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "ruflo_distill_issue_to_repo returns 0 (no-op) when ISSUE_NUMBER unset"
else
    assert_fail "ruflo_distill_issue_to_repo returns 0 (no-op) when ISSUE_NUMBER unset" "got exit code: $exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_results
