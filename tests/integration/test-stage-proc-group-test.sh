#!/usr/bin/env bash
# tests/integration/test-stage-proc-group-test.sh
# Process-group containment for the test stage (issue #1748).
#
# SPEC-1: a job-control spawn resolves to a group distinct from the runner's
# SPEC-2: the group kill reaps forked grandchildren, not just the top PID
# SPEC-3: proc-group.sh exists and exports the prefix, resolve and kill helpers
# SPEC-4: proc-group.sh is a guarded include in route.sh (→ route-missing-include-test.sh)
# SPEC-5: with no .pgid recorded, teardown still terminates via the single PID
# SPEC-6: zbuild_pg_kill refuses a PGID that is the caller's own
#
# Every SPEC runs on every platform. The test stage uses `set -m` rather than
# the router's `setsid` prefix precisely so containment does not depend on
# util-linux — see the comment at the spawn site in plugins/tool/test/plugin.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-stage process-group containment (#1748)"
setup_test_env "test-stage-proc-group"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Conditional source: at the merge-base this file does not exist, and every SPEC
# below must still reach its assertion so the control reddens rather than
# erroring out or hanging.
if [[ -f "$REPO_ROOT/scripts/lib/proc-group.sh" ]]; then
    # shellcheck source=../../scripts/lib/proc-group.sh
    source "$REPO_ROOT/scripts/lib/proc-group.sh"
fi

# ─── SPEC-3: the shared helper exists and exports every symbol ───────────────
# CHANGE: proc-group.sh is a new file; at baseline it does not exist.
print_test_section "SPEC-3: proc-group.sh defines _ZBUILD_PG_PREFIX, zbuild_pg_resolve, zbuild_pg_kill"

if ! declare -p _ZBUILD_PG_PREFIX >/dev/null 2>&1; then
    assert_fail "[SPEC-3] proc-group.sh defines _ZBUILD_PG_PREFIX" "missing"
elif ! declare -F zbuild_pg_kill >/dev/null 2>&1; then
    assert_fail "[SPEC-3] proc-group.sh defines zbuild_pg_kill" "missing"
elif ! declare -F zbuild_pg_resolve >/dev/null 2>&1; then
    assert_fail "[SPEC-3] proc-group.sh defines zbuild_pg_resolve" "missing"
elif ! declare -F zbuild_pid_kill >/dev/null 2>&1; then
    assert_fail "[SPEC-3] proc-group.sh defines zbuild_pid_kill" "missing"
else
    assert_pass "[SPEC-3] proc-group.sh defines the prefix, resolve and both kill helpers"
fi

# ─── SPEC-1: a job-control spawn lands in its own group ─────────────────────
# CHANGE: at baseline zbuild_pg_resolve does not exist, so nothing records a PGID.
print_test_section "SPEC-1: test subprocess tree gets its own PGID"

if ! declare -F zbuild_pg_resolve >/dev/null 2>&1; then
    assert_fail "[SPEC-1] test subprocess PGID differs from runner PGID (own group)" \
        "zbuild_pg_resolve missing"
else
    _spec1_runner_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)"

    # Spawn the way plugin.sh does: job control on, backgrounded, then ask the
    # production resolver what it would record.
    _spec1_pgid="$(
        set -m
        sleep 10 &
        _c=$!
        zbuild_pg_resolve "$_c"
        kill -KILL -- "-$_c" 2>/dev/null || true
        kill -KILL "$_c" 2>/dev/null || true
        wait "$_c" 2>/dev/null || true
    )"

    if [[ -n "$_spec1_pgid" && "$_spec1_pgid" =~ ^[0-9]+$ ]]; then
        assert_pass "[SPEC-1] a PGID is recorded and numeric"
    else
        assert_fail "[SPEC-1] a PGID is recorded and numeric" "got: '$_spec1_pgid'"
    fi
    if [[ -n "$_spec1_pgid" && "$_spec1_pgid" != "$_spec1_runner_pgid" ]]; then
        assert_pass "[SPEC-1] test subprocess PGID differs from runner PGID (own group)"
    else
        assert_fail "[SPEC-1] test subprocess PGID differs from runner PGID (own group)" \
            "PGID='$_spec1_pgid' runner PGID='$_spec1_runner_pgid'"
    fi
fi

# ─── SPEC-2: the group kill reaps forked grandchildren ──────────────────────
# CHANGE: at baseline the single-PID kill leaves the grandchild alive. This is
# the assertion the issue exists for — orphaned workers, not orphaned leaders.
print_test_section "SPEC-2: SIGTERM propagates to all forked children via process-group kill"

if ! declare -F zbuild_pg_kill >/dev/null 2>&1; then
    assert_fail "[SPEC-2] forked grandchild is dead after pg_kill (no survivors)" \
        "zbuild_pg_kill missing"
