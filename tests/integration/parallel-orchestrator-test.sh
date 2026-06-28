#!/usr/bin/env bash
# Integration tests: parallel-orchestrator end-to-end (ADR-039, #1131)
#
# Drives parallel_group_run directly with a fixture template + a mock
# parallel_dispatch_stage hook (the sibling of the cycle-orchestrator test's
# cycle_dispatch_stage mock). Verifies the ADR-039 execution contract:
#   - a 3-member group runs CONCURRENTLY (wall-clock ≪ sum of member times)
#   - all members complete; verdicts collected in member-DECLARATION order
#   - each member gets an INDEPENDENT stage-io seq label (no collision)
#   - the PARENT writes all stage statuses serially (members touch no state)
#   - on_member_error: continue → group rc=0; collect → group rc=1 (both run all)
#   - a SIGINT mid-run kills in-flight member children (no orphans)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "parallel-orchestrator — integration (ADR-039, #1131)"
setup_test_env "parallel-orchestrator-int"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/parallel-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

# 3-member parallel group fixture (members are top-level leaf sections, ADR-027).
TPL="$TEST_TEMP_DIR/par-3member.yaml"
cat > "$TPL" <<'EOF'
id: par-3member
flow:
  - gates
gates:
  type: parallel
  flow:
    - design
    - build
    - impact
  max_parallel: 3
  on_member_error: continue
design:
  roles: [builder]
build:
  roles: [builder]
impact:
  roles: [builder]
EOF

_seed_state() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    rm -rf "$ZBUILD_STATE_DIR/parallel-gates"
    jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}, updated_at:"seed"}' > "$STATE_FILE"
}

load_template "$TPL"

# ── T1: all members complete; declaration-order verdicts; per-member seq; parent
#        writes all statuses. Mock records its seq label + verdict per member.
print_test_section "T1: concurrent dispatch — all complete, ordered verdicts, isolated seq"

_seed_state
SEQ_DIR="$TEST_TEMP_DIR/seqs"; rm -rf "$SEQ_DIR"; mkdir -p "$SEQ_DIR"

# Mock hook: records the per-member stage-io seq label + stage identity, returns
# a per-member verdict. build "fails" (rc=1) to exercise ordered fail handling.
parallel_dispatch_stage() {
    local member="$1"
    printf '%s\n' "${ZBUILD_STAGE_IO_SEQ_LABEL:-NONE}" > "$SEQ_DIR/$member.seq"
    printf '%s\n' "${ZBUILD_CURRENT_STAGE:-NONE}"       > "$SEQ_DIR/$member.stage"
    case "$member" in
        build)
            _PARALLEL_DISPATCH_VERDICT="fail"
            _PARALLEL_DISPATCH_STATUS="failed"
            return 1
            ;;
        *)
            _PARALLEL_DISPATCH_VERDICT="pass"
            _PARALLEL_DISPATCH_STATUS="complete"
            return 0
            ;;
    esac
}

# Prefix mimics the runner's exported pipeline cardinal for the group unit.
export ZBUILD_SEQ_PREFIX="3"
set +e
parallel_group_run "gates" "$ZBUILD_STATE_DIR" "$STATE_FILE"
rc=$?
set -e
unset ZBUILD_SEQ_PREFIX

assert_eq "T1: group rc=0 (on_member_error=continue absorbs the build failure)" "0" "$rc"
assert_eq "T1: failure_count=1 (build)" "1" "$_PARALLEL_LAST_FAILURE_COUNT"

# Verdicts blob carries all 3 members.
assert_eq "T1: blob design verdict" "pass" \
    "$(jq -r '.design.verdict' <<<"$_PARALLEL_LAST_VERDICTS_BLOB")"
assert_eq "T1: blob build verdict" "fail" \
    "$(jq -r '.build.verdict' <<<"$_PARALLEL_LAST_VERDICTS_BLOB")"
assert_eq "T1: blob impact status" "complete" \
    "$(jq -r '.impact.status' <<<"$_PARALLEL_LAST_VERDICTS_BLOB")"

