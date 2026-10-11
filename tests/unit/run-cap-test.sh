#!/usr/bin/env bash
# Tests: host-wide concurrent run cap (issue #1932, ADR-059 §7).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/run-cap.sh
source "$REPO_ROOT/core/state/run-cap.sh"

print_test_header "host-wide concurrent run cap (#1932)"
setup_test_env "zb-run-cap"

# ─── helpers ─────────────────────────────────────────────────────────────────

# #1799: state files are made by the engine's own writers, never by hand.
# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"

_mk_live_state() {
    init_state "$1" "run-$RANDOM" 0 >/dev/null 2>&1
    _set_pipeline_status "$1" "in_progress"
}

_mk_dead_state() {
    init_state "$1" "run-$RANDOM" 0 >/dev/null 2>&1
    _set_pipeline_status "$1" "complete"
}

# A run that has started but not yet marked itself in_progress: the runner takes
# its slot before _set_pipeline_status runs, so this is every new run's state.
_mk_starting_state() {
    init_state "$1" "run-$RANDOM" 0 >/dev/null 2>&1
}

# A slot belongs to a process, so a held slot needs a process that stays alive.
# The holder writes its slot with the module's own writer, then execs sleep so
# the slot's pid stays the live one. Killed at the end of the test.
_HOLDER_PIDS=()
_hold_slot() {
    local _run_id="$1" _state_file="${2:-}"
    bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
        source "'"$REPO_ROOT"'/core/state/run-cap.sh"
        zbuild_run_cap_write_slot "$1" "$2"
        exec sleep 120
    ' _ "$_run_id" "$_state_file" >/dev/null 2>&1 &
    local _pid=$!
    _HOLDER_PIDS+=("$_pid")
    local _slot; _slot="$(zbuild_run_cap_slot_dir)/$_pid.json"
    local _w=0
    while [[ ! -f "$_slot" && $_w -lt 100 ]]; do sleep 0.1; _w=$((_w + 1)); done
    [[ -f "$_slot" ]] || assert_fail "holder for $_run_id wrote its slot" "no slot after 10s"
}

# A slot whose process has exited: written the same way, but nothing stays alive.
_dead_slot() {
    local _run_id="$1" _state_file="${2:-}"
    bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
        source "'"$REPO_ROOT"'/core/state/run-cap.sh"
        zbuild_run_cap_write_slot "$1" "$2"
    ' _ "$_run_id" "$_state_file" >/dev/null 2>&1 || true
}

_kill_holders() {
    local _p
    for _p in "${_HOLDER_PIDS[@]:-}"; do
        [[ -n "$_p" ]] || continue
        kill "$_p" 2>/dev/null || true
        wait "$_p" 2>/dev/null || true
    done
    _HOLDER_PIDS=()
}

# ─── [#1932/SPEC-1] no cap: returns 0, no slot written, silent ───────────────
print_test_section "[#1932/SPEC-1] unset ZBUILD_MAX_CONCURRENT_RUNS"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec1-state"
unset ZBUILD_MAX_CONCURRENT_RUNS

_s1_state="$TEST_TEMP_DIR/spec1/run.json"
_mk_live_state "$_s1_state"

_s1_stdout_file="$TEST_TEMP_DIR/spec1-stdout.txt"
_s1_stderr_file="$TEST_TEMP_DIR/spec1-stderr.txt"
_s1_rc=0
zbuild_run_cap_admit "run-s1" "$_s1_state" >"$_s1_stdout_file" 2>"$_s1_stderr_file" || _s1_rc=$?
_s1_stdout="$(<"$_s1_stdout_file")"
_s1_stderr="$(<"$_s1_stderr_file")"

assert_eq "[#1932/SPEC-1] no cap: returns 0" "0" "$_s1_rc"
assert_eq "[#1932/SPEC-1] no cap: no stdout produced" "" "$_s1_stdout"
assert_eq "[#1932/SPEC-1] no cap: no stderr produced" "" "$_s1_stderr"

