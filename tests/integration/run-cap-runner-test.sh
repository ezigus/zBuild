#!/usr/bin/env bash
# Tests: the host-wide run cap through the real runner (issue #1932, ADR-059 §7).
#
# run-cap-test.sh calls the module directly. This file starts the real
# core/pipeline/runner.sh, so it fails when the runner stops calling the cap, and
# it checks the runner's own exit paths free the slot it took.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/state/run-cap.sh
source "$REPO_ROOT/core/state/run-cap.sh"

print_test_header "run cap through the runner (#1932)"
setup_test_env "run-cap-runner"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/root"
SLOT_DIR="$(zbuild_run_cap_slot_dir)"
mkdir -p "$ZBUILD_STATE_ROOT"

OVERLAY_REPO="$(setup_git_temp_repo cap-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" runner-state-dir-minimal
mock_plugin_factory "intake" "agent" 0 "" "" >/dev/null
mock_plugin_factory "build" "agent" 0 "" "" >/dev/null

# A blocker is a live process holding a slot, written with the module's own
# writer; its state file is made with the engine's writers (#1799).
_HOLDER_PIDS=()
_hold_slot() {
    local _run_id="$1" _sf="$TEST_TEMP_DIR/holders/$1/pipeline-state.json"
    init_state "$_sf" "$_run_id" 0 >/dev/null 2>&1
    _set_pipeline_status "$_sf" "in_progress"
    bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
        source "'"$REPO_ROOT"'/core/state/run-cap.sh"
        zbuild_run_cap_write_slot "$1" "$2"
        exec sleep 120
    ' _ "$_run_id" "$_sf" >/dev/null 2>&1 &
    local _pid=$!
    _HOLDER_PIDS+=("$_pid")
    local _w=0
    while [[ ! -f "$SLOT_DIR/$_pid.json" && $_w -lt 100 ]]; do sleep 0.1; _w=$((_w + 1)); done
}

_kill_holders() {
    local _p
    for _p in "${_HOLDER_PIDS[@]:-}"; do
        [[ -n "$_p" ]] || continue
        kill "$_p" 2>/dev/null || true
        wait "$_p" 2>/dev/null || true
    done
    _HOLDER_PIDS=()
    # Each case starts with no slots; a killed holder's slot is not this test's subject.
    find "${SLOT_DIR:?}" -maxdepth 1 -name '*.json' -type f -delete 2>/dev/null || true
}

