#!/usr/bin/env bash
# Integration: run-level wall-clock limit with watchdog (#1944)
#
# SPEC-1 [code]: a run whose wall-clock time exceeds max_run_s ends with
#   pipeline status timed_out in pipeline-state.json and pipeline.end event
#   carrying status=timed_out, the in-flight stage, and limit_s; the watchdog
#   fires even when the engine is idle between dispatches (not only inside a
#   stage); a process that ignores TERM is dead within TERM + 10 s; release and
#   persist execute on every timed-out exit path.
#
# Phases:
#   P1 — basic timeout: slow stage hits the watchdog; status=timed_out, event
#        fields correct; runner exits non-zero within the limit
#   P2 — one timer for the whole run: fast-one completes, fast-two is
#        in-flight when the watchdog fires; both stages saw the same watchdog
#        (the same process), so it is the run's timer from its start, not one
#        reset per stage. No elapsed time is read (#2510)
#   P3 — TERM-ignore: a stage that traps and ignores SIGTERM is dead within
#        TERM + 10 s (KILL escalation)
#   P4 — release and persist run: always_run release + persist stages execute
#        on every timed-out exit path
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "run-timed-out: wall-clock limit watchdog fires and ends run correctly (#1944)"
setup_test_env "run-timed-out"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_DIR="$TEST_TEMP_DIR/events"
EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0
export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$STATE_DIR" "$EVENTS_DIR" "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

# ── Shared overlay repo ─────────────────────────────────────────────────────
OVERLAY_REPO="$(setup_git_temp_repo run-timed-out-overlay)"
mkdir -p "$OVERLAY_REPO/.zbuild/templates"

# Single-stage template: one slow stage (the main timeout victim)
cat > "$OVERLAY_REPO/.zbuild/templates/timeout-single.yaml" <<'EOF'
id: timeout-single
extends: simple
stages:
  - id: slow-stage
    gate: auto
    io:
      destinations: [file]
      tail_lines: 50
    router:
      timeout_s: 120
      max_turns: 0
EOF

# Two-stage template: fast-one is instant; fast-two blocks for a long time
cat > "$OVERLAY_REPO/.zbuild/templates/timeout-two-stage.yaml" <<'EOF'
id: timeout-two-stage
extends: simple
stages:
  - id: fast-one
    gate: auto
    io:
      destinations: [file]
      tail_lines: 50
  - id: fast-two
    gate: auto
    io:
      destinations: [file]
      tail_lines: 50
EOF

# Always-run (release + persist) template: flow stage + always_run release + persist
cat > "$OVERLAY_REPO/.zbuild/templates/timeout-with-release.yaml" <<'EOF'
id: timeout-with-release
extends: simple
flow:
  - outcome

always_run:
  - release
  - persist-stage

outcome:
  gate: auto
  io:
    destinations: [file]
    tail_lines: 50

release:
  gate: auto
  roles: [teardown]
  router:
    timeout_s: 30
  io:
    destinations: [file]
    tail_lines: 50

persist-stage:
  gate: auto
  roles: [persist]
  router:
    timeout_s: 30
  io:
    destinations: [file]
    tail_lines: 50
EOF

# Commit the templates into the overlay repo so the runner can find them
(cd "$OVERLAY_REPO" && git add .zbuild && git commit -q -m "add timeout test templates") >/dev/null 2>&1

# ── P1: basic timeout — slow stage, status=timed_out ───────────────────────

# Stage that sleeps far longer than max_run_s
mock_plugin_factory "slow-stage" "agent" 0 >/dev/null
SLOW_STAGE_STARTED="$TEST_TEMP_DIR/slow-stage-started"
cat > "$PLUGINS_ROOT/agent/slow-stage/plugin.sh" <<PLUG
slow_stage_run() {
    : > "${SLOW_STAGE_STARTED}"
    sleep 120
    $(mock_result_line slow-stage)
    return 0
}
PLUG

export ZBUILD_STATE_DIR="$STATE_DIR"
print_test_section "P1: slow stage timeout — status=timed_out written to pipeline-state.json"

# Run with ZBUILD_MAX_RUN_S=2 (2 seconds); wrap in timeout 25s to prevent hanging
# before implementation (no watchdog → stage sleeps forever → outer timeout kills it)
p1_rc=0
( cd "$OVERLAY_REPO" && ZBUILD_MAX_RUN_S=2 timeout 25 bash "$RUNNER" \
    --template timeout-single --goal "run-timed-out test p1" ) \
    >"$TEST_TEMP_DIR/p1.stdout" 2>"$TEST_TEMP_DIR/p1.stderr" \
    || p1_rc=$?

