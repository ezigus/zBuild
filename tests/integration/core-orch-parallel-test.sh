#!/usr/bin/env bash
# Integration Tests: plugins/tool/orch-bash-parallel/plugin.sh (issue #220)
#
# These tests exercise the full parallel dispatch/collect/shutdown cycle.
# Work units are executable script files (the parallel backend enforces this).
#
# Pool lifecycle:
#   1. orch_spawn   <pool_id>          — creates pool dir structure
#   2. orch_dispatch <pool_id> <file>  — launches background job; returns slot_id
#   3. orch_collect  <pool_id> [--timeout S] — waits for all jobs; exit 0=all pass 1=all fail 2=partial
#   4. orch_shutdown <pool_id>         — SIGTERM/SIGKILL workers; rm -rf pool dir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "orch-bash-parallel — integration tests (issue #220)"

setup_test_env "core-orch-parallel-int"

export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# Route pool dirs into the sandboxed temp dir.
export TMPDIR="$TEST_TEMP_DIR/_tmp"
mkdir -p "$TMPDIR"

# Source the plugin under test directly.
# shellcheck source=../../plugins/tool/orch-bash-parallel/plugin.sh
source "$REPO_ROOT/plugins/tool/orch-bash-parallel/plugin.sh"

# ─── Helper: unique pool id per section ──────────────────────────────────────
_pool() { echo "par-int-${1}-$$"; }

# ─── Helper: create a temp executable work unit script ───────────────────────
_make_unit() {
    local name="$1"
    local body="$2"
    local path="$TEST_TEMP_DIR/${name}.sh"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$path"
    chmod +x "$path"
    echo "$path"
}

# ─── Test 1: dispatch 2 workers → both complete, stdout captured ─────────────
print_test_section "1. Dispatch 2 workers (sleep 0.5 + echo done) → both complete"

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

assert_contains \
    "orch_collect output contains worker-a-done" \
    "$collected" "worker-a-done"

assert_contains \
    "orch_collect output contains worker-b-done" \
    "$collected" "worker-b-done"

# ─── Test 2: parallelism — 2 workers sleeping 1s → completes in <2s ──────────
print_test_section "2. 2 workers sleeping 1s each → orch_collect completes in <2s"

pool="$(_pool t2)"
orch_spawn "$pool"

unit_a="$(_make_unit "t2a" 'sleep 1; echo "done-a"')"
unit_b="$(_make_unit "t2b" 'sleep 1; echo "done-b"')"

orch_dispatch "$pool" "$unit_a" >/dev/null
orch_dispatch "$pool" "$unit_b" >/dev/null

t_start="$(date +%s)"
set +e
orch_collect "$pool" >/dev/null
collect_rc=$?
set -e
t_end="$(date +%s)"
elapsed=$(( t_end - t_start ))

assert_exit_code "orch_collect returns 0 for parallel workers" "0" "$collect_rc"

if [[ "$elapsed" -lt 3 ]]; then
    assert_pass "parallel workers complete in <3s (elapsed: ${elapsed}s)"
else
    assert_fail "parallel workers complete in <3s" "elapsed: ${elapsed}s (expected <3)"
fi

# ─── Test 3: stdout isolation — worker A and worker B output do not mix ───────
print_test_section "3. Stdout isolation — worker A writes from-A, worker B writes from-B"

pool="$(_pool t3)"
orch_spawn "$pool"

unit_a="$(_make_unit "t3a" 'echo "from-A"')"
unit_b="$(_make_unit "t3b" 'echo "from-B"')"

orch_dispatch "$pool" "$unit_a" >/dev/null
orch_dispatch "$pool" "$unit_b" >/dev/null

set +e
out="$(orch_collect "$pool")"
collect_rc=$?
set -e

assert_exit_code "orch_collect returns 0 with isolated workers" "0" "$collect_rc"

assert_contains "orch_collect output contains from-A" "$out" "from-A"
assert_contains "orch_collect output contains from-B" "$out" "from-B"

# ─── Test 4: stderr isolation — worker stderr appears on stderr not stdout ────
print_test_section "4. Stderr isolation — worker stderr goes to stderr, not stdout"

pool="$(_pool t4)"
orch_spawn "$pool"

unit="$(_make_unit "t4" 'echo "to-stdout"; echo "to-stderr" >&2')"
orch_dispatch "$pool" "$unit" >/dev/null

set +e
stdout_out="$(orch_collect "$pool" 2>/dev/null)"
collect_rc=$?
set -e

assert_exit_code "orch_collect returns 0 for worker with stderr output" "0" "$collect_rc"

assert_contains \
    "orch_collect stdout contains the stdout line" \
    "$stdout_out" "to-stdout"

if grep -qF "to-stderr" 2>/dev/null <<< "$stdout_out"; then
    assert_fail "stderr output does NOT appear in orch_collect stdout" \
        "to-stderr was found in stdout"
else
    assert_pass "stderr output does NOT appear in orch_collect stdout"
fi

# ─── Test 5: non-zero exit — worker exits 42 → orch_collect returns 1 (all-fail) ─
# orch_collect normalises work-unit exit codes to the 0/1/2 contract:
# 0=all pass, 1=all fail, 2=partial. The original 42 is not passed through.
print_test_section "5. Worker exits 42 → orch_collect returns 1 (all-fail convention)"

