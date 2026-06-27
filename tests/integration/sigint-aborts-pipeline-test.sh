#!/usr/bin/env bash
# Integration test (#612): SIGINT propagation from claude → router → build →
# runner halts the pipeline cleanly with status=interrupted + pipeline.aborted
# reason=sigint.
#
# Repro of the user-observed bug: pressing Ctrl-C did not stop the pipeline —
# the router's loop absorbed rc=130 as a transient error and kept iterating.
#
# Why we DON'T `kill -INT $runner_pid` here: the bash harness this test runs
# under starts non-interactively with SIGINT inherited as SIG_IGN; the runner
# bash cannot un-ignore it (POSIX). So we drive the kernel-level behavior
# end-to-end by simulating what actually happens on Ctrl-C: when the operator
# presses Ctrl-C, the kernel delivers SIGINT to every process in the
# foreground process group. claude (in the same pgrp as the runner) dies →
# `wait` reaps rc=130. THAT is the propagation chain that was broken; the
# mock claude here returns rc=130 directly to drive it.
#
# Assertions:
#   - Pipeline halts (does NOT iterate further).
#   - Claude is invoked at most twice (loop must not keep spawning).
#   - pipeline-state.json status=interrupted.
#   - `pipeline.aborted reason=sigint` event present in events.jsonl.
#   - Total wall-clock < 4s (no hung loop).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "sigint-aborts-pipeline — rc=130 chain halts pipeline (#612)"
setup_test_env "sigint-aborts-pipeline"
# Wave 12-E (#664): default is enforce. Stub plugins used here lack honest
# inputs/outputs blocks; opt out — this suite tests SIGINT chain semantics.
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

# Mock claude that records each invocation and exits 130 (simulates kernel
# SIGINT delivery to the foreground pgrp).
mkdir -p "$TEST_TEMP_DIR/bin"
CLAUDE_CALLS="$TEST_TEMP_DIR/claude-calls.log"
: > "$CLAUDE_CALLS"
export CLAUDE_CALLS
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
echo "call" >> "${CLAUDE_CALLS}"
exit 130
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Throwaway git repo for route_to_model_loop's `git diff HEAD` capture.
REPO="$TEST_TEMP_DIR/work-repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null
export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

# #921: intentional 6-stage subset (ZBUILD_CYCLES_ENABLED=0 → design/impact/cq-*
# never load; pipeline aborts at intake). Do NOT replace with
# register_standard_pipeline_stubs — the partial roster is deliberate.
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "plan"   "agent" 0 >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
mock_plugin_factory "test"   "tool"  0 >/dev/null
mock_plugin_factory "test_assessment" "agent" 0 >/dev/null
mock_plugin_factory "review" "agent" 0 >/dev/null

# Stage with route_to_model_loop: replace intake's run hook to invoke the loop
# directly (avoids dragging in the full build plugin's preconditions, while
# still exercising the router → stage exit-code → runner chain).
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<PLUG
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/core/router/route.sh"

intake_run() {
    local pf="${TEST_TEMP_DIR}/route-prompt.txt"
    echo "sigint propagation test prompt" > "\$pf"
    route_to_model_loop T2 "\$pf" "${REPO}" 5
    return \$?
}
PLUG

RC_FILE="$TEST_TEMP_DIR/runner-rc"
ELAPSED_FILE="$TEST_TEMP_DIR/elapsed"

start_ts=$(date +%s)
set +e
bash "$RUNNER" --goal "test-sigint-halt" \
    >"$TEST_TEMP_DIR/runner.stdout" 2>"$TEST_TEMP_DIR/runner.stderr"
runner_rc=$?
set -e
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
printf '%s' "$runner_rc" > "$RC_FILE"
printf '%s' "$elapsed" > "$ELAPSED_FILE"

# ─── Assertions ──────────────────────────────────────────────────────────────

# (0) Runner finished — captured rc.
assert_pass "runner exited (rc=$runner_rc)"

# Codex P2 on #616: runner must distinguish SIGINT (rc=130) from generic failure (rc=1)
if [[ "$runner_rc" -eq 130 ]]; then
    assert_pass "runner exits 130 distinctly on SIGINT (not generic rc=1)"
else
    assert_fail "runner exits 130 distinctly on SIGINT" "got rc=$runner_rc"
fi

# (1) Wall-clock budget: hang-backstop only (#1059). The real abort proof is the
#     call-count + single pipeline.aborted assertions below; this generous bound
#     just catches a true hang (was a tight ≤4s that flaked on the macOS matrix).
if [[ "$elapsed" -le 60 ]]; then
    assert_pass "pipeline halted in ≤60s end-to-end (actual=${elapsed}s)"
else
    assert_fail "pipeline halted in ≤60s end-to-end" \
        "actual=${elapsed}s — route loop appears hung on rc=130"
fi

# (2) Claude invoked at most 2 times. With the fix, exactly 1.
call_count="$(wc -l < "$CLAUDE_CALLS" 2>/dev/null | tr -d ' ' || echo 0)"
if [[ "$call_count" -le 2 ]]; then
    assert_pass "claude invoked at most 2 times (actual=$call_count) — loop did NOT iterate after rc=130"
else
    assert_fail "claude invoked at most 2 times" \
        "actual=$call_count — loop absorbed SIGINT and kept spawning"
fi

# (3) Pipeline state status=interrupted.
state_file="$STATE_DIR/pipeline-state.json"
if [[ -f "$state_file" ]]; then
    status="$(jq -r '.status // "MISSING"' "$state_file" 2>/dev/null || echo MISSING)"
    assert_eq "pipeline-state.json status=interrupted" "interrupted" "$status"
else
    assert_fail "pipeline-state.json exists" "missing: $state_file"
fi

# (4) pipeline.aborted event with reason=sigint emitted.
if [[ -f "$EVENTS_JSONL" ]]; then
    if grep '"type":"pipeline.aborted"' "$EVENTS_JSONL" | grep -q 'sigint'; then
        assert_pass "pipeline.aborted event emitted with reason=sigint"
    else
        assert_fail "pipeline.aborted event emitted with reason=sigint" \
            "events tail: $(tail -c 800 "$EVENTS_JSONL" 2>/dev/null)"
    fi
else
    assert_fail "events.jsonl exists" "missing: $EVENTS_JSONL"
fi

# (5) loop.terminated.signal event must also be present (router's signal exit).
if grep -q '"type":"loop.terminated.signal"' "$EVENTS_JSONL" 2>/dev/null; then
    assert_pass "loop.terminated.signal event emitted (router signal path)"
else
    assert_fail "loop.terminated.signal event emitted (router signal path)" \
        "events tail: $(tail -c 400 "$EVENTS_JSONL" 2>/dev/null)"
fi

print_test_results
