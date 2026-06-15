#!/usr/bin/env bash
# Integration test (#895): a build_test_cycle whose build no-ops on a green suite
# CONVERGES at iter 1 — it does not livelock to max_iterations.
#
# Drives the REAL cycle_orchestrator_run + the REAL test_assessment plugin. The
# build stage writes build-summary.json verdict=empty_diff (done_sentinel, work
# already implemented); the test stage writes test-results.json verdict=pass; the
# test_assessment stage runs the real plugin (LLM canned to pass/agrees=true).
# With the #895 fix, test_assessment returns pass → cycle converges in 1 iter.
# Pre-fix, test_assessment downgraded empty_diff to inconclusive → the cycle ran
# to max_iterations=3 (the reported livelock).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build_test_cycle: no-op build on green converges, not livelock (#895)"
setup_test_env "build-test-cycle-noop-895"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_RUN_ID="noop-895-$$"

# ─── git fixture so test_assessment can read intake-baseline + run git diff ──
GIT_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$GIT_FIXTURE"
git -C "$GIT_FIXTURE" init --quiet >/dev/null 2>&1
git -C "$GIT_FIXTURE" config user.email 'test@example.com' >/dev/null
git -C "$GIT_FIXTURE" config user.name 'test' >/dev/null
printf 'seed\n' > "$GIT_FIXTURE/SEED"
git -C "$GIT_FIXTURE" add SEED >/dev/null
git -C "$GIT_FIXTURE" commit -m baseline --quiet >/dev/null
_BASELINE_SHA="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
cd "$GIT_FIXTURE"

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
ARTIFACTS_DIR="$ZBUILD_STATE_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR" "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"
printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_FILE"
printf '%s' "$_BASELINE_SHA" > "$ZBUILD_STATE_DIR/intake-baseline-ref.txt"  # raw SHA, no trailing newline (matches real intake)
cat > "$ZBUILD_STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE
cat > "$ARTIFACTS_DIR/plan.json" <<'PJ'
{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"s1","description":"d","files":["core/x.sh"],"estimated_lines":1}]}
PJ

# shellcheck source=../../plugins/agent/test_assessment/plugin.sh
source "$REPO_ROOT/plugins/agent/test_assessment/plugin.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/standard.yaml"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# ─── Mocks: redaction passthrough + canned LLM pass/agrees ───────────────────
# Defined AFTER sourcing the plugin so route.sh (sourced by the plugin) does not
# clobber the route_to_model override.
apply_scope_redaction() { cat "$1" > "$2"; return 0; }
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"all green, nothing to change","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"All good.","iter":1}'
route_to_model() { printf '%s\n' "$CANNED_RESPONSE"; return 0; }

# ─── Stub stage dispatch: real test_assessment, synthetic build+test ─────────
cycle_dispatch_stage() {
    local stage="$1" state_file="$3"
    local state_dir; state_dir="$(dirname "$state_file")"
    local artdir="$state_dir/artifacts"; mkdir -p "$artdir"
    local v="pass"
    case "$stage" in
        build)
            # Build no-ops: it found the work already implemented.
            printf '{"schema_version":1,"verdict":"empty_diff","iterations":1,"terminated_reason":"done_sentinel","files_changed":[]}' \
                > "$artdir/build-summary.json"
            v="empty_diff"
            ;;
        test)
            printf '{"schema_version":1,"verdict":"pass","exit_code":0,"passed":379,"failed":0,"test_output":"total: 379/379 passed","diff_applied":true,"test_cmd":"npm test"}' \
                > "$artdir/test-results.json"
            v="pass"
            ;;
        test_assessment)
            # REAL plugin: reads build-summary(empty_diff)+test-results(pass) and
            # applies the #895 convergence gate.
            test_assessment_run "test_assessment" "$state_file" >/dev/null 2>&1 || true
            v="$(jq -r '.verdict' "$artdir/test-assessment.json" 2>/dev/null || echo unknown)"
            ;;
    esac
    _CYCLE_DISPATCH_VERDICT="$v"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

set +e
cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE"
RC=$?
set -e

assert_eq "no-op build on green: cycle rc=0 (converged, not livelock)" "0" "$RC"
assert_eq "no-op build on green: reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "no-op build on green: exactly 1 iteration (not max_iterations=3)" "1" "${_CYCLE_LAST_ITERATIONS:-}"

# The real test_assessment must have produced verdict=pass (the #895 fix).
ta_verdict="$(jq -r '.verdict' "$ARTIFACTS_DIR/test-assessment.json" 2>/dev/null || echo missing)"
assert_eq "real test_assessment returned pass on empty_diff+green" "pass" "$ta_verdict"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
