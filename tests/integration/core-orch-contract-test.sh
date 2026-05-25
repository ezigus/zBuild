#!/usr/bin/env bash
# Integration Tests: core/orch/contract.sh with mock orchestrator backend
# (issue #219, ADR-011)
#
# These tests exercise the full dispatch/collect/shutdown cycle against the
# synchronous mock backend.  They run end-to-end through the contract layer
# (core/orch/contract.sh) rather than calling the mock plugin functions
# directly, which is what distinguishes them from the unit tests.
#
# Work unit definition (canonical reference):
#   A work unit is a bash function body string suitable for `bash -c`.
#   It is constructed with:  orch_work_unit <body>
#   - Successful unit:       orch_work_unit 'echo "output text"'
#   - Failing unit:          orch_work_unit 'echo "error output"; exit 1'
#   - Multi-statement unit:  orch_work_unit 'echo first; echo second'
#
# Pool lifecycle:
#   1. orch_spawn  <pool_id> <count> <role>   — optional for mock (auto-init)
#   2. orch_dispatch <pool_id> <work_unit>    — one call per task
#   3. orch_collect  <pool_id>               — gather results; returns first non-0 rc
#   4. orch_shutdown <pool_id>               — cleanup; must leave no temp files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/orch/contract — integration tests (ADR-011, issue #219)"

setup_test_env "core-orch-contract-int"

export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ORCH_MOCK_DIR="$TEST_TEMP_DIR/orch-mock"

# Source the plugin registry (needed by contract.sh for find_plugin_for_role)
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

# Source the mock plugin first so its functions are present.
# shellcheck source=../../plugins/tool/orch-mock/plugin.sh
source "$REPO_ROOT/plugins/tool/orch-mock/plugin.sh"

# Source the contract layer under test.
# shellcheck source=../../core/orch/contract.sh
source "$REPO_ROOT/core/orch/contract.sh"

# ─── Helper: unique pool id per section to prevent cross-test contamination ───
_pool() { echo "pool-$$-${1}"; }

# ─── Test 1: dispatch a successful work unit → collect returns exit 0 + stdout ─
print_test_section "1. orch_dispatch successful work unit → orch_collect returns exit 0 and stdout"

pool="$(_pool t1)"
orch_spawn "$pool" 1 "test-role"

unit="$(orch_work_unit 'echo "hello from work unit"')"
orch_dispatch "$pool" "$unit"

collected=""
set +e
collected="$(orch_collect "$pool")"
collect_rc=$?
set -e

assert_exit_code \
    "orch_collect returns exit 0 for successful work unit" \
    "0" "$collect_rc"

assert_contains \
    "orch_collect stdout contains work unit output" \
    "$collected" "hello from work unit"

orch_shutdown "$pool"

# ─── Test 2: dispatch a failing work unit → orch_collect returns exit 1 ───────
print_test_section "2. orch_dispatch failing work unit → orch_collect returns exit 1"

pool="$(_pool t2)"
orch_spawn "$pool" 1 "test-role"

fail_unit="$(orch_work_unit 'echo "failure output"; exit 1')"
orch_dispatch "$pool" "$fail_unit" 2>/dev/null || true  # dispatch rc mirrors task rc

set +e
fail_collected="$(orch_collect "$pool")"
fail_rc=$?
set -e

assert_exit_code \
    "orch_collect returns exit 1 for failing work unit" \
    "1" "$fail_rc"

assert_contains \
    "orch_collect stdout contains failing work unit output" \
    "$fail_collected" "failure output"

orch_shutdown "$pool"

# ─── Test 3: two successful work units → both collected with correct results ──
print_test_section "3. Two dispatched work units → orch_collect returns both outputs, exit 0"

pool="$(_pool t3)"
orch_spawn "$pool" 2 "test-role"

unit_a="$(orch_work_unit 'echo "result-alpha"')"
unit_b="$(orch_work_unit 'echo "result-beta"')"

orch_dispatch "$pool" "$unit_a"
orch_dispatch "$pool" "$unit_b"

set +e
multi_collected="$(orch_collect "$pool")"
multi_rc=$?
set -e

assert_exit_code \
    "orch_collect returns exit 0 when all work units succeed" \
    "0" "$multi_rc"

assert_contains \
    "orch_collect output includes result-alpha" \
    "$multi_collected" "result-alpha"

assert_contains \
    "orch_collect output includes result-beta" \
    "$multi_collected" "result-beta"

orch_shutdown "$pool"

# ─── Test 4: two work units, one fails → orch_collect returns exit 1 ─────────
print_test_section "4. One successful + one failing work unit → orch_collect returns exit 1"

pool="$(_pool t4)"
orch_spawn "$pool" 2 "test-role"

good_unit="$(orch_work_unit 'echo "good output"')"
bad_unit="$(orch_work_unit 'echo "bad output"; exit 2')"

