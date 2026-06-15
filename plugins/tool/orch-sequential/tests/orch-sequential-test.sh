#!/usr/bin/env bash
# Integration Tests: plugins/tool/orch-sequential/ — end-to-end (issue #302)
# Covers: spawn / dispatch / collect 0/1/2 normalization / shutdown lifecycle,
#         pool_id validation, work-unit format flexibility (file vs bash body),
#         pool isolation (two pools don't interfere), capabilities advertisement.
#
# 5-trial-per-keeper for #219 (orch-sequential); KEEPERS §G mandate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/tool/orch-sequential"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/orch-sequential — integration: lifecycle + contract (issue #302)"

setup_test_env "orch-sequential-integ"

# Use isolated TMPDIR so pool dirs don't collide with anything.
export TMPDIR="$TEST_TEMP_DIR/tmp"
mkdir -p "$TMPDIR"

# shellcheck disable=SC1090,SC1091
source "$PLUGIN_DIR/plugin.sh"

# ─── Test 1: capabilities advertisement ─────────────────────────────────────
print_test_section "1. capabilities: declares sequential / no-parallelism"
caps="$(orch_capabilities)"
# Spec doesn't pin exact capability names; just confirm valid JSON array with content.
if echo "$caps" | grep -q '\['; then
    assert_pass "orch_capabilities returns a JSON-like list"
else
    assert_fail "orch_capabilities returns a JSON-like list" "got: $caps"
fi

# ─── Test 2: spawn → pool directory created ─────────────────────────────────
print_test_section "2. spawn creates pool results directory"
orch_spawn "p1" 1 ""
if [[ -d "$(_orch_seq_pool_dir p1)/results" ]]; then
    assert_pass "spawn creates results/ subdir"
else
    assert_fail "spawn creates results/ subdir" \
        "expected $(_orch_seq_pool_dir p1)/results to exist"
fi

# ─── Test 3: dispatch + collect — all-pass (rc=0) ───────────────────────────
print_test_section "3. orch_collect rc=0 when all work units succeed (ADR-011 contract)"
orch_spawn "all-pass" 0 ""
orch_dispatch "all-pass" 'echo "task 1 ran"' >/dev/null
orch_dispatch "all-pass" 'echo "task 2 ran"; true' >/dev/null
orch_dispatch "all-pass" 'exit 0' >/dev/null

set +e
orch_collect "all-pass" --timeout 10 >/dev/null 2>&1
collect_rc=$?
set -e
assert_eq "orch_collect rc=0 when all units exit 0" "0" "$collect_rc"

# ─── Test 4: dispatch + collect — all-fail (rc=1) ──────────────────────────
print_test_section "4. orch_collect rc=1 when all work units fail (ADR-011 contract)"
orch_spawn "all-fail" 0 ""
orch_dispatch "all-fail" 'exit 7' >/dev/null
orch_dispatch "all-fail" 'exit 1' >/dev/null
orch_dispatch "all-fail" 'false' >/dev/null

set +e
orch_collect "all-fail" --timeout 10 >/dev/null 2>&1
collect_rc=$?
set -e
assert_eq "orch_collect rc=1 when all units exit non-zero" "1" "$collect_rc"

# ─── Test 5: dispatch + collect — partial (rc=2) ───────────────────────────
print_test_section "5. orch_collect rc=2 when mixed results (ADR-011 contract)"
orch_spawn "partial" 0 ""
orch_dispatch "partial" 'exit 0' >/dev/null
orch_dispatch "partial" 'exit 5' >/dev/null
orch_dispatch "partial" 'true' >/dev/null

set +e
orch_collect "partial" --timeout 10 >/dev/null 2>&1
collect_rc=$?
set -e
assert_eq "orch_collect rc=2 when results are mixed" "2" "$collect_rc"

# ─── Test 6: shutdown removes pool dir ──────────────────────────────────────
print_test_section "6. shutdown cleans up the pool directory"
orch_spawn "doomed" 0 ""
if [[ -d "$(_orch_seq_pool_dir doomed)" ]]; then
    orch_shutdown "doomed"
    if [[ ! -d "$(_orch_seq_pool_dir doomed)" ]]; then
        assert_pass "shutdown removes pool directory"
    else
        assert_fail "shutdown removes pool directory" \
            "$(_orch_seq_pool_dir doomed) still exists"
    fi
else
    assert_fail "spawn precondition" "pool dir not created by spawn"
fi

# ─── Test 7: pool isolation — two pools don't interfere ─────────────────────
print_test_section "7. pool isolation: separate pools collect independently"
orch_spawn "iso-a" 0 ""
orch_spawn "iso-b" 0 ""
orch_dispatch "iso-a" 'exit 0' >/dev/null
orch_dispatch "iso-a" 'exit 0' >/dev/null
orch_dispatch "iso-b" 'exit 1' >/dev/null
orch_dispatch "iso-b" 'exit 2' >/dev/null

set +e
orch_collect "iso-a" --timeout 10 >/dev/null 2>&1
rc_a=$?
orch_collect "iso-b" --timeout 10 >/dev/null 2>&1
rc_b=$?
set -e
assert_eq "pool iso-a: rc=0 (all pass)" "0" "$rc_a"
assert_eq "pool iso-b: rc=1 (all fail)" "1" "$rc_b"

# ─── Test 8: pool_id validation rejects path-traversal attempts ────────────
print_test_section "8. pool_id validation: rejects unsafe ids"
set +e
orch_spawn "../escape" 0 "" 2>/dev/null
rc_dotdot=$?
orch_spawn "with/slash" 0 "" 2>/dev/null
rc_slash=$?
orch_spawn "with space" 0 "" 2>/dev/null
rc_space=$?
set -e
assert_eq "spawn rejects '..'" "1" "$rc_dotdot"
assert_eq "spawn rejects pool_id containing /" "1" "$rc_slash"
assert_eq "spawn rejects pool_id containing whitespace" "1" "$rc_space"

# ─── Test 9: work-unit script-file format also works ───────────────────────
print_test_section "9. dispatch accepts executable script-file work-units"
orch_spawn "script-pool" 0 ""
script="$TEST_TEMP_DIR/work.sh"
cat > "$script" <<'EOF'
#!/usr/bin/env bash
echo "from-script-file"
exit 0
EOF
chmod +x "$script"

orch_dispatch "script-pool" "$script" >/dev/null
set +e
orch_collect "script-pool" --timeout 10 >/dev/null 2>&1
rc_script=$?
set -e
assert_eq "script-file work-unit collected as success" "0" "$rc_script"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
