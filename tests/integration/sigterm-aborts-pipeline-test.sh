#!/usr/bin/env bash
# Integration test (Wave 15-F / #686): SIGTERM propagation has parity with
# SIGINT. Sending kill -TERM to the runner mid-build:
#   - causes the runner's INT/TERM trap to fire on TERM,
#   - records _RUNNER_ABORT_REASON=sigterm,
#   - exits 143 (128+SIGTERM),
#   - the EXIT trap emits `pipeline.aborted reason=sigterm status=interrupted`,
#   - subsequent stages (test, review, ...) never run.
#
# Unlike SIGINT (which non-interactive bash inherits as SIG_IGN — see #612),
# SIGTERM is NOT inherited as ignored, so we drive a true external signal
# delivery: backgrounded runner + `kill -TERM <runner_pid>`.
#
# Assertions:
#   - Runner exits 143 distinctly (not 0, not 1, not 130).
#   - Wall-clock ≤ 5s (signal handler exits promptly).
#   - `test` stage never runs (sentinel file absent).
#   - pipeline-state.json status=interrupted.
#   - `pipeline.aborted reason=sigterm` event in events.jsonl.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "sigterm-aborts-pipeline — kill -TERM halts pipeline (#686)"
setup_test_env "sigterm-aborts-pipeline"
# Wave 12-E (#664): stub plugins lack honest inputs/outputs blocks; opt out.
export ZBUILD_CONTRACT_VALIDATOR=warn
_test_cleanup_hook() {
    if [[ "${KEEP_TMP:-0}" == "1" ]]; then
        echo "KEEPTEMP=$TEST_TEMP_DIR" >&2
    else
        cleanup_test_env
    fi
}

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# Sentinel files: existence proves the stage actually ran.
BUILD_STARTED="$TEST_TEMP_DIR/build-started"
TEST_RAN="$TEST_TEMP_DIR/test-ran"
export BUILD_STARTED TEST_RAN

# Fast stub for intake + plan (instant 0).
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "plan"   "agent" 0 >/dev/null
# #746: standard template now includes impact between plan and build (plan_impact_cycle).
mock_plugin_factory "impact" "agent" 0 >/dev/null
mock_plugin_factory "design" "agent" 0 "" "designer" >/dev/null
# Build stage will be overridden below to sleep — create the manifest now.
mock_plugin_factory "build"  "agent" 0 >/dev/null
mock_plugin_factory "test"   "tool"  0 >/dev/null
mock_plugin_factory "test_assessment" "agent" 0 >/dev/null
mock_plugin_factory "review" "agent" 0 >/dev/null

# Build plugin: touches BUILD_STARTED, then loops short sleeps. Bash defers
# trap delivery until the foreground child (sleep) returns; a tight 0.1s
# polling loop lets the runner's TERM trap fire within ~100ms of signal
# delivery. (A single `sleep 30` would block the trap for the full 30s.)
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<PLUG
build_run() {
    : > "${BUILD_STARTED}"
    local _i
    for _i in \$(seq 1 300); do
        sleep 0.1
    done
    return 0
}
PLUG

# Test plugin: touches TEST_RAN. If this fires, the abort did NOT halt the
# pipeline — the assertion below catches that.
cat > "$PLUGINS_ROOT/tool/test/plugin.sh" <<PLUG
test_run() {
    : > "${TEST_RAN}"
    return 0
}
PLUG

export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

RC_FILE="$TEST_TEMP_DIR/runner-rc"
ELAPSED_FILE="$TEST_TEMP_DIR/elapsed"

# Start runner in a backgrounded subshell so we can capture its PID and
# deliver SIGTERM externally. `setsid` (when available) ensures a fresh
# process group so kill -TERM <pid> hits a leader cleanly; falls back to
# direct background otherwise.
start_ts=$(date +%s)

# Background the runner in its own process group via `setsid` (Linux) or
# `set -m` job-control (darwin). We need the runner + its plugin children
# to share a pgrp distinct from the harness so we can `kill -TERM -<pgid>`
# and deliver TERM to every descendant — the same way the kernel delivers
# Ctrl-C to a foreground pgrp. Without this, only the runner bash gets
# TERM; the build plugin's synchronous `sleep` blocks the trap from firing
# until it returns.
if command -v setsid >/dev/null 2>&1; then
    setsid bash "$RUNNER" --goal "test-sigterm-halt" \
        >"$TEST_TEMP_DIR/runner.stdout" 2>"$TEST_TEMP_DIR/runner.stderr" &
    RUNNER_PID=$!
    # setsid makes the child a session+pgrp leader → pgid == pid.
    RUNNER_PGID="$RUNNER_PID"
