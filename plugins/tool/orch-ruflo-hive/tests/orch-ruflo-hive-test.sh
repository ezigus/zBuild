#!/usr/bin/env bash
# Integration Tests: plugins/tool/orch-ruflo-hive/plugin.sh (issue #221)
#
# These tests exercise the full parallel dispatch/collect/shutdown cycle with
# real executable work units.  ruflo is mocked (accepts hive-mind commands,
# exits 0) so no live hive-mind is required.
#
# Pool lifecycle:
#   1. orch_spawn   <pool_id>          — creates pool dir structure
#   2. orch_dispatch <pool_id> <file>  — launches background job; returns slot_id
#   3. orch_collect  <pool_id> [--timeout S] — waits for all jobs; returns first non-0 rc
#   4. orch_shutdown <pool_id>         — SIGTERM/SIGKILL workers; rm -rf pool dir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "orch-ruflo-hive — integration tests (issue #221)"

setup_test_env "plugin-orch-ruflo-hive-int"

export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# Route pool dirs into the sandboxed temp dir.
export TMPDIR="$TEST_TEMP_DIR/_tmp"
mkdir -p "$TMPDIR"

# ─── Mock ruflo binary ────────────────────────────────────────────────────────
# Accepts all hive-mind commands, exits 0
cat > "$TEST_TEMP_DIR/bin/ruflo" <<RUFLO_MOCK_EOF
#!/usr/bin/env bash
# Integration mock: accept all hive-mind commands silently
case "\$1 \$2" in
    "hive-mind init")     exit 0 ;;
    "hive-mind task")     exit 0 ;;
    "hive-mind shutdown") exit 0 ;;
    *) exit 0 ;;
esac
RUFLO_MOCK_EOF
chmod +x "$TEST_TEMP_DIR/bin/ruflo"

# Source the plugin under test directly.
# shellcheck source=../../../../plugins/tool/orch-ruflo-hive/plugin.sh
source "$REPO_ROOT/plugins/tool/orch-ruflo-hive/plugin.sh"

# ─── Helper: unique pool id per section ──────────────────────────────────────
_pool() { echo "hive-int-${1}-$$"; }

# ─── Helper: create a temp executable work unit script ───────────────────────
_make_unit() {
    local name="$1"
    local body="$2"
    local path="$TEST_TEMP_DIR/${name}.sh"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$path"
    chmod +x "$path"
    echo "$path"
}

# ─── Test 1-3: Concurrent dispatch race ──────────────────────────────────────
print_test_section "1. Dispatch 2 workers → orch_collect returns 0"

pool="$(_pool t1)"
orch_spawn "$pool"

unit_a="$(_make_unit "t1a" 'sleep 0.2; echo "worker-a-done"')"
unit_b="$(_make_unit "t1b" 'sleep 0.2; echo "worker-b-done"')"

orch_dispatch "$pool" "$unit_a" >/dev/null
orch_dispatch "$pool" "$unit_b" >/dev/null

set +e
collected="$(orch_collect "$pool")"
collect_rc=$?
set -e

assert_exit_code "orch_collect returns 0 when both workers succeed" "0" "$collect_rc"

print_test_section "2. Both worker outputs are present after collect"

assert_contains \
    "orch_collect output contains worker-a-done" \
    "$collected" "worker-a-done"

assert_contains \
    "orch_collect output contains worker-b-done" \
    "$collected" "worker-b-done"

print_test_section "3. Collected output is non-empty"

if [[ -n "$collected" ]]; then
    assert_pass "orch_collect output is non-empty"
else
    assert_fail "orch_collect output is non-empty" "got empty string"
fi

# ─── Test 4-5: Interrupt dispatch ────────────────────────────────────────────
print_test_section "4. Interrupt dispatch: work unit killed via orch_shutdown"

pool="$(_pool t4)"
orch_spawn "$pool"

unit_long="$(_make_unit "t4-long" 'sleep 60; echo "should-not-appear"')"
orch_dispatch "$pool" "$unit_long" >/dev/null

# Give dispatch time to write PID files and start the inner process
sleep 0.3

pool_dir="${TMPDIR}/zbuild-hive-${pool}"

# Collect worker PIDs before shutdown removes the files
_t4_pids=()
for _f in "${pool_dir}/slots/"*.pid "${pool_dir}/results/"*.inner_pid; do
    [[ -f "$_f" ]] && _t4_pids+=("$(cat "$_f")")
done

if [[ "${#_t4_pids[@]}" -gt 0 ]]; then
    assert_pass "t4: tracked at least one worker PID before shutdown (${#_t4_pids[@]} total)"
else
    assert_fail "t4: tracked at least one worker PID before shutdown" "no PID files found under $pool_dir"
fi

orch_shutdown "$pool"

if [[ ! -d "$pool_dir" ]]; then
    assert_pass "orch_shutdown cleans up pool dir after interrupting worker"
else
    assert_fail "orch_shutdown cleans up pool dir after interrupting worker" \
        "dir still exists: $pool_dir"
fi

print_test_section "5. No leftover .tmp files after interrupt and shutdown"