# Per-member seq labels are independent + declaration-ordered (<prefix>.<slot>).
assert_eq "T1: design seq label = 3.1" "3.1" "$(cat "$SEQ_DIR/design.seq")"
assert_eq "T1: build seq label = 3.2" "3.2" "$(cat "$SEQ_DIR/build.seq")"
assert_eq "T1: impact seq label = 3.3" "3.3" "$(cat "$SEQ_DIR/impact.seq")"
# No collision: 3 distinct labels.
distinct_seqs="$(cat "$SEQ_DIR"/*.seq | sort -u | wc -l | tr -d ' ')"
assert_eq "T1: 3 distinct seq labels (no collision)" "3" "$distinct_seqs"

# Per-member stage identity set inside the subshell.
assert_eq "T1: design ZBUILD_CURRENT_STAGE" "design" "$(cat "$SEQ_DIR/design.stage")"
assert_eq "T1: impact ZBUILD_CURRENT_STAGE" "impact" "$(cat "$SEQ_DIR/impact.stage")"

# Parent wrote ALL statuses serially to state_file (members never touched it).
assert_eq "T1: state design status=complete" "complete" \
    "$(jq -r '.stage_statuses.design' "$STATE_FILE")"
assert_eq "T1: state build status=failed" "failed" \
    "$(jq -r '.stage_statuses.build' "$STATE_FILE")"
assert_eq "T1: state impact status=complete" "complete" \
    "$(jq -r '.stage_statuses.impact' "$STATE_FILE")"
assert_eq "T1: state build verdict=fail" "fail" \
    "$(jq -r '.stage_verdicts.build' "$STATE_FILE")"

# Caller's stage identity restored (was unset → still unset).
if [[ -z "${ZBUILD_CURRENT_STAGE+x}" ]]; then
    assert_pass "T1: ZBUILD_CURRENT_STAGE restored (unset) after the group"
else
    assert_fail "T1: ZBUILD_CURRENT_STAGE restored after the group" \
        "leaked value: ${ZBUILD_CURRENT_STAGE}"
fi

# Events: group + member lifecycle.
assert_event_emitted "T1: parallel.group.start emitted" \
    "$ZBUILD_EVENTS_JSONL" "parallel.group.start"
assert_event_emitted "T1: parallel.group.complete emitted" \
    "$ZBUILD_EVENTS_JSONL" "parallel.group.complete"
assert_event_emitted "T1: parallel.member.dispatch.start emitted" \
    "$ZBUILD_EVENTS_JSONL" "parallel.member.dispatch.start"
assert_event_emitted "T1: parallel.member.dispatch.complete emitted" \
    "$ZBUILD_EVENTS_JSONL" "parallel.member.dispatch.complete"
# 3 members → 3 start + 3 complete events.
start_n="$(grep -c '"parallel.member.dispatch.start"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "T1: 3 member dispatch.start events" "3" "$start_n"

# ── T2: concurrency — 3 members each sleep 1s run in <3s (serial sum = 3s). The
#       1s margin keeps the integer-second timer robust on a loaded CI host.
print_test_section "T2: members run concurrently (wall-clock < serial sum)"

_seed_state
parallel_dispatch_stage() {
    sleep 1
    _PARALLEL_DISPATCH_VERDICT="pass"; _PARALLEL_DISPATCH_STATUS="complete"
    return 0
}

t_start="$(date +%s)"
set +e
parallel_group_run "gates" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null
rc=$?
set -e
t_end="$(date +%s)"
elapsed=$(( t_end - t_start ))

assert_eq "T2: group rc=0 (all pass)" "0" "$rc"
if [[ "$elapsed" -lt 3 ]]; then
    assert_pass "T2: 3×1s members complete in <3s (elapsed: ${elapsed}s) → concurrent"
else
    assert_fail "T2: 3×1s members complete in <3s" "elapsed: ${elapsed}s (serial would be ~3s+)"
fi

# ── T3: on_member_error=collect → a member failure fails the group (rc=1). ────
print_test_section "T3: on_member_error=collect propagates a member failure (rc=1)"

COLLECT_TPL="$TEST_TEMP_DIR/par-collect.yaml"
cat > "$COLLECT_TPL" <<'EOF'
id: par-collect
flow:
  - gates
