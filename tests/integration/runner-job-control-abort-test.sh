#!/usr/bin/env bash
# Integration test (Wave 15-H / #688): flag-gated process-group signal
# forwarding via bash job control in the runner.
#
# When ZBUILD_RUNNER_JOB_CONTROL=1:
#   - the runner enables `set -m` at startup;
#   - the SIGINT/TERM trap walks `jobs -p` and TERM-then-KILL's each
#     child PGID, reaping whole subtrees.
#
# Discriminating assertions:
#   (T1) With flag on, the runner shell has `monitor` (-m) option set —
#        verified by injecting a probe plugin that records `$-` and
#        `set -o monitor` output. Flag-off: no `-m`.
#   (T2) With flag on, SIGTERM mid-build still produces rc=143 + the
#        Wave 15-B sentinel/event chain (regression of trap composition).
#
# Wave 15-H lays the foundation for future backgrounded stages (e.g.
# parallel strategy fanout); the trap's PG-kill loop is exercised here
# transitively by T2's end-to-end SIGTERM. The current dispatch path
# runs plugins in foreground subshells (no `&`), so a flag-on test that
# requires a backgrounded runner-child would not reflect realistic usage
# and is intentionally omitted.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner job-control PG forwarding (Wave 15-H / #688)"
setup_test_env "runner-job-control-abort"

_test_cleanup_hook() {
    if [[ "${KEEP_TMP:-0}" == "1" ]]; then
        echo "KEEPTEMP=$TEST_TEMP_DIR" >&2
    else
        cleanup_test_env
    fi
}

export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

# ─── T1: flag toggles `-m` (monitor mode) on the runner shell ────────────────
print_test_section "T1: ZBUILD_RUNNER_JOB_CONTROL=1 enables set -m in runner"

PROBE_STATE_DIR="$TEST_TEMP_DIR/state-probe"
PROBE_PLUGINS="$TEST_TEMP_DIR/plugins"   # mock_plugin_factory uses TEST_TEMP_DIR/plugins
PROBE_EVENTS="$TEST_TEMP_DIR/events-probe/events.jsonl"
mkdir -p "$PROBE_STATE_DIR" "$TEST_TEMP_DIR/events-probe"
PROBE_OPTS_FILE="$TEST_TEMP_DIR/intake-shell-opts"

export ZBUILD_PLUGINS_ROOT="$PROBE_PLUGINS"
export ZBUILD_STATE_DIR="$PROBE_STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events-probe"
export ZBUILD_EVENTS_JSONL="$PROBE_EVENTS"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0

mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "plan"   "agent" 0 >/dev/null
mock_plugin_factory "impact" "agent" 0 >/dev/null
mock_plugin_factory "design" "agent" 0 "" "designer" >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
mock_plugin_factory "test"   "tool"  0 >/dev/null
mock_plugin_factory "test_assessment" "agent" 0 >/dev/null
mock_plugin_factory "review" "agent" 0 >/dev/null

# Probe intake records $- (set of shell option flags) to a marker so we
# can introspect whether the runner shell has 'm' (monitor mode) set.
cat > "$PROBE_PLUGINS/agent/intake/plugin.sh" <<PROBE
intake_run() {
    echo "dash=\$-" > "${PROBE_OPTS_FILE}"
    set -o | grep -E '^monitor' >> "${PROBE_OPTS_FILE}" 2>/dev/null || true
    return 0
}
PROBE

# Run with flag OFF.
: > "$PROBE_OPTS_FILE"
unset ZBUILD_RUNNER_JOB_CONTROL
rm -f "$PROBE_STATE_DIR/pipeline-state.json"
set +e
bash "$RUNNER" --goal "w15h probe flag-off" \
    >"$TEST_TEMP_DIR/runner-off.stdout" 2>"$TEST_TEMP_DIR/runner-off.stderr"
rc_off=$?
set -e
opts_off="$(cat "$PROBE_OPTS_FILE" 2>/dev/null || echo "")"

# Run with flag ON.
: > "$PROBE_OPTS_FILE"
export ZBUILD_RUNNER_JOB_CONTROL=1
rm -f "$PROBE_STATE_DIR/pipeline-state.json"
set +e
bash "$RUNNER" --goal "w15h probe flag-on" \
    >"$TEST_TEMP_DIR/runner-on.stdout" 2>"$TEST_TEMP_DIR/runner-on.stderr"
rc_on=$?
set -e
opts_on="$(cat "$PROBE_OPTS_FILE" 2>/dev/null || echo "")"

# Both runs must exit 0.
assert_eq "flag-off probe run rc=0" "0" "$rc_off"
assert_eq "flag-on  probe run rc=0" "0" "$rc_on"

# Flag-off: $- must NOT contain 'm'; set -o monitor must be off.
if echo "$opts_off" | grep -qE 'dash=[^m]*$|dash=[^m]*[^m]*$' && \
   echo "$opts_off" | grep -qE '^monitor[[:space:]]+off$'; then
    assert_pass "flag-off: monitor mode OFF in runner shell"
else
    # Looser check: dash line should not have 'm'.
    if echo "$opts_off" | head -1 | grep -qv 'm'; then
        assert_pass "flag-off: monitor mode OFF in runner shell (dash check)"
    else
        assert_fail "flag-off: monitor mode OFF in runner shell" \
            "got: $opts_off"
    fi
fi

# Flag-on: $- must contain 'm' OR set -o monitor must be on.
if echo "$opts_on" | head -1 | grep -q 'm' || \
   echo "$opts_on" | grep -qE '^monitor[[:space:]]+on$'; then
    assert_pass "flag-on: monitor mode ON in runner shell"
else
    assert_fail "flag-on: monitor mode ON in runner shell" \
        "got: $opts_on"