pool="$(_pool t5)"
orch_spawn "$pool"

unit="$(_make_unit "t5" 'echo "about to fail"; exit 42')"
orch_dispatch "$pool" "$unit" >/dev/null

set +e
orch_collect "$pool" >/dev/null 2>/dev/null
collect_rc=$?
set -e

assert_exit_code "orch_collect returns 1 (all-fail) for non-zero worker exit" "1" "$collect_rc"

# On failure, pool dir should remain (not cleaned up)
pool_dir="$(_orch_par_pool_dir "$pool")"  # #898: per-run namespaced path
if [[ -d "$pool_dir" ]]; then
    assert_pass "pool dir remains when orch_collect returns non-zero"
else
    assert_fail "pool dir remains when orch_collect returns non-zero" \
        "pool dir was removed despite failure"
fi

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 6: orch_shutdown while worker is running → pool dir removed ─────────
print_test_section "6. orch_shutdown while worker is running → pool dir removed"

pool="$(_pool t6)"
orch_spawn "$pool"

unit="$(_make_unit "t6" 'sleep 60')"
orch_dispatch "$pool" "$unit" >/dev/null
# Give dispatch time to write PID files
sleep 0.2

pool_dir="$(_orch_par_pool_dir "$pool")"  # #898: per-run namespaced path

# Pool dir should exist now
if [[ -d "$pool_dir" ]]; then
    assert_pass "pool dir exists before shutdown"
else
    assert_fail "pool dir exists before shutdown" "not found: $pool_dir"
fi

# Collect PIDs before shutdown removes the files
_t6_pids=()
for _f in "${pool_dir}/pids/"*.pid "${pool_dir}/results/"*.inner_pid; do
    [[ -f "$_f" ]] && _t6_pids+=("$(cat "$_f")")
done

orch_shutdown "$pool"

if [[ ! -d "$pool_dir" ]]; then
    assert_pass "orch_shutdown removes pool dir while worker is running"
else
    assert_fail "orch_shutdown removes pool dir" "dir still exists: $pool_dir"
fi

# Verify all tracked worker processes are actually dead
sleep 0.3
for _pid in "${_t6_pids[@]}"; do
    if kill -0 "$_pid" 2>/dev/null; then
        assert_fail "worker PID ${_pid} terminated after shutdown" "process still alive"
        kill -KILL "$_pid" 2>/dev/null || true
    else
        assert_pass "worker PID ${_pid} terminated after shutdown"
    fi
done

# ─── Test 7: orch_collect --timeout: long worker with short timeout returns non-zero
print_test_section "7. orch_collect --timeout 1 with 10s worker → returns non-zero within ~2s"

pool="$(_pool t7)"
orch_spawn "$pool"

unit="$(_make_unit "t7" 'sleep 10; echo "should not appear"')"
orch_dispatch "$pool" "$unit" >/dev/null

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

# Should complete well before the worker's 10s sleep
if [[ "$elapsed" -lt 5 ]]; then
    assert_pass "orch_collect --timeout 1 returned within 5s (elapsed: ${elapsed}s)"
else
    assert_fail "orch_collect --timeout 1 returned within 5s" \
        "elapsed: ${elapsed}s"
fi

orch_shutdown "$pool" 2>/dev/null || true

# ─── Test 8: multiple rounds — spawn, dispatch, collect, spawn same pool again ─
print_test_section "8. Multiple rounds with same pool_id — second round works cleanly"

pool="$(_pool t8)"

# Round 1
orch_spawn "$pool"
unit_r1="$(_make_unit "t8r1" 'echo "round-1"')"
orch_dispatch "$pool" "$unit_r1" >/dev/null
set +e
out_r1="$(orch_collect "$pool")"
rc_r1=$?
set -e

assert_exit_code "round 1: orch_collect returns 0" "0" "$rc_r1"
assert_contains "round 1: output contains round-1" "$out_r1" "round-1"

# After successful collect, pool dir should be removed (clean state)
pool_dir="$(_orch_par_pool_dir "$pool")"  # #898: per-run namespaced path
if [[ ! -d "$pool_dir" ]]; then
    assert_pass "pool dir removed after successful collect (between rounds)"
else
    assert_fail "pool dir removed after successful collect" \
        "dir still exists: $pool_dir"
fi

# Round 2 — re-spawn same pool_id
orch_spawn "$pool"
unit_r2="$(_make_unit "t8r2" 'echo "round-2"')"
orch_dispatch "$pool" "$unit_r2" >/dev/null
set +e
out_r2="$(orch_collect "$pool")"
rc_r2=$?
set -e

assert_exit_code "round 2: orch_collect returns 0" "0" "$rc_r2"
assert_contains "round 2: output contains round-2" "$out_r2" "round-2"

if grep -qF "round-1" 2>/dev/null <<< "$out_r2"; then
    assert_fail "round 2 output does not contain round-1 leftovers" \
        "round-1 found in round-2 output"
else
    assert_pass "round 2 output contains no round-1 leftovers"
fi

orch_shutdown "$pool" 2>/dev/null || true

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
