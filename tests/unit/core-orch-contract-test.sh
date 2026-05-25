#!/usr/bin/env bash
# Tests: core/orch/contract.sh — orchestrator backend contract (issue #219)
# TDD order: these tests are intentionally written BEFORE core/orch/contract.sh
# exists so that the implementation is driven by the failing test output.
#
# Work unit definition (shared contract for unit + integration tests):
#   A work unit is a bash function body string safe to pass to `bash -c`.
#   Single statements:  "echo hello"
#   Multi-statement:    "echo hello; echo world"
#   Failing work unit:  "exit 1"
#   Build one with:     orch_work_unit <body>  (defined in the mock plugin)
#
# Mock backend wiring:
#   The mock at plugins/tool/orch-mock/plugin.sh is sourced directly.
#   No plugin registry lookup is needed for unit tests.
#   ORCH_MOCK_DIR is pointed at $TEST_TEMP_DIR to keep all state isolated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/orch/contract — unit tests (ADR-011, issue #219)"

setup_test_env "core-orch-contract-unit"

# Prevent project config from leaking into tests.
export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# Point mock state at the sandboxed temp dir.
export ORCH_MOCK_DIR="$TEST_TEMP_DIR/orch-mock"

# Source the mock backend first so its functions are available when
# core/orch/contract.sh calls orch_capabilities / orch_has_capability.
# shellcheck source=../../plugins/tool/orch-mock/plugin.sh
source "$REPO_ROOT/plugins/tool/orch-mock/plugin.sh"

# Source the contract layer under test.
# shellcheck source=../../core/orch/contract.sh
source "$REPO_ROOT/core/orch/contract.sh"

# ─── Test 1: Required contract functions are defined after sourcing ───────────
print_test_section "1. Required contract functions are defined after sourcing with mock backend"

for fn in orch_spawn orch_dispatch orch_collect orch_shutdown orch_capabilities orch_has_capability; do
    if declare -F "$fn" >/dev/null 2>&1; then
        assert_pass "function $fn is defined"
    else
        assert_fail "function $fn is defined" "declare -F $fn returned nothing"
    fi
done

# ─── Test 2: orch_has_capability "parallel_spawn" returns 1 (mock lacks it) ──
print_test_section "2. orch_has_capability 'parallel_spawn' returns 1 for mock backend"

set +e
orch_has_capability "parallel_spawn"
cap_rc=$?
set -e

assert_exit_code \
    "orch_has_capability parallel_spawn returns 1 (mock does not declare it)" \
    "1" "$cap_rc"

# ─── Test 3: orch_has_capability "sequential" returns 0 (mock provides it) ───
print_test_section "3. orch_has_capability 'sequential' returns 0 for mock backend"

set +e
orch_has_capability "sequential"
cap_rc=$?
set -e

assert_exit_code \
    "orch_has_capability sequential returns 0" \
    "0" "$cap_rc"

# ─── Test 4: orch_has_capability "fanout" returns 0 ──────────────────────────
print_test_section "4. orch_has_capability 'fanout' returns 0 for mock backend"

set +e
orch_has_capability "fanout"
cap_rc=$?
set -e

assert_exit_code \
    "orch_has_capability fanout returns 0" \
    "0" "$cap_rc"

# ─── Test 5: orch_capabilities returns a non-empty list ──────────────────────
print_test_section "5. orch_capabilities returns a non-empty list"

caps_output="$(orch_capabilities)"

# Must be non-empty
if [[ -n "$caps_output" ]]; then
    assert_pass "orch_capabilities returns non-empty output"
else
    assert_fail "orch_capabilities returns non-empty output" "got empty string"
fi

# Must contain at least one quoted capability name (JSON array format)
assert_contains \
    "orch_capabilities output contains a quoted capability" \
    "$caps_output" '"'

# Must contain "sequential" — the one capability the mock declares
assert_contains \
    "orch_capabilities output contains sequential" \
    "$caps_output" "sequential"

# ─── Test 6: orch_capabilities output includes all mock-declared capabilities ─
print_test_section "6. orch_capabilities output includes all mock-declared capabilities"

assert_contains \
    "orch_capabilities includes fanout" \
    "$caps_output" "fanout"

# ─── Test 7: Invalid/unknown backend name emits a warn ───────────────────────
# The contract layer must warn (via helpers warn()) when an unknown backend
# alias is passed to orch_load_backend (or equivalent init function).
# The warn goes to stderr; we capture it.
print_test_section "7. Invalid backend name emits a warn to stderr"

warn_output="$(orch_load_backend "definitely-not-a-real-backend" 2>&1 || true)"

assert_contains \
    "unknown backend name produces a warn on stderr" \
    "$warn_output" "backend"

# The contract must NOT hard-exit the caller's shell when an unknown name is given.
set +e
orch_load_backend "definitely-not-a-real-backend" 2>/dev/null
load_rc=$?
set -e

# Acceptable return codes: 1 (error) is fine; 0 is also acceptable if the
# contract degrades gracefully.  We just assert it is not a shell-level crash
# (i.e., rc is 0 or 1, not a signal kill).
if [[ "$load_rc" -le 1 ]]; then
    assert_pass "orch_load_backend with unknown name returns 0 or 1 (no crash)"
else
    assert_fail "orch_load_backend with unknown name returns 0 or 1 (no crash)" \
        "got rc=$load_rc"
fi

# ─── Test 8: orch_load_backend with valid mock alias succeeds ─────────────────
print_test_section "8. orch_load_backend with mock-orch alias succeeds"

# Supply the test plugins root so the registry can find orch-mock.
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"

set +e
orch_load_backend "mock-orch" 2>/dev/null
load_rc=$?
set -e

assert_exit_code \
    "orch_load_backend mock-orch returns 0" \
    "0" "$load_rc"

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
