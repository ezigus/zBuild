#!/usr/bin/env bash
# Integration test (Wave 15-H / #688): with ZBUILD_RUNNER_JOB_CONTROL=1
# enabled, the happy-path pipeline still completes cleanly (no spurious
# abort, no broken `wait`, events emitted correctly, rc=0 on success).
#
# Risks the test guards against (from issue body):
#   - `set -m` makes bash auto-disown completed background children; the
#     existing trap chain must not break the normal `wait` calls.
#   - The signal handler's `jobs -p` traversal must NOT fire on a clean
#     run (no children alive when EXIT trap runs cleanly).
#   - Flag-on must not produce false `pipeline.aborted` events.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner job-control happy-path regression (Wave 15-H / #688)"
setup_test_env "runner-job-control-regression"

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

# ─── Wave 15-H flag ──────────────────────────────────────────────────────────
export ZBUILD_RUNNER_JOB_CONTROL=1

export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

# All stages succeed instantly — pure happy path.
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "plan"   "agent" 0 >/dev/null
# #746: standard template now includes impact between plan and build (plan_impact_cycle).
mock_plugin_factory "impact" "agent" 0 >/dev/null
mock_plugin_factory "design" "agent" 0 "" "designer" >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
mock_plugin_factory "test"   "tool"  0 >/dev/null
mock_plugin_factory "test_assessment" "agent" 0 >/dev/null
# #755: review_cycle.flow now includes the 4 compound_quality stages.
mock_plugin_factory "cq-preflight" "agent" 0 >/dev/null
mock_plugin_factory "cq-audit-plan" "agent" 0 >/dev/null
mock_plugin_factory "cq-cycle" "agent" 0 >/dev/null
mock_plugin_factory "cq-backtrack" "agent" 0 >/dev/null
mock_plugin_factory "review" "agent" 0 >/dev/null

set +e
bash "$RUNNER" --goal "w15h job-control happy path" \
    >"$TEST_TEMP_DIR/runner.stdout" 2>"$TEST_TEMP_DIR/runner.stderr"
runner_rc=$?
set -e

# ─── Assertions ──────────────────────────────────────────────────────────────

# (1) Runner exits 0 cleanly.
if [[ "$runner_rc" -eq 0 ]]; then
    assert_pass "runner exits rc=0 with ZBUILD_RUNNER_JOB_CONTROL=1"
else
    assert_fail "runner exits rc=0 with ZBUILD_RUNNER_JOB_CONTROL=1" \
        "got rc=$runner_rc. Stderr tail: $(tail -c 800 "$TEST_TEMP_DIR/runner.stderr" 2>/dev/null)"
fi

# (2) NO spurious pipeline.aborted event.
if [[ -f "$EVENTS_JSONL" ]] && grep -q '"type":"pipeline.aborted"' "$EVENTS_JSONL"; then
    assert_fail "no spurious pipeline.aborted event on happy path" \
        "events tail: $(tail -c 800 "$EVENTS_JSONL" 2>/dev/null)"
else
    assert_pass "no spurious pipeline.aborted event on happy path"
fi

# (3) pipeline-state.json status NOT interrupted (clean status set by stages).
state_file="$STATE_DIR/pipeline-state.json"
if [[ -f "$state_file" ]]; then
    status="$(jq -r '.status // "MISSING"' "$state_file" 2>/dev/null || echo MISSING)"
    if [[ "$status" == "interrupted" ]]; then
        assert_fail "pipeline-state.json status != interrupted" "got: $status"
    else
        assert_pass "pipeline-state.json status=$status (not interrupted)"
    fi
else
    assert_fail "pipeline-state.json exists" "missing: $state_file"
fi

# (4) Stage events emitted (sanity: pipeline actually ran).
if [[ -f "$EVENTS_JSONL" ]] && grep -q '"type":"stage.start"' "$EVENTS_JSONL"; then
    assert_pass "stage.start events emitted (pipeline ran end-to-end)"
else
    assert_fail "stage.start events emitted" \
        "events: $(wc -l <"$EVENTS_JSONL" 2>/dev/null) lines"
fi

# (5) No stray "abort sentinel" left behind.
if [[ -e "$STATE_DIR/.abort.signal" ]]; then
    assert_fail "no stale .abort.signal on clean exit" \
        "found: $STATE_DIR/.abort.signal"
else
    assert_pass "no stale .abort.signal on clean exit"
fi

print_test_results
exit $((FAIL > 0))