STATE_FILE="$STATE_DIR/pipeline-state.json"

# Runner must exit non-zero (timed-out runs are failures)
assert_eq "[#1944/SPEC-1] P1: runner exits non-zero" "1" "$p1_rc"

# pipeline-state.json must exist and have status=timed_out
if [[ ! -f "$STATE_FILE" ]]; then
    assert_fail "[#1944/SPEC-1] P1: pipeline-state.json written" "state file not found"
else
    _p1_status="$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null || true)"
    assert_eq "[#1944/SPEC-1] P1: pipeline-state.json status=timed_out" "timed_out" "$_p1_status"
fi

# The run's last words say why it ended: the wall-clock limit, not the
# generic "stopped before finishing" (the watchdog fires outside any cycle,
# so no cycle reason is set).
assert_contains "[#1944/SPEC-1] P1: the run's footer names the wall-clock limit" \
    "$(grep '^The run ' "$TEST_TEMP_DIR/p1.stderr" || true)" "exceeded its wall-clock limit"

print_test_section "P1: pipeline.end event fields — status=timed_out, stage, limit_s"

if [[ ! -f "$EVENTS_JSONL" ]]; then
    assert_fail "[#1944/SPEC-1] P1: events.jsonl written" "events file not found"
else
    # Event: pipeline.end with status=timed_out
    _p1_end_event="$(jq -c 'select(.type=="pipeline.end" and .data.status=="timed_out")' \
        "$EVENTS_JSONL" 2>/dev/null | tail -1)"
    if [[ -n "$_p1_end_event" ]]; then
        assert_pass "[#1944/SPEC-1] P1: pipeline.end status=timed_out event emitted"
    else
        assert_fail "[#1944/SPEC-1] P1: pipeline.end status=timed_out event emitted" \
            "no such event in $(wc -l < "$EVENTS_JSONL") events"
    fi

    # The event must carry the in-flight stage name
    _p1_stage="$(jq -r 'select(.type=="pipeline.end" and .data.status=="timed_out") | .data.stage // empty' \
        "$EVENTS_JSONL" 2>/dev/null | tail -1)"
    if [[ -n "$_p1_stage" ]]; then
        assert_pass "[#1944/SPEC-1] P1: pipeline.end event carries in-flight stage (stage=$_p1_stage)"
    else
        assert_fail "[#1944/SPEC-1] P1: pipeline.end event carries in-flight stage" \
            "stage field empty in timed_out pipeline.end event"
    fi

    # The event must carry limit_s (the max_run_s value that was applied)
    _p1_limit="$(jq -r 'select(.type=="pipeline.end" and .data.status=="timed_out") | .data.limit_s // empty' \
        "$EVENTS_JSONL" 2>/dev/null | tail -1)"
    if [[ -n "$_p1_limit" && "$_p1_limit" =~ ^[0-9]+$ ]]; then
        assert_pass "[#1944/SPEC-1] P1: pipeline.end event carries limit_s=$_p1_limit"
    else
        assert_fail "[#1944/SPEC-1] P1: pipeline.end event carries limit_s" \
            "limit_s field absent or non-numeric in timed_out pipeline.end event"
    fi
fi

# ── P2: idle between dispatches — watchdog fires independently of stage state ─
print_test_section "P2: watchdog fires even when engine is idle between dispatches"

# Reset state/events for fresh run
rm -f "$STATE_FILE" "$EVENTS_JSONL"
mock_plugin_factory "fast-one" "agent" 0 >/dev/null
mock_plugin_factory "fast-two" "agent" 0 >/dev/null