gates:
  type: parallel
  flow:
    - design
    - build
    - impact
  max_parallel: 2
  on_member_error: collect
design:
  roles: [builder]
build:
  roles: [builder]
impact:
  roles: [builder]
EOF
load_template "$COLLECT_TPL"
_seed_state

RAN_DIR="$TEST_TEMP_DIR/ran"; rm -rf "$RAN_DIR"; mkdir -p "$RAN_DIR"
parallel_dispatch_stage() {
    local member="$1"
    : > "$RAN_DIR/$member"   # proof this member ran (no short-circuit)
    if [[ "$member" == "design" ]]; then
        _PARALLEL_DISPATCH_VERDICT="fail"; _PARALLEL_DISPATCH_STATUS="failed"
        return 1
    fi
    _PARALLEL_DISPATCH_VERDICT="pass"; _PARALLEL_DISPATCH_STATUS="complete"
    return 0
}

set +e
parallel_group_run "gates" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null
rc=$?
set -e
assert_eq "T3: group rc=1 (collect propagates the design failure)" "1" "$rc"
# All members ran despite design failing first (max_parallel=2 forces a pool shift).
assert_eq "T3: design ran" "1" "$([[ -f "$RAN_DIR/design" ]] && echo 1 || echo 0)"
assert_eq "T3: build ran" "1" "$([[ -f "$RAN_DIR/build" ]] && echo 1 || echo 0)"
assert_eq "T3: impact ran (no short-circuit on sibling failure)" "1" \
    "$([[ -f "$RAN_DIR/impact" ]] && echo 1 || echo 0)"

# Re-load the 3-member continue fixture for any later cases.
load_template "$TPL"

# ── T4: SIGINT mid-run kills in-flight member children (no orphans). ─────────
print_test_section "T4: SIGINT mid-run kills in-flight members (no orphans)"

_seed_state
PID_DIR="$TEST_TEMP_DIR/pids"; rm -rf "$PID_DIR"; mkdir -p "$PID_DIR"

# Long-running mock: record the member subshell pid, then busy-wait. The
# transient `sleep` child self-reaps; killing the tracked subshell pid (+ its
# children via pkill -P) terminates the work — proving no orphan survives.
parallel_dispatch_stage() {
    local member="$1"
    printf '%s' "$BASHPID" > "$PID_DIR/$member.pid"
    local i
    for (( i=0; i<300; i++ )); do sleep 0.1; done
    _PARALLEL_DISPATCH_VERDICT="pass"; _PARALLEL_DISPATCH_STATUS="complete"
    return 0
}

# Run the group in a backgrounded subshell so the test can signal it mid-flight.
( parallel_group_run "gates" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1 ) &
pg_pid=$!

# Wait (bounded) for all 3 members to register their pids.
_count_pid_files() {
    local n=0 f
    for f in "$PID_DIR"/*.pid; do [[ -f "$f" ]] && n=$(( n + 1 )); done
    printf '%s' "$n"
}
waited=0
while [[ "$(_count_pid_files)" -lt 3 && $waited -lt 50 ]]; do
    sleep 0.1
    waited=$(( waited + 1 ))
done
member_pids=()
for f in "$PID_DIR"/*.pid; do
    [[ -f "$f" ]] && member_pids+=("$(cat "$f")")
done
assert_eq "T4: all 3 members launched before signal" "3" "${#member_pids[@]}"

# Signal the group → its INT trap kills in-flight children + returns 130.
kill -INT "$pg_pid" 2>/dev/null || true
wait "$pg_pid" 2>/dev/null || true

# Give the OS a moment to reap, then verify every member process is dead.
sleep 0.5
orphans=0
for _pid in "${member_pids[@]}"; do
    if kill -0 "$_pid" 2>/dev/null; then
        orphans=$(( orphans + 1 ))
        kill -KILL "$_pid" 2>/dev/null || true
    fi
done
assert_eq "T4: no orphaned member processes after SIGINT" "0" "$orphans"
assert_event_emitted "T4: parallel.group.complete (status=aborted) emitted" \
    "$ZBUILD_EVENTS_JSONL" "parallel.group.complete"

cleanup_test_env
print_test_results
