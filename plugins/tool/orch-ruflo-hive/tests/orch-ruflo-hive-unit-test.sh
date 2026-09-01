#!/usr/bin/env bash
# Tests: plugins/tool/orch-ruflo-hive/plugin.sh — unit tests (issue #221)
# TDD order: written before implementation to drive the design.
#
# These tests source the hive plugin directly (no contract layer) and
# verify the low-level contract functions behave correctly.  ruflo is mocked
# so no live hive-mind is required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "orch-ruflo-hive — unit tests (issue #221)"

setup_test_env "plugin-orch-ruflo-hive-unit"

export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# Route pool dirs into the sandboxed temp dir so tests are isolated.
export TMPDIR="$TEST_TEMP_DIR/_tmp"
mkdir -p "$TMPDIR"

# ─── Mock ruflo binary ────────────────────────────────────────────────────────
# Write the mock with the actual TEST_TEMP_DIR path expanded
cat > "$TEST_TEMP_DIR/bin/ruflo" <<RUFLO_MOCK_EOF
#!/usr/bin/env bash
echo "CALL: \$*" >> "${TEST_TEMP_DIR}/ruflo.calls"
case "\$1 \$2" in
    "hive-mind init")     exit 0 ;;
    "hive-mind task")     echo "slot-mock-\$\$"; exit 0 ;;
    "hive-mind shutdown") exit 0 ;;
    *) exit 0 ;;
esac
RUFLO_MOCK_EOF
chmod +x "$TEST_TEMP_DIR/bin/ruflo"

# Source the plugin under test.
# shellcheck source=../../../../plugins/tool/orch-ruflo-hive/plugin.sh
source "$REPO_ROOT/plugins/tool/orch-ruflo-hive/plugin.sh"

# ─── Helper: unique pool id per section ──────────────────────────────────────
_pool() { echo "hive-unit-${1}-$$"; }

# ─── Test 1: orch_capabilities returns valid JSON ────────────────────────────
print_test_section "1. orch_capabilities returns valid JSON"

caps="$(orch_capabilities)"

if [[ -n "$caps" ]]; then
    assert_pass "orch_capabilities returns non-empty output"
else
    assert_fail "orch_capabilities returns non-empty output" "got empty string"
fi

if command -v jq >/dev/null 2>&1; then
    if echo "$caps" | jq . >/dev/null 2>&1; then
        assert_pass "orch_capabilities output is valid JSON"
    else
        assert_fail "orch_capabilities output is valid JSON" "jq parse failed: $caps"
    fi
else
    assert_pass "orch_capabilities output is valid JSON (jq unavailable — skipped)"
fi

# ─── Test 2: orch_capabilities JSON has backend=ruflo-hive ───────────────────
print_test_section "2. orch_capabilities JSON has backend=ruflo-hive"

assert_contains \
    "orch_capabilities output contains backend key" \
    "$caps" '"backend"'

assert_contains \
    "orch_capabilities output contains ruflo-hive value" \
    "$caps" '"ruflo-hive"'

# ─── Test 3: orch_capabilities JSON has parallel capability ──────────────────
print_test_section "3. orch_capabilities JSON has parallel capability"

assert_contains \
    "orch_capabilities output contains parallel capability" \
    "$caps" '"parallel"'

assert_contains \
    "orch_capabilities output contains hive_mind capability" \
    "$caps" '"hive_mind"'

assert_contains \
    "orch_capabilities output contains distributed capability" \
    "$caps" '"distributed"'

# ─── Test 4: orch_spawn valid pool_id exits 0 ────────────────────────────────
print_test_section "4. orch_spawn valid pool_id exits 0"

pool="$(_pool t4)"
set +e
orch_spawn "$pool" 2>/dev/null
rc_spawn=$?
set -e

assert_exit_code "orch_spawn valid pool_id exits 0" "0" "$rc_spawn"

pool_dir="$(_orch_hive_pool_dir "$pool")"   # #2004: derive, never hardcode

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