# No files must have been written under the state root
_s1_file_count=0
if [[ -d "$ZBUILD_STATE_ROOT" ]]; then
    while IFS= read -r _; do
        _s1_file_count=$((_s1_file_count + 1))
    done < <(find "$ZBUILD_STATE_ROOT" -type f 2>/dev/null)
fi
assert_eq "[#1932/SPEC-1] no cap: no slot file written" "0" "$_s1_file_count"

# ─── [#1932/SPEC-6] below cap: returns 0, slot written, silent ───────────────
print_test_section "[#1932/SPEC-6] cap set, fewer live slots than cap"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec6-state"
export ZBUILD_MAX_CONCURRENT_RUNS=2

_s6_state_a="$TEST_TEMP_DIR/spec6-a/run.json"
_s6_state_new="$TEST_TEMP_DIR/spec6-new/run.json"
_mk_live_state "$_s6_state_a"
_mk_live_state "$_s6_state_new"

# One existing live slot (cap=2, so 1 < 2)
_hold_slot "run-s6-a" "$_s6_state_a"

_s6_stdout_file="$TEST_TEMP_DIR/spec6-stdout.txt"
_s6_stderr_file="$TEST_TEMP_DIR/spec6-stderr.txt"
_s6_rc=0
zbuild_run_cap_admit "run-s6-new" "$_s6_state_new" >"$_s6_stdout_file" 2>"$_s6_stderr_file" || _s6_rc=$?
_s6_stdout="$(<"$_s6_stdout_file")"
_s6_stderr="$(<"$_s6_stderr_file")"

assert_eq "[#1932/SPEC-6] below cap: returns 0" "0" "$_s6_rc"
assert_eq "[#1932/SPEC-6] below cap: no stdout produced" "" "$_s6_stdout"
assert_eq "[#1932/SPEC-6] below cap: no stderr produced" "" "$_s6_stderr"

# A slot file must now exist for the admitted run
_s6_slot_found=0
while IFS= read -r _f; do
    if grep -q "run-s6-new" "$_f" 2>/dev/null; then
        _s6_slot_found=1
    fi
done < <(find "$ZBUILD_STATE_ROOT" -type f 2>/dev/null)
assert_eq "[#1932/SPEC-6] below cap: slot file written for admitted run" "1" "$_s6_slot_found"

# ─── [#1932/SPEC-2] at cap: returns 1, blockers named, stderr message ────────
print_test_section "[#1932/SPEC-2] cap set, N live slots present"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec2-state"
export ZBUILD_MAX_CONCURRENT_RUNS=2

_s2_state_a="$TEST_TEMP_DIR/spec2-a/run.json"
_s2_state_b="$TEST_TEMP_DIR/spec2-b/run.json"
_s2_state_new="$TEST_TEMP_DIR/spec2-new/run.json"
_mk_live_state "$_s2_state_a"
_mk_live_state "$_s2_state_b"
_mk_live_state "$_s2_state_new"

# Seed two live slots (cap=2, so count == cap)
_hold_slot "run-s2-a" "$_s2_state_a"
_hold_slot "run-s2-b" "$_s2_state_b"

_ZBUILD_RUN_CAP_BLOCKERS=""
_s2_stderr_file="$TEST_TEMP_DIR/spec2-stderr.txt"
_s2_rc=0
zbuild_run_cap_admit "run-s2-new" "$_s2_state_new" 2>"$_s2_stderr_file" || _s2_rc=$?

assert_eq "[#1932/SPEC-2] at cap: returns 1" "1" "$_s2_rc"
assert_contains "[#1932/SPEC-2] _ZBUILD_RUN_CAP_BLOCKERS names run-s2-a" \
    "$_ZBUILD_RUN_CAP_BLOCKERS" "run-s2-a"
assert_contains "[#1932/SPEC-2] _ZBUILD_RUN_CAP_BLOCKERS names run-s2-b" \
    "$_ZBUILD_RUN_CAP_BLOCKERS" "run-s2-b"

_s2_stderr="$(<"$_s2_stderr_file")"
assert_contains "[#1932/SPEC-2] stderr refusal names run-s2-a" "$_s2_stderr" "run-s2-a"
assert_contains "[#1932/SPEC-2] stderr refusal names run-s2-b" "$_s2_stderr" "run-s2-b"