_slot_count() {
    local n=0 _f
    while IFS= read -r _f; do n=$((n + 1)); done \
        < <(find "$SLOT_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
    printf '%d' "$n"
}

# _run_runner <case> <issue> <cap>: start the real runner; leaves rc, stderr and
# that case's events in $TEST_TEMP_DIR/<case>.{rc,err,events}.
_run_runner() {
    local _case="$1" _issue="$2" _cap="$3" _repo_root="${4:-}"
    local _ev="$TEST_TEMP_DIR/$_case-events"
    mkdir -p "$_ev"
    ( cd "$OVERLAY_REPO" && env -u ZBUILD_STATE_DIR \
        ZBUILD_STATE_ROOT="$ZBUILD_STATE_ROOT" \
        ${_repo_root:+ZBUILD_REPO_ROOT="$_repo_root"} \
        ZBUILD_MAX_CONCURRENT_RUNS="$_cap" \
        ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
        ZBUILD_EVENTS_DIR="$_ev" \
        ZBUILD_EVENTS_JSONL="$_ev/events.jsonl" \
        ZBUILD_EVENTS_DB="$_ev/events.db" \
        ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
        ZBUILD_CYCLES_ENABLED=0 \
        ZBUILD_RUN_ID="run-$_case-$$" \
        HOME="$TEST_TEMP_DIR/home" \
        bash "$RUNNER" --issue "$_issue" --template runner-state-dir-minimal ) \
        >/dev/null 2>"$TEST_TEMP_DIR/$_case.err"
    printf '%d' "$?" > "$TEST_TEMP_DIR/$_case.rc"
    cat "$_ev/events.jsonl" "$ZBUILD_STATE_ROOT"/runs/*/events.jsonl \
        "$ZBUILD_STATE_ROOT"/issues/*/runs/*/events.jsonl 2>/dev/null \
        | grep "run-$_case-$$" > "$TEST_TEMP_DIR/$_case.events" || true
}
mkdir -p "$TEST_TEMP_DIR/home/.zbuild"

# ─── [#1932/R-6] cap + 1 starts: the extra run is refused before any stage ────
print_test_section "[#1932/R-6] a run past the cap is refused by the runner"

_hold_slot "run-blocker-r6"
_run_runner r6 "$(zb_test_issue)" 1
_r6_rc="$(<"$TEST_TEMP_DIR/r6.rc")"
_r6_err="$(<"$TEST_TEMP_DIR/r6.err")"
_r6_ev="$(<"$TEST_TEMP_DIR/r6.events")"

if [[ "$_r6_rc" != "0" ]]; then
    assert_pass "[#1932/R-6] runner exits non-zero at the cap"
else
    assert_fail "[#1932/R-6] runner exits non-zero at the cap" "rc=0"
fi
assert_contains "[#1932/R-6] refusal names the blocking run" "$_r6_err" "run-blocker-r6"
assert_contains "[#1932/R-6] pipeline.refused.run_cap emitted" "$_r6_ev" "pipeline.refused.run_cap"
if grep -q '"plugin.run.start"\|"stage.start"' <<< "$_r6_ev"; then
    assert_fail "[#1932/R-6] no stage ran" "a stage started in the refused run"
else
    assert_pass "[#1932/R-6] no stage ran"
fi
assert_eq "[#1932/R-6] only the blocker's slot remains" "1" "$(_slot_count)"
_kill_holders

# ─── [#1932/R-6b] below the cap the run is admitted and frees its slot ────────
# Control for R-6: a cap that refused everything would pass R-6 too.
print_test_section "[#1932/R-6b] below the cap the run is admitted"

_hold_slot "run-blocker-r6b"
_run_runner r6b "$(zb_test_issue)" 2
_r6b_ev="$(<"$TEST_TEMP_DIR/r6b.events")"
if grep -q "pipeline.refused.run_cap" <<< "$_r6b_ev"; then
    assert_fail "[#1932/R-6b] not refused below the cap" "pipeline.refused.run_cap emitted"
else
    assert_pass "[#1932/R-6b] not refused below the cap"
fi
assert_contains "[#1932/R-6b] a stage ran" "$_r6b_ev" "intake"
assert_eq "[#1932/R-6b] the run's slot is freed at exit" "1" "$(_slot_count)"
_kill_holders

# ─── [#1932/slot-leak] a run refused by the issue lock frees its cap slot ─────
# The cap slot is taken before the issue lock. The lock's refusal returns before
# the runner's exit trap is set, so the slot used to stay until it was reaped.
print_test_section "[#1932/slot-leak] issue-lock refusal frees the cap slot"

_leak_issue="$(zb_test_issue)"
_lock_sf="$TEST_TEMP_DIR/lock-holder/pipeline-state.json"
init_state "$_lock_sf" "run-lock-holder" 0 >/dev/null 2>&1
_set_pipeline_status "$_lock_sf" "in_progress"
bash -c '
    source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
    source "'"$REPO_ROOT"'/core/state/issue-lock.sh"
    zbuild_issue_lock_acquire "issue-$1" run-lock-holder "$2" || exit 1
    printf ready > "$3"
    exec sleep 120
' _ "$_leak_issue" "$_lock_sf" "$TEST_TEMP_DIR/lock-ready" >/dev/null 2>&1 &
_HOLDER_PIDS+=("$!")
_w=0
while [[ ! -f "$TEST_TEMP_DIR/lock-ready" && $_w -lt 100 ]]; do sleep 0.1; _w=$((_w + 1)); done

_run_runner leak "$_leak_issue" 5
_leak_ev="$(<"$TEST_TEMP_DIR/leak.events")"
assert_contains "[#1932/slot-leak] the run was refused by the issue lock" \
    "$_leak_ev" "pipeline.refused.issue_locked"
assert_eq "[#1932/slot-leak] no cap slot is left behind" "0" "$(_slot_count)"
_kill_holders

# ─── [#1932/slot-leak-wt] a run that cannot enter its worktree frees its slot ──
print_test_section "[#1932/slot-leak-wt] worktree failure frees the cap slot"

mkdir -p "$TEST_TEMP_DIR/not-a-repo"
_run_runner leakwt "$(zb_test_issue)" 5 "$TEST_TEMP_DIR/not-a-repo"
_leakwt_rc="$(<"$TEST_TEMP_DIR/leakwt.rc")"
if [[ "$_leakwt_rc" != "0" ]]; then
    assert_pass "[#1932/slot-leak-wt] the run failed to enter its worktree"
else
    assert_fail "[#1932/slot-leak-wt] the run failed to enter its worktree" "rc=0"
fi
assert_contains "[#1932/slot-leak-wt] it failed entering the worktree" \
    "$(<"$TEST_TEMP_DIR/leakwt.err")" "worktree"
assert_eq "[#1932/slot-leak-wt] no cap slot is left behind" "0" "$(_slot_count)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