else
    # darwin fallback: enable job control so each backgrounded pipeline gets
    # its own pgrp. (`set -m` in this scope only; the harness wraps reset on
    # cleanup.)
    set -m
    bash "$RUNNER" --goal "test-sigterm-halt" \
        >"$TEST_TEMP_DIR/runner.stdout" 2>"$TEST_TEMP_DIR/runner.stderr" &
    RUNNER_PID=$!
    RUNNER_PGID="$(ps -o pgid= "$RUNNER_PID" 2>/dev/null | tr -d ' ' || echo "$RUNNER_PID")"
    set +m
fi

# Wait up to 10s for the build stage to start (proves the runner is
# established and trap is installed). Without this, racing the SIGTERM
# in before traps are armed could hit the bash default disposition.
for _ in $(seq 1 100); do
    [[ -f "$BUILD_STARTED" ]] && break
    sleep 0.1
done

if [[ ! -f "$BUILD_STARTED" ]]; then
    # Runner failed to reach build — abort the test with diagnostic context.
    kill -KILL "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
    assert_fail "build stage reached before signal" \
        "BUILD_STARTED never touched. Stderr tail: $(tail -c 600 "$TEST_TEMP_DIR/runner.stderr" 2>/dev/null)"
    print_test_results
    exit 1
fi

# Deliver SIGTERM to the runner's process group — mirrors the kernel's
# Ctrl-C-to-foreground-pgrp delivery and ensures the build plugin's child
# `sleep` also receives TERM (otherwise bash defers the runner's trap
# until the foreground subprocess returns). The runner's TERM trap (Wave
# 15-F) arms the sentinel, records reason=sigterm, and exit 143s.
kill -TERM "-$RUNNER_PGID" 2>/dev/null || kill -TERM "$RUNNER_PID" 2>/dev/null || true

# Wait for the runner to actually exit. `wait` returns the child's rc.
# `set +e` so the non-zero rc doesn't abort the harness; `set -u` is fine
# because runner_rc is always assigned.
set +e
wait "$RUNNER_PID"
runner_rc=$?
set -e
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
printf '%s' "$elapsed" > "$ELAPSED_FILE"
printf '%s' "$runner_rc" > "$RC_FILE"

# ─── Assertions ──────────────────────────────────────────────────────────────

assert_pass "runner exited (rc=$runner_rc)"

# (1) Runner must exit 143 (128 + SIGTERM) — the distinctive parity rc.
if [[ "$runner_rc" == "143" ]]; then
    assert_pass "runner exits 143 distinctly on SIGTERM"
else
    assert_fail "runner exits 143 distinctly on SIGTERM" \
        "got rc=$runner_rc. Stderr tail: $(tail -c 600 "$TEST_TEMP_DIR/runner.stderr" 2>/dev/null)"
fi

# (2) Wall-clock budget: the signal handler must exit promptly. We allow
#     a generous 5s ceiling (build sleeps 30s — if elapsed >> 5 the trap
#     isn't firing).
if [[ "$elapsed" -le 7 ]]; then
    assert_pass "pipeline halted in ≤7s (actual=${elapsed}s)"
else
    assert_fail "pipeline halted in ≤7s" \
        "actual=${elapsed}s — SIGTERM trap is not firing promptly"
fi

# (3) `test` stage must NOT have run — abort halts the pipeline.
if [[ -f "$TEST_RAN" ]]; then
    assert_fail "test stage did NOT run after SIGTERM" "TEST_RAN sentinel exists"
else
    assert_pass "test stage did NOT run after SIGTERM (abort halted pipeline)"
fi

# (4) Pipeline state status=interrupted.
state_file="$STATE_DIR/pipeline-state.json"
if [[ -f "$state_file" ]]; then
    status="$(jq -r '.status // "MISSING"' "$state_file" 2>/dev/null || echo MISSING)"
    assert_eq "pipeline-state.json status=interrupted" "interrupted" "$status"
else
    assert_fail "pipeline-state.json exists" "missing: $state_file"
fi

# (5) pipeline.aborted event with reason=sigterm emitted.
if [[ -f "$EVENTS_JSONL" ]]; then
    if grep '"type":"pipeline.aborted"' "$EVENTS_JSONL" | grep -q 'sigterm'; then
        assert_pass "pipeline.aborted event emitted with reason=sigterm"
    else
        assert_fail "pipeline.aborted event emitted with reason=sigterm" \
            "events tail: $(tail -c 800 "$EVENTS_JSONL" 2>/dev/null)"
    fi
else
    assert_fail "events.jsonl exists" "missing: $EVENTS_JSONL"
fi

print_test_results
exit $((FAIL > 0))