if [[ -d "${pool_dir}/slots" ]]; then
    assert_pass "orch_spawn creates slots/ subdir"
else
    assert_fail "orch_spawn creates slots/ subdir" "not found: ${pool_dir}/slots"
fi

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 5: orch_spawn invalid pool_id (5 variants) all exit 1 ──────────────
print_test_section "5. orch_spawn invalid pool_id (5 variants) all exit 1"

_assert_invalid_spawn() {
    local bad_id="$1" label="$2"
    local rc=0
    set +e
    orch_spawn "$bad_id" 2>/dev/null
    rc=$?
    set -e
    assert_exit_code "orch_spawn rejects ${label}" "1" "$rc"
}

_assert_invalid_spawn "" "empty pool_id"
_assert_invalid_spawn "bad id" "pool_id with space"
_assert_invalid_spawn "../evil" "path-traversal pool_id"
_assert_invalid_spawn "a/b" "slash in pool_id"
long_id="$(printf 'a%.0s' {1..65})"
_assert_invalid_spawn "$long_id" "65-char pool_id (over limit)"

# Verify valid 64-char pool_id IS accepted
ok_id="$(printf 'a%.0s' {1..64})"
set +e
orch_spawn "$ok_id" 2>/dev/null
rc_ok=$?
set -e
assert_exit_code "orch_spawn accepts exactly 64-char pool_id" "0" "$rc_ok"
orch_shutdown "$ok_id" 2>/dev/null || true

# ─── Test 6: orch_spawn ruflo not in PATH exits 1 with diagnostic ─────────────
print_test_section "6. orch_spawn ruflo not in PATH exits 1 with diagnostic"

# Hide ruflo by using a PATH that excludes TEST_TEMP_DIR/bin
_saved_path="$PATH"
_empty_bin="$TEST_TEMP_DIR/_tmp/empty_bin"
mkdir -p "$_empty_bin"
export PATH="$_empty_bin"

set +e
diag_out="$(orch_spawn "hive-no-ruflo-$$" 2>&1)"
rc_noruflo=$?
set -e

export PATH="$_saved_path"

assert_exit_code "orch_spawn exits 1 when ruflo not in PATH" "1" "$rc_noruflo"

if grep -qiF "ruflo" 2>/dev/null <<< "$diag_out"; then
    assert_pass "diagnostic message mentions ruflo"
else
    assert_fail "diagnostic message mentions ruflo" "output: $diag_out"
fi

# ─── Test 7: orch_dispatch valid args exits 0 and prints slot_id ──────────────
print_test_section "7. orch_dispatch valid args exits 0 and prints slot_id"

pool="$(_pool t7)"
orch_spawn "$pool" 2>/dev/null

work_unit="$TEST_TEMP_DIR/t7-unit.sh"
printf '#!/usr/bin/env bash\necho "hello"\n' > "$work_unit"
chmod +x "$work_unit"

set +e
slot_id="$(orch_dispatch "$pool" "$work_unit" 2>/dev/null)"
rc_dispatch=$?
set -e

assert_exit_code "orch_dispatch valid args exits 0" "0" "$rc_dispatch"

if [[ -n "$slot_id" ]]; then
    assert_pass "orch_dispatch prints a non-empty slot_id: $slot_id"
else
    assert_fail "orch_dispatch prints a non-empty slot_id" "got empty string"
fi

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 8: orch_dispatch non-executable work_unit exits 1 ──────────────────
print_test_section "8. orch_dispatch non-executable work_unit exits 1"

pool="$(_pool t8)"
orch_spawn "$pool" 2>/dev/null

non_exec="$TEST_TEMP_DIR/t8-non-exec.sh"
printf '#!/usr/bin/env bash\necho "should not run"\n' > "$non_exec"
# Deliberately NOT chmod +x

set +e
orch_dispatch "$pool" "$non_exec" 2>/dev/null
rc_nonexec=$?
set -e