# Check that no zbuild-hive temp files remain in TMPDIR for this pool
leftover_count=0
_hive_prefix="${TMPDIR}/zbuild-hive-${pool}"
for _f in "${_hive_prefix}"*.tmp; do
    [[ -f "$_f" ]] && leftover_count=$((leftover_count + 1)) || true
done

if [[ "$leftover_count" -eq 0 ]]; then
    assert_pass "no leftover .tmp files after shutdown"
else
    assert_fail "no leftover .tmp files after shutdown" \
        "found $leftover_count .tmp file(s)"
fi

# ─── Test 6: Work unit exits non-zero → orch_collect returns 1 (all-fail) ────
# orch_collect normalises work-unit exit codes to the 0/1/2 contract:
# 0=all pass, 1=all fail, 2=partial. The original exit code is not passed through.
print_test_section "6. Work unit exits 42 → orch_collect returns 1 (all-fail convention)"

pool="$(_pool t6)"
orch_spawn "$pool"

unit_fail="$(_make_unit "t6-fail" 'echo "about to fail"; exit 42')"
orch_dispatch "$pool" "$unit_fail" >/dev/null

set +e
orch_collect "$pool" >/dev/null 2>/dev/null
collect_rc=$?
set -e

assert_exit_code "orch_collect returns 1 (all-fail) for non-zero work unit exit" "1" "$collect_rc"

# On failure, pool dir should remain (not auto-cleaned)
pool_dir="${TMPDIR}/zbuild-hive-${pool}"
if [[ -d "$pool_dir" ]]; then
    assert_pass "pool dir remains when orch_collect returns non-zero"
else
    assert_fail "pool dir remains when orch_collect returns non-zero" \
        "pool dir was removed despite failure"
fi

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 7: Work unit stdout → orch_collect streams it ──────────────────────
print_test_section "7. Work unit stdout is streamed by orch_collect"

pool="$(_pool t7)"
orch_spawn "$pool"

unit_out="$(_make_unit "t7-out" 'echo "hive-output-marker"')"
orch_dispatch "$pool" "$unit_out" >/dev/null

set +e
out="$(orch_collect "$pool")"
collect_rc=$?
set -e

assert_exit_code "orch_collect returns 0 for stdout-only worker" "0" "$collect_rc"
assert_contains "orch_collect streams work unit stdout" "$out" "hive-output-marker"

# ─── Test 8: orch_collect --timeout with sleep-10 work unit ──────────────────
print_test_section "8. orch_collect --timeout 1 with sleep-10 worker → exits non-zero within 5s"

pool="$(_pool t8)"
orch_spawn "$pool"

unit_slow="$(_make_unit "t8-slow" 'sleep 10; echo "should not appear"')"
orch_dispatch "$pool" "$unit_slow" >/dev/null

t_start="$(date +%s)"
set +e
orch_collect "$pool" --timeout 1 >/dev/null 2>/dev/null
collect_rc=$?
set -e
t_end="$(date +%s)"
elapsed=$(( t_end - t_start ))

if [[ "$collect_rc" -ne 0 ]]; then
    assert_pass "orch_collect --timeout returns non-zero when worker timed out"
else
    assert_fail "orch_collect --timeout returns non-zero when worker timed out" \
        "got rc=0"
fi

if [[ "$elapsed" -lt 5 ]]; then
    assert_pass "orch_collect --timeout 1 returned within 5s (elapsed: ${elapsed}s)"
else
    assert_fail "orch_collect --timeout 1 returned within 5s" \
        "elapsed: ${elapsed}s"
fi

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 9: orch_shutdown kills in-flight processes ─────────────────────────
print_test_section "9. orch_shutdown kills in-flight processes"

pool="$(_pool t9)"
orch_spawn "$pool"

unit_inf="$(_make_unit "t9-inf" 'sleep 60')"
orch_dispatch "$pool" "$unit_inf" >/dev/null
# Give dispatch time to write PID files and launch inner process
sleep 0.3

pool_dir="${TMPDIR}/zbuild-hive-${pool}"

# Collect all tracked PIDs before shutdown removes the files
_t9_pids=()
for _f in "${pool_dir}/slots/"*.pid "${pool_dir}/results/"*.inner_pid; do
    [[ -f "$_f" ]] && _t9_pids+=("$(cat "$_f")")
done

if [[ "${#_t9_pids[@]}" -gt 0 ]]; then
    assert_pass "t9: tracked at least one worker PID before shutdown (${#_t9_pids[@]} total)"
else
    assert_fail "t9: tracked at least one worker PID before shutdown" "no PID files found under $pool_dir"
fi

orch_shutdown "$pool"

# Give signals time to propagate
sleep 0.3

for _pid in "${_t9_pids[@]}"; do
    if kill -0 "$_pid" 2>/dev/null; then
        assert_fail "worker PID ${_pid} terminated after shutdown" "process still alive"
        kill -KILL "$_pid" 2>/dev/null || true
    else
        assert_pass "worker PID ${_pid} terminated after shutdown"
    fi
done

# ─── Cleanup ──────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }
cleanup_test_env
print_test_results