# ─── [#1932/SPEC-3] stale slot reaped before counting ────────────────────────
print_test_section "[#1932/SPEC-3] stale slot reaped, does not block admission"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec3-state"
export ZBUILD_MAX_CONCURRENT_RUNS=2

_s3_state_live="$TEST_TEMP_DIR/spec3-live/run.json"
_s3_state_dead="$TEST_TEMP_DIR/spec3-dead/run.json"
_s3_state_new="$TEST_TEMP_DIR/spec3-new/run.json"
_mk_live_state "$_s3_state_live"
_mk_dead_state "$_s3_state_dead"
_mk_live_state "$_s3_state_new"

# Seed one live slot + one dead (complete) slot — total 2, but only 1 is live
_hold_slot "run-s3-live" "$_s3_state_live"
_dead_slot "run-s3-dead" "$_s3_state_dead"

# With cap=2 and 2 total slots (1 live, 1 stale), admission must succeed
# because zbuild_run_cap_reap_stale removes the dead slot before counting
_s3_rc=0
zbuild_run_cap_admit "run-s3-new" "$_s3_state_new" 2>/dev/null || _s3_rc=$?
assert_eq "[#1932/SPEC-3] stale slot reaped: admission succeeds" "0" "$_s3_rc"

# The stale slot must have been removed
_s3_dead_found=0
while IFS= read -r _f; do
    if grep -q "run-s3-dead" "$_f" 2>/dev/null; then
        _s3_dead_found=1
    fi
done < <(find "$ZBUILD_STATE_ROOT" -type f 2>/dev/null)
assert_eq "[#1932/SPEC-3] stale slot file removed by reap" "0" "$_s3_dead_found"

# Negative control: two live slots still refuse — reaping alone does not open the gate
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec3b-state"
_s3b_state_a="$TEST_TEMP_DIR/spec3b-a/run.json"
_s3b_state_b="$TEST_TEMP_DIR/spec3b-b/run.json"
_s3b_state_new="$TEST_TEMP_DIR/spec3b-new/run.json"
_mk_live_state "$_s3b_state_a"
_mk_live_state "$_s3b_state_b"
_mk_live_state "$_s3b_state_new"
_hold_slot "run-s3b-a" "$_s3b_state_a"
_hold_slot "run-s3b-b" "$_s3b_state_b"
_s3b_rc=0
zbuild_run_cap_admit "run-s3b-new" "$_s3b_state_new" 2>/dev/null || _s3b_rc=$?
assert_eq "[#1932/SPEC-3] control: two live slots still refuse" "1" "$_s3b_rc"

# ─── [#1932/SPEC-3b] a dead process's slot is reaped though its state says running
# A run killed by the OOM killer — the case the cap exists for — never gets to
# write a final status: its state still says in_progress with a fresh
# updated_at. Liveness read from the state file would keep its slot for 24h.
print_test_section "[#1932/SPEC-3b] dead process, state still in_progress"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec3c-state"
export ZBUILD_MAX_CONCURRENT_RUNS=1
_s3c_state_crashed="$TEST_TEMP_DIR/spec3c-crashed/run.json"
_s3c_state_new="$TEST_TEMP_DIR/spec3c-new/run.json"
_mk_live_state "$_s3c_state_crashed"
_mk_live_state "$_s3c_state_new"
_dead_slot "run-s3c-crashed" "$_s3c_state_crashed"
_s3c_rc=0
zbuild_run_cap_admit "run-s3c-new" "$_s3c_state_new" 2>/dev/null || _s3c_rc=$?
assert_eq "[#1932/SPEC-3b] crashed run's slot does not block: admitted" "0" "$_s3c_rc"
_s3c_found=0
while IFS= read -r _f; do
    grep -q "run-s3c-crashed" "$_f" 2>/dev/null && _s3c_found=1
done < <(find "$ZBUILD_STATE_ROOT" -type f 2>/dev/null)
assert_eq "[#1932/SPEC-3b] crashed run's slot file removed" "0" "$_s3c_found"