assert_exit_code "orch_dispatch rejects non-executable file" "1" "$rc_nonexec"

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 9: orch_dispatch non-existent work_unit exits 1 ────────────────────
print_test_section "9. orch_dispatch non-existent work_unit exits 1"

pool="$(_pool t9)"
orch_spawn "$pool" 2>/dev/null

set +e
orch_dispatch "$pool" "/tmp/does-not-exist-zbuild-hive-test.sh" 2>/dev/null
rc_missing=$?
set -e

assert_exit_code "orch_dispatch rejects path to non-existent file" "1" "$rc_missing"

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 10: orch_dispatch invalid pool_id exits 1 (ruflo NOT called) ────────
print_test_section "10. orch_dispatch invalid pool_id exits 1; ruflo not called"

# Clear call log
rm -f "$TEST_TEMP_DIR/ruflo.calls"

work_unit_t10="$TEST_TEMP_DIR/t10-unit.sh"
printf '#!/usr/bin/env bash\necho "t10"\n' > "$work_unit_t10"
chmod +x "$work_unit_t10"

set +e
orch_dispatch "bad pool id" "$work_unit_t10" 2>/dev/null
rc_badpool=$?
set -e

assert_exit_code "orch_dispatch invalid pool_id exits 1" "1" "$rc_badpool"

# ruflo.calls should not have hive-mind task entry since we bailed before calling ruflo
if [[ ! -f "$TEST_TEMP_DIR/ruflo.calls" ]] || ! grep -q "hive-mind task" "$TEST_TEMP_DIR/ruflo.calls" 2>/dev/null; then
    assert_pass "ruflo hive-mind task NOT called for invalid pool_id"
else
    assert_fail "ruflo hive-mind task NOT called for invalid pool_id" \
        "ruflo.calls: $(cat "$TEST_TEMP_DIR/ruflo.calls" 2>/dev/null)"
fi

# ─── Test 11: orch_collect empty pool exits 0 ────────────────────────────────
print_test_section "11. orch_collect empty pool exits 0"

pool="$(_pool t11)"
orch_spawn "$pool" 2>/dev/null

set +e
orch_collect "$pool" >/dev/null 2>/dev/null
rc_empty=$?
set -e

assert_exit_code "orch_collect empty pool exits 0" "0" "$rc_empty"

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 12: orch_collect invalid pool_id exits 1 ───────────────────────────
print_test_section "12. orch_collect invalid pool_id exits 1"

set +e
orch_collect "bad pool id" 2>/dev/null
rc_badcol=$?
set -e

assert_exit_code "orch_collect invalid pool_id exits 1" "1" "$rc_badcol"

# ─── Test 13: orch_shutdown valid pool_id exits 0 ────────────────────────────
print_test_section "13. orch_shutdown valid pool_id exits 0"

pool="$(_pool t13)"
orch_spawn "$pool" 2>/dev/null

set +e
orch_shutdown "$pool" 2>/dev/null
rc_shut=$?
set -e

assert_exit_code "orch_shutdown valid pool_id exits 0" "0" "$rc_shut"

pool_dir="$(_orch_hive_pool_dir "$pool")"   # #2004: derive, never hardcode
if [[ ! -d "$pool_dir" ]]; then
    assert_pass "orch_shutdown removes pool directory"
else
    assert_fail "orch_shutdown removes pool directory" "dir still exists: $pool_dir"
fi

# ─── Test 14: orch_shutdown non-existent pool exits 0 (idempotent) ────────────
print_test_section "14. orch_shutdown non-existent pool exits 0 (idempotent)"

set +e
orch_shutdown "hive-nonexistent-$$" 2>/dev/null
rc_idempotent=$?
set -e

assert_exit_code "orch_shutdown non-existent pool exits 0 (idempotent)" "0" "$rc_idempotent"

# ─── Cleanup ──────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }
cleanup_test_env
print_test_results
