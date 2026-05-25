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

pool_dir="${TMPDIR}/zbuild-pool-${pool}"

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

# ─── Test 3: Invalid pool_id returns rc=1 ─────────────────────────────────────
print_test_section "3. Invalid pool_id returns rc=1 in all contract functions"

# Test pool_id with path separator
set +e
orch_spawn "a/b" 2>/dev/null
rc_slash=$?
set -e
assert_exit_code "orch_spawn rejects pool_id with slash (a/b)" "1" "$rc_slash"

# Test pool_id with ..
set +e
orch_spawn "../bad" 2>/dev/null
rc_dotdot=$?
set -e
assert_exit_code "orch_spawn rejects pool_id with .. (../bad)" "1" "$rc_dotdot"

# Test empty string
set +e
orch_spawn "" 2>/dev/null
rc_empty=$?
set -e
assert_exit_code "orch_spawn rejects empty pool_id" "1" "$rc_empty"

# Test 65-character string (over the 64-char limit)
long_id="$(printf 'a%.0s' {1..65})"
set +e
orch_spawn "$long_id" 2>/dev/null
rc_long=$?
set -e
assert_exit_code "orch_spawn rejects 65-char pool_id (over limit)" "1" "$rc_long"

# Test pool_id with space
set +e
orch_spawn "bad id" 2>/dev/null
rc_space=$?
set -e
assert_exit_code "orch_spawn rejects pool_id with whitespace" "1" "$rc_space"

# Verify a valid 64-char pool_id is accepted
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