# ─── [#1932/SPEC-3c] a live process's slot is kept though its state is not in_progress yet
# The runner takes its slot before it marks itself in_progress, and init_state
# writes no status at all. A starter that reaped on the state file would delete
# that slot, and both runs would go over the cap.
print_test_section "[#1932/SPEC-3c] live process, state not yet in_progress"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec3d-state"
export ZBUILD_MAX_CONCURRENT_RUNS=1
_s3d_state_starting="$TEST_TEMP_DIR/spec3d-starting/run.json"
_s3d_state_new="$TEST_TEMP_DIR/spec3d-new/run.json"
_mk_starting_state "$_s3d_state_starting"
_mk_live_state "$_s3d_state_new"
_hold_slot "run-s3d-starting" "$_s3d_state_starting"
_s3d_rc=0
zbuild_run_cap_admit "run-s3d-new" "$_s3d_state_new" 2>/dev/null || _s3d_rc=$?
assert_eq "[#1932/SPEC-3c] starting run still counts: refused" "1" "$_s3d_rc"
_s3d_found=0
while IFS= read -r _f; do
    grep -q "run-s3d-starting" "$_f" 2>/dev/null && _s3d_found=1
done < <(find "$ZBUILD_STATE_ROOT" -type f 2>/dev/null)
assert_eq "[#1932/SPEC-3c] starting run's slot file kept" "1" "$_s3d_found"

# ─── [#1932/SPEC-3d] a slot's JSON survives any run id ─────────────────────
# A slot that does not parse has no readable pid, so the reap removes it even
# while its process is alive.
print_test_section "[#1932/SPEC-3d] a run id with quotes and backslashes"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec3e-state"
export ZBUILD_MAX_CONCURRENT_RUNS=1
_s3e_id='run-"quoted"\\x'
_hold_slot "$_s3e_id" ""
_s3e_rc=0
_ZBUILD_RUN_CAP_BLOCKERS=""
zbuild_run_cap_admit "run-s3e-new" "" 2>/dev/null || _s3e_rc=$?
assert_eq "[#1932/SPEC-3d] live slot with an odd run id still counts: refused" "1" "$_s3e_rc"
assert_eq "[#1932/SPEC-3d] and the blocker is named exactly" "$_s3e_id" "$_ZBUILD_RUN_CAP_BLOCKERS"

# ─── [#1932/SPEC-4] ZBUILD_NO_RUN_CAP=1: bypass regardless of cap and count ──
print_test_section "[#1932/SPEC-4] ZBUILD_NO_RUN_CAP=1 overrides cap and slot count"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec4-state"
export ZBUILD_MAX_CONCURRENT_RUNS=1

_s4_state_blocker="$TEST_TEMP_DIR/spec4-blocker/run.json"
_s4_state_new="$TEST_TEMP_DIR/spec4-new/run.json"
_mk_live_state "$_s4_state_blocker"
_mk_live_state "$_s4_state_new"

# Seed one live slot (cap=1, so count == cap — would normally refuse)
_hold_slot "run-s4-blocker" "$_s4_state_blocker"

export ZBUILD_NO_RUN_CAP=1
_s4_stderr_file="$TEST_TEMP_DIR/spec4-stderr.txt"
_s4_rc=0
zbuild_run_cap_admit "run-s4-new" "$_s4_state_new" 2>"$_s4_stderr_file" || _s4_rc=$?
unset ZBUILD_NO_RUN_CAP

assert_eq "[#1932/SPEC-4] NO_RUN_CAP=1: returns 0 regardless of cap" "0" "$_s4_rc"
_s4_stderr="$(<"$_s4_stderr_file")"
assert_contains "[#1932/SPEC-4] NO_RUN_CAP=1: warns that the cap was bypassed" \
    "$_s4_stderr" "ZBUILD_NO_RUN_CAP=1"

# ─── [#1932/SPEC-5] unreadable slot dir: warns and fails open ────────────────
print_test_section "[#1932/SPEC-5] unreadable slot dir fails open"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec5-state"
export ZBUILD_MAX_CONCURRENT_RUNS=1

_s5_state="$TEST_TEMP_DIR/spec5-new/run.json"
_mk_live_state "$_s5_state"