# fast-one returns at once; fast-two holds until it is stopped. Each records the
# watchdog it runs under: among the runner's own children (\$\$ in a stage is
# the runner's pid), the one sleeping the run's limit — never a search of the
# machine. One timer for the run: both
# see the same process. A timer reset per stage would be a new one for fast-two.
# The limit (20s) leaves a slow machine's start-up and fast-one far inside it.
_P2_WD="$TEST_TEMP_DIR/p2-watchdog"
cat > "$TEST_TEMP_DIR/p2-helper.sh" <<'HELP'
_p2_watchdog() {
    local c w a
    for c in $(pgrep -P "$$" 2>/dev/null); do
        for w in $(pgrep -P "$c" -x sleep 2>/dev/null); do
            a="$(ps -o args= -p "$w" 2>/dev/null)"; a="${a%"${a##*[![:space:]]}"}"
            [[ "$a" == "sleep 20" ]] && printf '%s\n' "$w"
        done
    done
}
HELP
cat > "$PLUGINS_ROOT/agent/fast-one/plugin.sh" <<PLUG
fast_one_run() {
    source "$TEST_TEMP_DIR/p2-helper.sh"
    _p2_watchdog > "${_P2_WD}.one"
    $(mock_result_line fast-one)
    return 0
}
PLUG
cat > "$PLUGINS_ROOT/agent/fast-two/plugin.sh" <<PLUG
fast_two_run() {
    source "$TEST_TEMP_DIR/p2-helper.sh"
    _p2_watchdog > "${_P2_WD}.two"
    sleep 600
    $(mock_result_line fast-two)
    return 0
}
PLUG
rm -f "${_P2_WD}.one" "${_P2_WD}.two"

p2_rc=0
( cd "$OVERLAY_REPO" && ZBUILD_MAX_RUN_S=20 timeout 90 bash "$RUNNER" \
    --template timeout-two-stage --goal "run-timed-out test p2" ) \
    >"$TEST_TEMP_DIR/p2.stdout" 2>"$TEST_TEMP_DIR/p2.stderr" \
    || p2_rc=$?

assert_eq "[#1944/SPEC-1] P2: runner exits non-zero" "1" "$p2_rc"

if [[ -f "$STATE_FILE" ]]; then
    _p2_status="$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null || true)"
    assert_eq "[#1944/SPEC-1] P2: pipeline status=timed_out (watchdog fires regardless of dispatch state)" \
        "timed_out" "$_p2_status"

    # fast-one MUST have completed before the watchdog fired: its status must be
    # "complete". This is the falsifiable check — if the watchdog fired before
    # fast-one completed, fast-one's status would not be "complete" and this fails.
    # Stage names are stored with their literal name (hyphenated) as the key.
    _p2_fast_one="$(jq -r '.stage_statuses["fast-one"] // empty' "$STATE_FILE" 2>/dev/null || true)"
    if [[ "$_p2_fast_one" == "complete" ]]; then
        assert_pass "[#1944/SPEC-1] P2: fast-one completed before watchdog fired (watchdog fires independently)"
    else
        assert_fail "[#1944/SPEC-1] P2: fast-one completed before watchdog fired" \
            "fast-one status: '${_p2_fast_one:-<empty>}' — watchdog fired too early or fast-one did not run"
    fi
else
    assert_fail "[#1944/SPEC-1] P2: pipeline-state.json written" "state file not found"
fi

_p2_one="$(cat "${_P2_WD}.one" 2>/dev/null)"; _p2_two="$(cat "${_P2_WD}.two" 2>/dev/null)"
assert_eq "[#1944/SPEC-1] P2: fast-one ran under the run's watchdog" "1" "$([[ "$_p2_one" =~ ^[0-9]+$ ]] && echo 1 || echo 0)"
assert_eq "[#1944/SPEC-1] P2: fast-two ran under the same watchdog — one timer for the run, not one per stage" \
    "$_p2_one" "$_p2_two"

# ── P3: TERM-ignore → KILL within TERM + 10s ────────────────────────────────
print_test_section "P3: stage that ignores SIGTERM is dead within TERM + 10s"

rm -f "$STATE_FILE" "$EVENTS_JSONL"

# Stage that traps SIGTERM and does NOT exit, sleeps indefinitely
TERM_IGNORED_PID_FILE="$TEST_TEMP_DIR/term-ignore-pid"
cat > "$PLUGINS_ROOT/agent/slow-stage/plugin.sh" <<PLUG
slow_stage_run() {
    : > "${SLOW_STAGE_STARTED}"
    # Record our PID so the test can check it is dead
    printf '%s\n' "\$\$" > "${TERM_IGNORED_PID_FILE}"
    # Trap SIGTERM and ignore it (only SIGKILL can stop this)
    trap '' TERM
    sleep 600
    $(mock_result_line slow-stage)
    return 0
}
PLUG

# max_run_s=2 → the watchdog TERMs at 2s; the stage ignores it; the watchdog
# KILLs it at 2+10s. Without that KILL the stage holds 600s, the outer timeout
# (90s) ends the runner with 124, and the stage outlives it: the rc and the
# stage's pid say which, with no elapsed time read (#2510).
p3_rc=0
( cd "$OVERLAY_REPO" && ZBUILD_MAX_RUN_S=2 timeout 90 bash "$RUNNER" \
    --template timeout-single --goal "run-timed-out test p3 term-ignore" ) \
    >"$TEST_TEMP_DIR/p3.stdout" 2>"$TEST_TEMP_DIR/p3.stderr" \
    || p3_rc=$?

# Runner must exit (not hang past 30s timeout)
assert_eq "[#1944/SPEC-1] P3: runner exits non-zero (not still running)" "1" "$p3_rc"


# If stage PID was written, check the process is dead
if [[ -f "$TERM_IGNORED_PID_FILE" ]]; then
    _ignore_pid="$(cat "$TERM_IGNORED_PID_FILE" 2>/dev/null || true)"
    if [[ "$_ignore_pid" =~ ^[0-9]+$ ]]; then
        if kill -0 "$_ignore_pid" 2>/dev/null; then
            assert_fail "[#1944/SPEC-1] P3: TERM-ignoring stage process is dead after TERM+10s" \
                "PID $_ignore_pid is still alive"
        else
            assert_pass "[#1944/SPEC-1] P3: TERM-ignoring stage process is dead (PID $_ignore_pid killed)"
        fi
    fi
fi

# ── P4: release AND persist stages run on timed-out exit path ───────────────
print_test_section "P4: always_run release and persist stages execute on timed-out exit path"

rm -f "$STATE_FILE" "$EVENTS_JSONL"

mock_plugin_factory "outcome"       "agent" 0 "" ""        >/dev/null
mock_plugin_factory "teardown"      "tool"  0 "" "teardown" >/dev/null
mock_plugin_factory "persist-stage" "tool"  0 "" "persist"  >/dev/null

# Outcome (flow) stage: sleeps 30s (will be killed by watchdog)
OUTCOME_STARTED="$TEST_TEMP_DIR/outcome-started"
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() {
    : > "${OUTCOME_STARTED}"
    sleep 30
    $(mock_result_line outcome)
    return 0
}
PLUG

# Release (teardown) stage: drops a marker to prove it ran
RELEASE_MARKER="$TEST_TEMP_DIR/release-ran-on-timeout"
cat > "$PLUGINS_ROOT/tool/teardown/plugin.sh" <<PLUG
teardown_run() {
    : > "${RELEASE_MARKER}"
    $(mock_result_line teardown)
    return 0
}
PLUG

# Persist stage: drops a marker to prove it ran
PERSIST_MARKER="$TEST_TEMP_DIR/persist-ran-on-timeout"
cat > "$PLUGINS_ROOT/tool/persist-stage/plugin.sh" <<PLUG
persist_stage_run() {
    : > "${PERSIST_MARKER}"
    $(mock_result_line persist-stage)
    return 0
}
PLUG

p4_rc=0
( cd "$OVERLAY_REPO" && ZBUILD_MAX_RUN_S=2 timeout 25 bash "$RUNNER" \
    --template timeout-with-release --goal "run-timed-out test p4 release+persist" ) \
    >"$TEST_TEMP_DIR/p4.stdout" 2>"$TEST_TEMP_DIR/p4.stderr" \
    || p4_rc=$?

assert_eq "[#1944/SPEC-1] P4: runner exits non-zero on timed-out path" "1" "$p4_rc"

if [[ -f "$STATE_FILE" ]]; then
    _p4_status="$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null || true)"
    assert_eq "[#1944/SPEC-1] P4: pipeline status=timed_out" "timed_out" "$_p4_status"
else
    assert_fail "[#1944/SPEC-1] P4: pipeline-state.json written" "state file not found"
fi

if [[ -e "$RELEASE_MARKER" ]]; then
    assert_pass "[#1944/SPEC-1] P4: release (always_run) stage ran on timed-out exit path"
else
    assert_fail "[#1944/SPEC-1] P4: release (always_run) stage ran on timed-out exit path" \
        "release marker not found — always_run release stage did not execute"
fi

if [[ -e "$PERSIST_MARKER" ]]; then
    assert_pass "[#1944/SPEC-1] P4: persist (always_run) stage ran on timed-out exit path"
else
    assert_fail "[#1944/SPEC-1] P4: persist (always_run) stage ran on timed-out exit path" \
        "persist marker not found — always_run persist stage did not execute"
fi

print_test_results
exit $((FAIL > 0))
