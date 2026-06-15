#!/usr/bin/env bash
# Tests: plugins/tool/orch-bash-parallel/plugin.sh — unit tests (issue #220)
# TDD order: written before implementation to drive the design.
#
# These tests source the parallel plugin directly (no contract layer) and
# verify the low-level contract functions behave correctly without spawning
# real background work (structurally — we test orch_spawn dir layout,
# orch_capabilities JSON shape, and pool_id validation).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "orch-bash-parallel — unit tests (issue #220)"

setup_test_env "core-orch-parallel-unit"

export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# Route pool dirs into the sandboxed temp dir so tests are isolated.
export TMPDIR="$TEST_TEMP_DIR/_tmp"
mkdir -p "$TMPDIR"

# Source the plugin under test.
# shellcheck source=../../plugins/tool/orch-bash-parallel/plugin.sh
source "$REPO_ROOT/plugins/tool/orch-bash-parallel/plugin.sh"

# ─── Helper: unique pool id per section ──────────────────────────────────────
_pool() { echo "par-unit-${1}-$$"; }

# ─── Test 1: orch_spawn creates pool dir + results/ + pids/ subdirs ──────────
print_test_section "1. orch_spawn creates pool dir with results/ and pids/ subdirs"

pool="$(_pool t1)"
orch_spawn "$pool"

# #898: ask the plugin where the pool dir lives (now per-run namespaced) rather
# than hardcoding the flat ${TMPDIR}/zbuild-pool-* path.
pool_dir="$(_orch_par_pool_dir "$pool")"

if [[ -d "$pool_dir" ]]; then
    assert_pass "orch_spawn creates pool directory: $pool_dir"
else
    assert_fail "orch_spawn creates pool directory" "not found: $pool_dir"
fi

if [[ -d "${pool_dir}/results" ]]; then
    assert_pass "orch_spawn creates results/ subdir"
else
    assert_fail "orch_spawn creates results/ subdir" "not found: ${pool_dir}/results"
fi

if [[ -d "${pool_dir}/pids" ]]; then
    assert_pass "orch_spawn creates pids/ subdir"
else
    assert_fail "orch_spawn creates pids/ subdir" "not found: ${pool_dir}/pids"
fi

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 2: orch_capabilities returns valid JSON with backend=bash-parallel ──
print_test_section "2. orch_capabilities returns JSON with backend=bash-parallel"

caps="$(orch_capabilities)"

if [[ -n "$caps" ]]; then
    assert_pass "orch_capabilities returns non-empty output"
else
    assert_fail "orch_capabilities returns non-empty output" "got empty string"
fi

assert_contains \
    "orch_capabilities output contains backend key" \
    "$caps" '"backend"'

assert_contains \
    "orch_capabilities output contains bash-parallel value" \
    "$caps" '"bash-parallel"'

assert_contains \
    "orch_capabilities output contains parallel capability" \
    "$caps" '"parallel"'

assert_contains \
    "orch_capabilities output contains fanout_parallel capability" \
    "$caps" '"fanout_parallel"'

# ─── Test 3: Invalid pool_id returns rc=1 in ALL five contract functions ───────
print_test_section "3. Invalid pool_id returns rc=1 in all five contract functions"

_assert_invalid_pool() {
    local fn="$1" bad_id="$2" label="$3"
    local rc=0
    set +e
    case "$fn" in
        spawn)  orch_spawn "$bad_id" 2>/dev/null; rc=$? ;;
        dispatch) orch_dispatch "$bad_id" "/dev/null" 2>/dev/null; rc=$? ;;
        collect)  orch_collect "$bad_id" 2>/dev/null; rc=$? ;;
        shutdown) orch_shutdown "$bad_id" 2>/dev/null; rc=$? ;;
        capabilities) orch_capabilities 2>/dev/null; rc=$? ;;
    esac
    set -e
    [[ "$fn" == "capabilities" ]] \
        && assert_exit_code "orch_capabilities ignores pool_id (no arg)" "0" "$rc" \
        || assert_exit_code "${fn} rejects ${label}" "1" "$rc"
}

for bad_id in "a/b" "../bad" "" "bad id"; do
    _assert_invalid_pool spawn      "$bad_id" "pool_id='${bad_id}'"
    _assert_invalid_pool dispatch   "$bad_id" "pool_id='${bad_id}'"
    _assert_invalid_pool collect    "$bad_id" "pool_id='${bad_id}'"
    _assert_invalid_pool shutdown   "$bad_id" "pool_id='${bad_id}'"
done

# 65-char (over limit)
long_id="$(printf 'a%.0s' {1..65})"
_assert_invalid_pool spawn    "$long_id" "65-char pool_id"
_assert_invalid_pool dispatch "$long_id" "65-char pool_id"
_assert_invalid_pool collect  "$long_id" "65-char pool_id"
_assert_invalid_pool shutdown "$long_id" "65-char pool_id"

# Verify a valid 64-char pool_id is accepted by spawn
ok_id="$(printf 'a%.0s' {1..64})"
set +e
orch_spawn "$ok_id" 2>/dev/null
rc_ok=$?
set -e
assert_exit_code "orch_spawn accepts exactly 64-char pool_id" "0" "$rc_ok"
orch_shutdown "$ok_id" 2>/dev/null || true

# ─── Test 4: orch_dispatch rejects non-executable work_unit ──────────────────
print_test_section "4. orch_dispatch rejects non-executable work_unit"

pool="$(_pool t4)"
orch_spawn "$pool"

# Create a file that is NOT executable
non_exec="$TEST_TEMP_DIR/non-exec.sh"
echo "#!/usr/bin/env bash" > "$non_exec"
# Do NOT chmod +x

set +e
orch_dispatch "$pool" "$non_exec" 2>/dev/null
rc_nonexec=$?
set -e
assert_exit_code "orch_dispatch rejects non-executable file" "1" "$rc_nonexec"

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 5: orch_dispatch rejects non-file work_unit ────────────────────────
print_test_section "5. orch_dispatch rejects non-file (bash body string) work_unit"

pool="$(_pool t5)"
orch_spawn "$pool"

set +e
orch_dispatch "$pool" "echo hello" 2>/dev/null
rc_nofile=$?
set -e
assert_exit_code "orch_dispatch rejects bash-body string (not a file)" "1" "$rc_nofile"

# Also reject a path to a file that does not exist
set +e
orch_dispatch "$pool" "/tmp/does-not-exist-zbuild-test.sh" 2>/dev/null
rc_missing=$?
set -e
assert_exit_code "orch_dispatch rejects path to non-existent file" "1" "$rc_missing"

orch_shutdown "$pool" 2>/dev/null || true

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