else
    _spec2_tmpdir="$TEST_TEMP_DIR/spec2"
    mkdir -p "$_spec2_tmpdir"
    _spec2_gc_pid_file="$_spec2_tmpdir/grandchild.pid"

    # A mock suite that forks a worker — the shape a single-PID kill misses.
    # Sleeps are short: a failed kill leaves the `wait` to bound the test, and a
    # 60s bound blows the acceptance harness's own ZBUILD_NEGCTL_TIMEOUT.
    _spec2_result="$(
        set -m
        eval "sleep 10 & printf '%s' \$! > '$_spec2_gc_pid_file'; sleep 10" >/dev/null 2>&1 &
        _c=$!

        _w=0
        while [[ ! -f "$_spec2_gc_pid_file" && "$_w" -lt 30 ]]; do
            sleep 0.1 2>/dev/null || true
            _w=$((_w + 1))
        done
        _gc="$(cat "$_spec2_gc_pid_file" 2>/dev/null || true)"

        zbuild_pg_kill "$(zbuild_pg_resolve "$_c")"
        wait "$_c" 2>/dev/null || true

        kill -0 "$_c" 2>/dev/null && printf 'LEADER_ALIVE ' || printf 'LEADER_DEAD '
        if [[ -n "$_gc" && "$_gc" =~ ^[0-9]+$ ]]; then
            kill -0 "$_gc" 2>/dev/null && printf 'GC_ALIVE' || printf 'GC_DEAD'
            kill -KILL "$_gc" 2>/dev/null || true
        else
            printf 'GC_UNRECORDED'
        fi
    )"

    case "$_spec2_result" in
        "LEADER_DEAD "*) assert_pass "[SPEC-2] group leader is dead after pg_kill" ;;
        *) assert_fail "[SPEC-2] group leader is dead after pg_kill" "got: '$_spec2_result'" ;;
    esac
    case "$_spec2_result" in
        *"GC_DEAD") assert_pass "[SPEC-2] forked grandchild is dead after pg_kill (no survivors)" ;;
        *"GC_UNRECORDED") assert_fail "[SPEC-2] grandchild PID was recorded before kill" \
            "got: '$_spec2_result'" ;;
        *) assert_fail "[SPEC-2] forked grandchild is dead after pg_kill (no survivors)" \
            "got: '$_spec2_result'" ;;
    esac
fi

# ─── SPEC-5: fallback single-PID kill when no PGID was recorded ──────────────
# GUARD: this path existed before the change; tagged but not contorted to fail.
# The grep guard is what keeps the baseline run from hanging on `wait` — without
# it nothing kills the sleep, negctl's 60s budget expires, and every SPEC
# sharing this file reports as an infra timeout instead of an honest red.
print_test_section "SPEC-5: fallback single-PID kill works when no PGID file present"

if ! grep -q '_test_kill_staging_pg' "$REPO_ROOT/plugins/tool/test/plugin.sh" 2>/dev/null; then
    assert_fail "[SPEC-5] fallback single-PID kill terminates process when no PGID file" \
        "_test_kill_staging_pg missing"
else
    (
        [[ -f "$REPO_ROOT/scripts/lib/proc-group.sh" ]] && \
            source "$REPO_ROOT/scripts/lib/proc-group.sh"
        # shellcheck source=../../plugins/tool/test/plugin.sh
        source "$REPO_ROOT/plugins/tool/test/plugin.sh" 2>/dev/null || true

        _spec5_tmpdir="$TEST_TEMP_DIR/spec5"
        mkdir -p "$_spec5_tmpdir"
        _spec5_pid_file="$_spec5_tmpdir/test-stage.pid"
        _spec5_pgid_file="$_spec5_tmpdir/test-stage.pgid"

        sleep 10 &
        _spec5_pid=$!
        printf '%s' "$_spec5_pid" > "$_spec5_pid_file"
        # No pgid file — simulates a spawn whose group could not be proven.

        _test_kill_staging_pg "$_spec5_pid_file" "$_spec5_pgid_file"
        wait "$_spec5_pid" 2>/dev/null || true
        sleep 0.1 2>/dev/null || true

        if kill -0 "$_spec5_pid" 2>/dev/null; then
            printf 'SPEC5_PROC_ALIVE\n'
            kill -KILL "$_spec5_pid" 2>/dev/null || true
        else
            printf 'SPEC5_PROC_DEAD\n'
        fi
    ) > "$TEST_TEMP_DIR/spec5-out.txt" 2>/dev/null || true

    _spec5_out="$(cat "$TEST_TEMP_DIR/spec5-out.txt" 2>/dev/null || echo '')"
    if grep -q 'SPEC5_PROC_DEAD' <<< "$_spec5_out"; then
        assert_pass "[SPEC-5] fallback single-PID kill terminates process when no PGID file"
    else
        assert_fail "[SPEC-5] fallback single-PID kill terminates process when no PGID file" \
            "process survived"
    fi