# Make the slot root unreadable/untraversable so the function cannot count slots
mkdir -p "$ZBUILD_STATE_ROOT"
chmod 000 "$ZBUILD_STATE_ROOT"

_s5_stderr_file="$TEST_TEMP_DIR/spec5-stderr.txt"
_s5_rc=0
zbuild_run_cap_admit "run-s5" "$_s5_state" 2>"$_s5_stderr_file" || _s5_rc=$?

# Restore before any assertions so cleanup_test_env can remove the tree
chmod 755 "$ZBUILD_STATE_ROOT"

assert_eq "[#1932/SPEC-5] unreadable slot dir: returns 0 (fail-open)" "0" "$_s5_rc"
_s5_stderr="$(<"$_s5_stderr_file")"
assert_contains "[#1932/SPEC-5] unreadable slot dir: warns it is admitting" \
    "$_s5_stderr" "admitting (fail-open)"

# ─── [#1932/SPEC-7] ADR-059 §7 and event-schema.json ────────────────────────
print_test_section "[#1932/SPEC-7] ADR-059 §7 and pipeline.refused.run_cap"

_adr_file="$REPO_ROOT/docs/adr/ADR-059-issue-vs-run-keying.md"
assert_file_exists "[#1932/SPEC-7] ADR-059 file exists" "$_adr_file"

# §7 heading must appear inside the ## Decision section (between ## Decision and the next ##)
_s7_decision_section=""
_s7_decision_section="$(awk '/^## Decision/{in_sec=1; next} /^## /{if(in_sec) exit} in_sec{print}' "$_adr_file")"
if grep -Eq '^### 7\. Host-wide run cap, off unless configured \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$' <<< "$_s7_decision_section"; then
    assert_pass "[#1932/SPEC-7] ADR-059 heading '### 7. Host-wide run cap, off unless configured (<date>)' under Decision"
else
    assert_fail "[#1932/SPEC-7] ADR-059 heading '### 7. Host-wide run cap, off unless configured (<date>)' under Decision" \
        "section heading not found inside ## Decision in ADR-059"
fi

# Enforced-by section must contain a bullet (line starting with -) naming run-cap-test.sh
_s7_enforced_section=""
_s7_enforced_section="$(awk '/^## Enforced by/{in_sec=1; next} /^## /{if(in_sec) exit} in_sec{print}' "$_adr_file")"
_s7_enforced_bullet=""
while IFS= read -r _line; do
    if grep -q "^[-*]" <<< "$_line" && grep -q "run-cap-test\.sh" <<< "$_line"; then
        _s7_enforced_bullet="$_line"
    fi
done <<< "$_s7_enforced_section"
if [[ -n "$_s7_enforced_bullet" ]]; then
    assert_pass "[#1932/SPEC-7] ADR-059 Enforced-by has a bullet naming tests/unit/run-cap-test.sh"
else
    assert_fail "[#1932/SPEC-7] ADR-059 Enforced-by has a bullet naming tests/unit/run-cap-test.sh" \
        "no bullet line containing run-cap-test.sh found in ## Enforced by"
fi

# Enforced-by section must individually name all six spec statements
for _spec_tag in SPEC-1 SPEC-2 SPEC-3 SPEC-4 SPEC-5 SPEC-6; do
    if grep -q "$_spec_tag" <<< "$_s7_enforced_section"; then
        assert_pass "[#1932/SPEC-7] ADR-059 Enforced-by names $_spec_tag"
    else
        assert_fail "[#1932/SPEC-7] ADR-059 Enforced-by names $_spec_tag" \
            "$_spec_tag not found in ## Enforced by section of ADR-059"
    fi
done

_schema_file="$REPO_ROOT/config/event-schema.json"
if grep -q "pipeline.refused.run_cap" "$_schema_file"; then
    assert_pass "[#1932/SPEC-7] event-schema.json contains pipeline.refused.run_cap"
else
    assert_fail "[#1932/SPEC-7] event-schema.json contains pipeline.refused.run_cap" \
        "event type missing from config/event-schema.json"
fi

_kill_holders
cleanup_test_env
print_test_results
exit $((FAIL > 0))