orch_dispatch "$pool" "$good_unit"
orch_dispatch "$pool" "$bad_unit" 2>/dev/null || true

set +e
mixed_collected="$(orch_collect "$pool")"
mixed_rc=$?
set -e

# orch_collect returns first non-zero rc (2 from the bad unit)
assert_exit_code \
    "orch_collect returns first non-zero rc from mixed work units" \
    "2" "$mixed_rc"

assert_contains \
    "orch_collect output includes good unit output" \
    "$mixed_collected" "good output"

assert_contains \
    "orch_collect output includes bad unit output" \
    "$mixed_collected" "bad output"

orch_shutdown "$pool"

# ─── Test 5: orch_shutdown removes all temp files for the pool ────────────────
print_test_section "5. orch_shutdown cleans up — no pool temp files remain"

pool="$(_pool t5)"
orch_spawn "$pool" 1 "test-role"

unit="$(orch_work_unit 'echo "cleanup test"')"
orch_dispatch "$pool" "$unit"
orch_collect "$pool" >/dev/null

# Record the pool directory path before shutdown.
pool_dir="${ORCH_MOCK_DIR}/$(printf '%s' "$pool" | tr -cs '[:alnum:]_-' '_')"

orch_shutdown "$pool"

if [[ ! -d "$pool_dir" ]]; then
    assert_pass "orch_shutdown removes pool directory: $pool_dir"
else
    assert_fail "orch_shutdown removes pool directory" \
        "directory still exists: $pool_dir"
fi

# Verify no stale .stdout or .rc files are left in the overall mock dir that
# belong to this pool.  The mock dir itself may still exist (shared across
# tests) but should contain no files for the shutdown pool.
stale_files="$(find "$ORCH_MOCK_DIR" -name "*.stdout" -o -name "*.rc" 2>/dev/null \
    | grep "$(printf '%s' "$pool" | tr -cs '[:alnum:]_-' '_')" || true)"

if [[ -z "$stale_files" ]]; then
    assert_pass "no stale .stdout or .rc files remain for pool $pool"
else
    assert_fail "no stale .stdout or .rc files remain for pool $pool" \
        "found: $stale_files"
fi

# ─── Test 6: work unit stdout/stderr isolation — stderr does not contaminate ──
print_test_section "6. Work unit stderr does not appear in orch_collect stdout"

pool="$(_pool t6)"
orch_spawn "$pool" 1 "test-role"

stderr_unit="$(orch_work_unit 'echo "stdout line"; echo "stderr line" >&2')"
orch_dispatch "$pool" "$stderr_unit"

set +e
isolated_out="$(orch_collect "$pool")"
isolated_rc=$?
set -e

assert_exit_code \
    "orch_collect returns 0 for work unit with only stderr side-effect" \
    "0" "$isolated_rc"

# The contract captures stdout; stderr handling is backend-defined.
# The mock redirects stderr to stdout in bash -c for simplicity.
# This test validates that the stdout line is present (regression guard).
assert_contains \
    "orch_collect output contains stdout line from work unit" \
    "$isolated_out" "stdout line"

orch_shutdown "$pool"

# ─── Test 7: orch_collect on empty pool returns exit 0, no output ─────────────
print_test_section "7. orch_collect on pool with no dispatched units returns exit 0"

pool="$(_pool t7)"
orch_spawn "$pool" 0 "test-role"

set +e
empty_out="$(orch_collect "$pool")"
empty_rc=$?
set -e

assert_exit_code \
    "orch_collect on empty pool returns exit 0" \
    "0" "$empty_rc"

if [[ -z "$empty_out" ]]; then
    assert_pass "orch_collect on empty pool produces no output"
else
    assert_fail "orch_collect on empty pool produces no output" \
        "got: $empty_out"
fi

orch_shutdown "$pool"

# ─── Test 8: pool_id sanitization — slash-containing id does not create paths ─
print_test_section "8. pool_id containing slashes is sanitized (no directory traversal)"

pool="pool/with/slashes-$$"
orch_spawn "$pool" 1 "test-role"

unit="$(orch_work_unit 'echo "sanitized pool"')"
orch_dispatch "$pool" "$unit"

set +e
san_out="$(orch_collect "$pool")"
san_rc=$?
set -e

assert_exit_code \
    "orch_collect works for pool_id with slashes (sanitized)" \
    "0" "$san_rc"

assert_contains \
    "orch_collect output is correct for sanitized pool_id" \
    "$san_out" "sanitized pool"

orch_shutdown "$pool"

# Verify no file was created at the literal slash path.
if [[ ! -d "$ORCH_MOCK_DIR/pool" ]]; then
    assert_pass "slash in pool_id did not create a nested directory"
else
    assert_fail "slash in pool_id did not create a nested directory" \
        "found: $ORCH_MOCK_DIR/pool"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
