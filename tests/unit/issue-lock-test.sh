#!/usr/bin/env bash
# Tests: the per-issue admission lock (#1688/#1764, ADR-059 §4).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/issue-lock.sh
source "$REPO_ROOT/core/state/issue-lock.sh"

print_test_header "per-issue admission lock (#1688/#1764)"
setup_test_env "zb-issue-lock"
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state"

_mk_state() {
    # $1 = path, $2 = status, $3 = age in seconds
    local f="$1" status="$2" age="${3:-0}"
    mkdir -p "$(dirname "$f")"
    local ts; ts="$(date -u -r "$(( $(date -u +%s) - age ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@$(( $(date -u +%s) - age ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    printf '{"status":"%s","updated_at":"%s"}\n' "$status" "$ts" > "$f"
}

# The lock is held on a file descriptor, and a descriptor belongs to a process —
# so "a second run" has to be a second PROCESS, not a second function call in
# this one. A same-process call would find the lock it already holds and pass
# for a reason that has nothing to do with exclusion.
_try_acquire_in_subprocess() {
    local key="$1" run_id="$2" state_file="${3:-}"
    bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
        source "'"$REPO_ROOT"'/core/state/issue-lock.sh"
        export ZBUILD_STATE_ROOT="'"$ZBUILD_STATE_ROOT"'"
        if zbuild_issue_lock_acquire "'"$key"'" "'"$run_id"'" "'"$state_file"'"; then
            echo "ACQUIRED"
        else
            echo "REFUSED holder=${_ZBUILD_ISSUE_LOCK_HOLDER:-none}"
        fi
    ' 2>/dev/null
}

# ─── [SPEC-1][change] a second run of the same issue is refused ─────────────
print_test_section "[SPEC-1][change] one run per issue"

_S1="$TEST_TEMP_DIR/run1/pipeline-state.json"
_mk_state "$_S1" "in_progress" 5

# Hold the lock in a background process that stays alive, then try from another.
bash -c '
    source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
    source "'"$REPO_ROOT"'/core/state/issue-lock.sh"
    export ZBUILD_STATE_ROOT="'"$ZBUILD_STATE_ROOT"'"
    zbuild_issue_lock_acquire 4242 run-holder "'"$_S1"'" || exit 1
    printf ready > "'"$TEST_TEMP_DIR"'/holder-ready"
    sleep 20
' >/dev/null 2>&1 &
_holder_pid=$!
_w=0
while [[ ! -f "$TEST_TEMP_DIR/holder-ready" && $_w -lt 100 ]]; do sleep 0.1; _w=$((_w+1)); done

_r="$(_try_acquire_in_subprocess 4242 run-second "$_S1")"
assert_contains "[SPEC-1] a second run of issue 4242 is REFUSED" "$_r" "REFUSED"
assert_contains "[SPEC-1] and the refusal names the holding run" "$_r" "run-holder"

# A DIFFERENT issue is unaffected — this is a keyed mutex, not a capacity cap.
# Without this, a lock that refused everything would pass SPEC-1 too.
_r="$(_try_acquire_in_subprocess 9999 run-other "")"
assert_contains "[SPEC-1] a run of a DIFFERENT issue is admitted" "$_r" "ACQUIRED"

kill "$_holder_pid" 2>/dev/null || true
wait "$_holder_pid" 2>/dev/null || true

# ─── [SPEC-2][change] a dead holder is reaped, not left blocking ────────────
# Reap BEFORE admission. A lock whose holder is gone must not block a live run
# until someone notices — that is the half of legacy shipwright's
# reap_stale_pipeline_locks worth keeping.
print_test_section "[SPEC-2][change] a dead holder's lock is taken, not honoured"

_r="$(_try_acquire_in_subprocess 4242 run-after-death "$_S1")"
assert_contains "[SPEC-2] the dead holder's lock is reaped and taken" "$_r" "ACQUIRED"

# ─── [SPEC-3][guard] a STALE state file does not fake liveness ─────────────
# zbuild_run_is_live requires in_progress AND a fresh timestamp. A run that
# died without ever updating its state would otherwise hold its issue forever.
print_test_section "[SPEC-3][guard] in_progress with an ancient timestamp is not live"

_S_OLD="$TEST_TEMP_DIR/old/pipeline-state.json"
_mk_state "$_S_OLD" "in_progress" 200000   # ~55h, past the 24h gate
_lock="$(zbuild_issue_lock_path 5555)"
mkdir -p "$(dirname "$_lock")"
printf 'run_id=ancient pid=999999 state_file=%s acquired_at=old\n' "$_S_OLD" > "$_lock"
if _zbuild_issue_lock_holder_is_live "$_lock"; then
    assert_fail "[SPEC-3] a 55h-old in_progress run must not read as live" "reported live"
else
    assert_pass "[SPEC-3] a 55h-old in_progress run is not live"
fi

# But a FRESH in_progress run is — the positive control, without which SPEC-3
# passes on a predicate that always says "dead".
printf 'run_id=fresh pid=999999 state_file=%s acquired_at=now\n' "$_S1" > "$_lock"
if _zbuild_issue_lock_holder_is_live "$_lock"; then
    assert_pass "[SPEC-3] positive control: a fresh in_progress run IS live"
else
    assert_fail "[SPEC-3] a fresh in_progress run must read as live" "reported dead"
fi

# A live PID with no state file at all also counts — a run can die before
# writing its first state file, and a run can also be mid-startup.
printf 'run_id=nostate pid=%s state_file=/nonexistent acquired_at=now\n' "$$" > "$_lock"
if _zbuild_issue_lock_holder_is_live "$_lock"; then
    assert_pass "[SPEC-3] a live PID with no state file still counts as live"
else
    assert_fail "[SPEC-3] a live PID must count as live" "reported dead"
fi

# ─── [SPEC-4][guard] the key becomes a filename, so it is sanitised ────────
# ADR-059 §5 will key --goal runs by a hash, but the path must be safe for any
# key a caller passes today.
print_test_section "[SPEC-4][guard] a hostile key cannot traverse"

# The property is NOT "the string contains no dots" — `..` inside a FILENAME is
# inert, because `/` is the only traversal vector and sanitisation removes it.
# A first version of this asserted on the substring and failed against correct
# output. What matters: the parent directory is still the locks root, and no
# path COMPONENT is `..`.
_p="$(zbuild_issue_lock_path '../../etc/passwd')"
assert_eq "[SPEC-4] the lock stays directly under the locks root" \
    "$ZBUILD_STATE_ROOT/locks" "$(dirname "$_p")"
_has_dotdot=0
_ifs_save="$IFS"; IFS='/'
for _seg in $_p; do [[ "$_seg" == ".." ]] && _has_dotdot=1; done
IFS="$_ifs_save"
assert_eq "[SPEC-4] no path component is '..'" "0" "$_has_dotdot"
# And the hostile input really did reach the sanitiser — without this the two
# assertions above would also pass on a function that ignored its argument.
assert_contains "[SPEC-4] the key was sanitised, not dropped" "$_p" "etc_passwd"

# A separator smuggled in another way is equally inert.
_p2="$(zbuild_issue_lock_path 'a/b')"
assert_eq "[SPEC-4] an embedded slash cannot create a subdirectory" \
    "$ZBUILD_STATE_ROOT/locks" "$(dirname "$_p2")"

# ─── [SPEC-5][guard] the operator opt-out works, and is opt-IN ─────────────
print_test_section "[SPEC-5][guard] ZBUILD_NO_ISSUE_LOCK=1 admits anyway"

_S2="$TEST_TEMP_DIR/run2/pipeline-state.json"
_mk_state "$_S2" "in_progress" 5
_lock2="$(zbuild_issue_lock_path 6060)"
mkdir -p "$(dirname "$_lock2")"
printf 'run_id=live pid=%s state_file=%s acquired_at=now\n' "$$" "$_S2" > "$_lock2"

_r="$(ZBUILD_NO_ISSUE_LOCK=1 bash -c '
    source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
    source "'"$REPO_ROOT"'/core/state/issue-lock.sh"
    export ZBUILD_STATE_ROOT="'"$ZBUILD_STATE_ROOT"'"
    zbuild_issue_lock_acquire 6060 override "" && echo ACQUIRED || echo REFUSED
' 2>/dev/null)"
assert_contains "[SPEC-5] the override admits a run that would be refused" "$_r" "ACQUIRED"

# ─── [SPEC-6][guard] an inherited descriptor must not lock an issue forever ──
# THE BUG THIS EXISTS FOR, found by the parity test: a flock belongs to the open
# file DESCRIPTION, which every child inherits. The runner spawns many — stage
# dispatches, watchdog subshells, orchestrator pools — so one lingering child
# keeps the issue locked after the run that took it has exited. `flock -n`
# failing is evidence that SOMETHING holds the descriptor; it is not evidence
# that a RUN is still working.
#
# Without the reap, an orphaned descriptor locks an issue out permanently.
print_test_section "[SPEC-6][guard] a dead run's orphaned descriptor is reaped"

_S_ORPHAN="$TEST_TEMP_DIR/orphan/pipeline-state.json"
_mk_state "$_S_ORPHAN" "complete" 5

# A holder process that takes the lock, spawns a child which INHERITS the
# descriptor, then exits — leaving the child holding it. This is the shape the
# runner produces, reproduced deliberately.
bash -c '
    source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
    source "'"$REPO_ROOT"'/core/state/issue-lock.sh"
    export ZBUILD_STATE_ROOT="'"$ZBUILD_STATE_ROOT"'"
    zbuild_issue_lock_acquire 7777 run-orphan "'"$_S_ORPHAN"'" || exit 1
    # The child inherits FD 201 and outlives its parent.
    ( sleep 20 ) &
    printf ready > "'"$TEST_TEMP_DIR"'/orphan-ready"
    exit 0
' >/dev/null 2>&1
_w=0
while [[ ! -f "$TEST_TEMP_DIR/orphan-ready" && $_w -lt 100 ]]; do sleep 0.1; _w=$((_w+1)); done
sleep 0.3

# The recorded holder is gone (its state file says complete and its PID exited),
# so a new run must take the lock despite the descriptor still being held.
_r="$(_try_acquire_in_subprocess 7777 run-after-orphan "$_S_ORPHAN")"
assert_contains "[SPEC-6] an orphaned descriptor does not block a new run" "$_r" "ACQUIRED"

# And the guard is not simply "always acquire": a LIVE holder still refuses.
# Without this the assertion above passes on a lock that never refuses anything.
_S_LIVE="$TEST_TEMP_DIR/stillrunning/pipeline-state.json"
_mk_state "$_S_LIVE" "in_progress" 5
bash -c '
    source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
    source "'"$REPO_ROOT"'/core/state/issue-lock.sh"
    export ZBUILD_STATE_ROOT="'"$ZBUILD_STATE_ROOT"'"
    zbuild_issue_lock_acquire 7778 run-live "'"$_S_LIVE"'" || exit 1
    printf ready > "'"$TEST_TEMP_DIR"'/live-ready"
    sleep 20
' >/dev/null 2>&1 &
_live_pid=$!
_w=0
while [[ ! -f "$TEST_TEMP_DIR/live-ready" && $_w -lt 100 ]]; do sleep 0.1; _w=$((_w+1)); done

_r="$(_try_acquire_in_subprocess 7778 run-blocked "$_S_LIVE")"
assert_contains "[SPEC-6] control: a LIVE holder still refuses" "$_r" "REFUSED"
kill "$_live_pid" 2>/dev/null || true
wait "$_live_pid" 2>/dev/null || true

cleanup_test_env
print_test_results
exit $((FAIL > 0))
