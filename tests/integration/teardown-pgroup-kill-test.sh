#!/usr/bin/env bash
# Tests: teardown(release) actually FREES the groups it reads (#2018).
#
# ADR-062 §2 is the path that runs on every normal exit, and it had no
# behavioural coverage at all — no test asserted that teardown killed anything,
# only that it ran. That gap is not theoretical: adding a start-time field to the
# dispatch record made `cat` + `[[ =~ ^[0-9]+$ ]]` reject every record, and the
# guard's failure branch is `continue`, so teardown killed NOTHING and returned
# success. The whole suite stayed green.
#
# So this asserts the outcome — the process is gone — not that a function ran.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "teardown(release) frees recorded process groups (#2018)"
setup_test_env "teardown-pgroup-kill"

_spawn_group() {
    local _out="$1"
    ( set -m; sleep 300 & echo "$!" > "$_out"; wait ) >/dev/null 2>&1 &
    local _i=0
    while [[ ! -s "$_out" && $_i -lt 50 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
    cat "$_out" 2>/dev/null
}

_run_teardown_release() {
    local _sd="$1"
    ( export ZBUILD_TEARDOWN_SCOPE=release ZBUILD_STATE_DIR="$_sd"
      source "$REPO_ROOT/scripts/lib/proc-group.sh"
      emit_event() { :; }
      source "$REPO_ROOT/plugins/tool/teardown/plugin.sh"
      teardown_run "teardown" "$_sd/pipeline-state.json"
    ) >/dev/null 2>&1 || true
}

_wait_gone() {
    local _p="$1" _i=0
    while kill -0 "$_p" 2>/dev/null && [[ $_i -lt 40 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
    kill -0 "$_p" 2>/dev/null && return 1 || return 0
}

# ── SPEC-1: a TSV dispatch record (the #2018 format) is honoured ────────────
SD1="$TEST_TEMP_DIR/run1"
mkdir -p "$SD1/runtime/stages"
echo '{"stage_statuses":{}}' > "$SD1/pipeline-state.json"
P1="$(_spawn_group "$TEST_TEMP_DIR/p1")"
G1="$(ps -o pgid= -p "$P1" 2>/dev/null | tr -d ' ')"
printf '%s\t%s\n' "$G1" "$(ps -o lstart= -p "$G1" 2>/dev/null | tr -s ' ')" \
    > "$SD1/runtime/stages/build.pgid"
_run_teardown_release "$SD1"
if _wait_gone "$P1"; then
    assert_pass "SPEC-1: teardown frees a group recorded in the TSV format"
else
    assert_fail "SPEC-1: teardown frees a group recorded in the TSV format" \
        "pid $P1 (pgid $G1) survived release — the record was read but nothing was killed"
    kill -9 -- "-$G1" 2>/dev/null || true
fi

# ── SPEC-2: a legacy BARE record is still honoured ──────────────────────────
# Records written before #2018 are on disk in running installs. Reading the new
# format must not stop reading the old one.
SD2="$TEST_TEMP_DIR/run2"
mkdir -p "$SD2/runtime/stages"
echo '{"stage_statuses":{}}' > "$SD2/pipeline-state.json"
P2="$(_spawn_group "$TEST_TEMP_DIR/p2")"
G2="$(ps -o pgid= -p "$P2" 2>/dev/null | tr -d ' ')"
printf '%s\n' "$G2" > "$SD2/runtime/stages/build.pgid"
_run_teardown_release "$SD2"
if _wait_gone "$P2"; then
    assert_pass "SPEC-2: teardown still frees a pre-#2018 bare record"
else
    assert_fail "SPEC-2: teardown still frees a pre-#2018 bare record" \
        "pid $P2 (pgid $G2) survived release"
    kill -9 -- "-$G2" 2>/dev/null || true
fi

# ── SPEC-3: a stage that never RETURNED is still freed ──────────────────────
# The original defect (#1748/#2001): cleanup ran from stage_statuses, which is
# written only when a stage completes, so a stage killed mid-flight was never
# released. The record exists for every stage that STARTED. `build` is absent
# from stage_statuses below and must be freed anyway.
SD3="$TEST_TEMP_DIR/run3"
mkdir -p "$SD3/runtime/stages"
echo '{"stage_statuses":{"intake":"complete"}}' > "$SD3/pipeline-state.json"
P3="$(_spawn_group "$TEST_TEMP_DIR/p3")"
G3="$(ps -o pgid= -p "$P3" 2>/dev/null | tr -d ' ')"
printf '%s\t%s\n' "$G3" "$(ps -o lstart= -p "$G3" 2>/dev/null | tr -s ' ')" \
    > "$SD3/runtime/stages/build.pgid"
_run_teardown_release "$SD3"
if _wait_gone "$P3"; then
    assert_pass "SPEC-3: a stage absent from stage_statuses is still freed"
else
    assert_fail "SPEC-3: a stage absent from stage_statuses is still freed" \
        "pid $P3 (pgid $G3) survived — release is still keyed on completion"
    kill -9 -- "-$G3" 2>/dev/null || true
fi

print_test_results