fi

# ─── SPEC-6: the kill helper will not signal the caller's own group ──────────
# CHANGE: at baseline there is no helper to guard.
print_test_section "SPEC-6: zbuild_pg_kill refuses the caller's own process group"

if ! declare -F zbuild_pg_kill >/dev/null 2>&1; then
    assert_fail "[SPEC-6] zbuild_pg_kill refuses the caller's own PGID" "helper missing"
else
    # `set -m` makes the backgrounded probe a group leader in its own right, so a
    # regressed guard kills only the probe. Without that isolation this test
    # would signal the group the whole suite runs in.
    _spec6_script="$TEST_TEMP_DIR/spec6-probe.sh"
    cat > "$_spec6_script" <<SPEC6EOF
source "$REPO_ROOT/scripts/lib/proc-group.sh"
_self="\$(ps -o pgid= -p \$\$ 2>/dev/null | tr -d ' ')"
zbuild_pg_kill "\$_self"
printf 'SURVIVED\n'
SPEC6EOF
    ( set -m; bash "$_spec6_script" > "$TEST_TEMP_DIR/spec6-out.txt" 2>/dev/null & wait $! ) || true
    _spec6_out="$(cat "$TEST_TEMP_DIR/spec6-out.txt" 2>/dev/null || echo '')"
    if [[ "$_spec6_out" == "SURVIVED" ]]; then
        assert_pass "[SPEC-6] zbuild_pg_kill refuses the caller's own PGID"
    else
        assert_fail "[SPEC-6] zbuild_pg_kill refuses the caller's own PGID" \
            "caller did not survive (got: '$_spec6_out')"
    fi
fi

# ─── SPEC-7: .pid names the suite, not the shell layer above it ─────────────
# `set -m` puts the suite in its own group, so it IS the group leader and the
# two runtime files must agree. They disagree exactly when .pid records the
# enclosing subshell — and since a TERM to that parent does not cascade across
# the group boundary, the PID fallback would then reap the shell and leave the
# workers running: the bug this issue exists to end, reintroduced in its own fix.
print_test_section "SPEC-7: runtime/test-stage.pid records the group leader, not its parent"

if ! grep -q 'zbuild_pg_resolve' "$REPO_ROOT/plugins/tool/test/plugin.sh" 2>/dev/null; then
    assert_fail "[SPEC-7] recorded PID is the group leader" "spawn not wired to proc-group"
else
    _spec7_state="$TEST_TEMP_DIR/spec7-state"
    _spec7_art="$_spec7_state/artifacts"
    mkdir -p "$_spec7_art"
    _spec7_repo="$TEST_TEMP_DIR/spec7-repo"
    mkdir -p "$_spec7_repo"
    git -C "$_spec7_repo" init -q
    git -C "$_spec7_repo" config user.name t
    git -C "$_spec7_repo" config user.email t@t
    printf 'x\n' > "$_spec7_repo/tracked.txt"
    git -C "$_spec7_repo" add -A
    git -C "$_spec7_repo" commit -q -m init
    : > "$TEST_TEMP_DIR/spec7.patch"

    (
        # shellcheck source=../../plugins/tool/test/plugin.sh
        source "$REPO_ROOT/plugins/tool/test/plugin.sh" 2>/dev/null || true
        # Long enough that `ps` still sees the child when the PGID is resolved:
        # an instant command is already reaped, and no group is recorded at all.
        _test_run_inner "$TEST_TEMP_DIR/spec7.patch" "$_spec7_repo" \
            "$_spec7_art/test-results.json" "sleep 2"
    ) >/dev/null 2>&1 || true

    _spec7_rt="$_spec7_state/runtime"
    _spec7_pid="$(cat "$_spec7_rt/test-stage.pid" 2>/dev/null || true)"
    _spec7_pgid="$(cat "$_spec7_rt/test-stage.pgid" 2>/dev/null || true)"

    if [[ -z "$_spec7_pgid" ]]; then
        assert_fail "[SPEC-7] a PGID was recorded for a live suite" \
            "pgid file empty or absent (pid='$_spec7_pid')"
    elif [[ "$_spec7_pid" == "$_spec7_pgid" ]]; then
        assert_pass "[SPEC-7] recorded PID is the group leader (pid == pgid)"
    else
        assert_fail "[SPEC-7] recorded PID is the group leader (pid == pgid)" \
            "pid='$_spec7_pid' pgid='$_spec7_pgid' — .pid names the parent subshell"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