fi

# ─── T2: SIGTERM with flag-on still produces rc=143 + Wave 15-B chain ────────
print_test_section "T2: end-to-end SIGTERM with flag-on (regression of trap chain)"

# Reuse $PROBE_PLUGINS (= TEST_TEMP_DIR/plugins). Override build/test/intake.
E2E_STATE_DIR="$TEST_TEMP_DIR/state-e2e"
E2E_EVENTS_JSONL="$TEST_TEMP_DIR/events-e2e/events.jsonl"
export ZBUILD_STATE_DIR="$E2E_STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events-e2e"
export ZBUILD_EVENTS_JSONL="$E2E_EVENTS_JSONL"
mkdir -p "$E2E_STATE_DIR" "$TEST_TEMP_DIR/events-e2e"
export ZBUILD_RUNNER_JOB_CONTROL=1

E2E_BUILD_STARTED="$TEST_TEMP_DIR/e2e-build-started"
E2E_TEST_RAN="$TEST_TEMP_DIR/e2e-test-ran"
export E2E_BUILD_STARTED E2E_TEST_RAN

# Restore intake to a no-op (was overridden by probe).
cat > "$PROBE_PLUGINS/agent/intake/plugin.sh" <<PLUG
intake_run() { return 0; }
PLUG

# Build plugin: short polling loop so the trap can fire within budget.
# Note: under flag-on, `set -m` puts the plugin subshell in its own PGID
# so a kernel-pgrp TERM to the runner does NOT reach the subshell directly.
# The runner's trap therefore fires only after the foreground subshell
# returns naturally — bounded by the loop length here.
cat > "$PROBE_PLUGINS/agent/build/plugin.sh" <<PLUG
build_run() {
    : > "${E2E_BUILD_STARTED}"
    local _i
    for _i in \$(seq 1 20); do
        sleep 0.1
    done
    return 0
}
PLUG
cat > "$PROBE_PLUGINS/tool/test/plugin.sh" <<PLUG
test_run() { : > "${E2E_TEST_RAN}"; return 0; }
PLUG

if command -v setsid >/dev/null 2>&1; then
    setsid bash "$RUNNER" --goal "w15h e2e" \
        >"$TEST_TEMP_DIR/runner-e2e.stdout" 2>"$TEST_TEMP_DIR/runner-e2e.stderr" &
    RUNNER_PID=$!
    RUNNER_PGID="$RUNNER_PID"
else
    set -m
    bash "$RUNNER" --goal "w15h e2e" \
        >"$TEST_TEMP_DIR/runner-e2e.stdout" 2>"$TEST_TEMP_DIR/runner-e2e.stderr" &
    RUNNER_PID=$!
    RUNNER_PGID="$(ps -o pgid= "$RUNNER_PID" 2>/dev/null | tr -d ' ' || echo "$RUNNER_PID")"
    set +m
fi

for _ in $(seq 1 100); do
    [[ -f "$E2E_BUILD_STARTED" ]] && break
    sleep 0.1
done
if [[ ! -f "$E2E_BUILD_STARTED" ]]; then
    kill -KILL "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
    assert_fail "build stage reached before signal (T2)" \
        "stderr tail: $(tail -c 600 "$TEST_TEMP_DIR/runner-e2e.stderr" 2>/dev/null)"
    print_test_results
    exit 1
fi

sig_ts=$(date +%s)
kill -TERM "-$RUNNER_PGID" 2>/dev/null || kill -TERM "$RUNNER_PID" 2>/dev/null || true

set +e
wait "$RUNNER_PID"
runner_rc=$?
set -e
end_ts=$(date +%s)
sig_to_exit=$(( end_ts - sig_ts ))

assert_eq "runner exits 143 (flag-on, SIGTERM)" "143" "$runner_rc"

# Budget: 5s. The build plugin's polling loop is bounded at 2s of sleep so
# the runner trap fires within budget even under flag-on (where `set -m`
# puts the subshell in its own PGID and pgrp TERM does not reach it
# directly — the trap is deferred until the subshell returns naturally).
if [[ "$sig_to_exit" -le 5 ]]; then
    assert_pass "signal-to-exit ≤5s (actual=${sig_to_exit}s)"
else
    assert_fail "signal-to-exit ≤5s" "actual=${sig_to_exit}s"
fi

if [[ -f "$E2E_TEST_RAN" ]]; then
    assert_fail "test stage did NOT run after SIGTERM" "TEST_RAN sentinel exists"
else
    assert_pass "test stage did NOT run after SIGTERM"
fi

e2e_state_file="$E2E_STATE_DIR/pipeline-state.json"
if [[ -f "$e2e_state_file" ]]; then
    status="$(jq -r '.status // "MISSING"' "$e2e_state_file" 2>/dev/null || echo MISSING)"
    assert_eq "status=interrupted" "interrupted" "$status"
else
    assert_fail "pipeline-state.json exists" "missing: $e2e_state_file"
fi

if grep -q '"type":"pipeline.aborted".*sigterm' "$E2E_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "pipeline.aborted reason=sigterm emitted"
else
    assert_fail "pipeline.aborted reason=sigterm emitted" \
        "events tail: $(tail -c 800 "$E2E_EVENTS_JSONL" 2>/dev/null)"
fi

# No errors from the new job-control code path.
if grep -qiE "set -m: error|jobs -p: error|_runner_signal_trap.*error" \
       "$TEST_TEMP_DIR/runner-e2e.stderr" 2>/dev/null; then
    assert_fail "no job-control errors in stderr" \
        "stderr tail: $(tail -c 600 "$TEST_TEMP_DIR/runner-e2e.stderr")"
else
    assert_pass "no job-control errors in stderr"
fi

print_test_results
exit $((FAIL > 0))
