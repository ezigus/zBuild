#!/usr/bin/env bash
# Integration test (ADR-006 + ADR-025, Wave 15-E #685): a pipeline aborted
# by SIGINT must be resumable end-to-end. Verifies the two contract points
# Wave 15-E owns:
#
#   1. The runner's SIGINT path leaves state in the shape ADR-006 expects:
#      pipeline-state.json status=interrupted (per the status enum amendment
#      in ADR-006), with `stage_statuses[intake]=complete` so the resume
#      dispatch loop knows to skip intake and start at build. ADR-006's
#      status enum maps SIGINT/mid-flight cancellation → `interrupted`;
#      `aborted` is explicit-operator-cancel.
#
#   2. `--resume` clears the `.abort.signal` sentinel BEFORE the dispatch
#      loop's first `_zbuild_check_abort` pre-flight. The normal EXIT trap
#      already disarms the sentinel (verified by full-pipeline-sigint-test.sh
#      T5), but kill -9 / host crash / any path skipping the EXIT trap can
#      leave a stale sentinel. Without the defensive disarm at resume
#      entry, the first pre-flight in the dispatch loop would observe the
#      stale sentinel and re-abort the resumed run with rc=130. This test
#      simulates that hard-kill case by pre-arming the sentinel between
#      the abort and the resume.
#
# The test drives:
#   Phase 1 — fresh run with intake=success, build returns rc=130
#             → runner exits 130, state=interrupted, stage[intake]=complete,
#               stage[build]=failed-or-in_progress
#   Phase 2 — leave (or pre-arm) the sentinel file, then --resume the run
#             with build now succeeding, plus a marker test stage
#             → runner exits 0, sentinel cleared on resume entry, intake
#               is skipped, build re-runs and succeeds, test stage runs.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "resume-after-sigint — aborted run resumes from build (#685, Wave 15-E)"
setup_test_env "resume-after-sigint-w15e"
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

# Throwaway git repo so plugins that touch git don't fail on init.
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

# Seven standard mock plugins, all initially succeed.
# We will rewrite build/test on-the-fly between phases.
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "plan"   "agent" 0 >/dev/null
mock_plugin_factory "impact" "agent" 0 "" "impact_analyzer" >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
mock_plugin_factory "test"   "tool"  0 >/dev/null
mock_plugin_factory "test_assessment" "agent" 0 >/dev/null
mock_plugin_factory "review" "agent" 0 >/dev/null

# ── Phase 1 ────────────────────────────────────────────────────────────────
# build_run arms the sentinel (mimicking the runner SIGINT trap firing in a
# sibling subshell) AND returns 130. The runner's rc=130 path → exit 130 →
# _runner_abort_trap EXIT, which writes status=interrupted and disarms the
# sentinel. So after Phase 1 the sentinel is gone (matches full-pipeline-
# sigint-test.sh T5). We re-arm it explicitly below for Phase 2 to simulate
# the "hard kill / EXIT trap skipped" case.
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<'PLUG'
build_run() {
    : > "${ZBUILD_STATE_DIR}/.abort.signal"
    return 130
}
PLUG

# Marker so we can tell if test stage ran in either phase.
TEST_MARKER="$TEST_TEMP_DIR/test-stage-ran-marker"
cat > "$PLUGINS_ROOT/tool/test/plugin.sh" <<PLUG
test_run() {
    : > "${TEST_MARKER}"
    return 0
}
PLUG

set +e
bash "$RUNNER" --goal "w15e resume after sigint" \
    >"$TEST_TEMP_DIR/phase1.stdout" 2>"$TEST_TEMP_DIR/phase1.stderr"
phase1_rc=$?
set -e

state_file="$STATE_DIR/pipeline-state.json"

print_test_section "P1.T1: phase 1 runner exits rc=130 (SIGINT chain halted)"
assert_eq "phase1 rc=130" "130" "$phase1_rc"

print_test_section "P1.T2: pipeline-state.json exists and status=interrupted (ADR-006)"
if [[ ! -f "$state_file" ]]; then
    assert_fail "state file written" "missing: $state_file"
else
    p1_status="$(jq -r '.status // "MISSING"' "$state_file" 2>/dev/null || echo MISSING)"
    assert_eq "status=interrupted" "interrupted" "$p1_status"
fi

print_test_section "P1.T3: stage_statuses[intake]=complete (resume can skip it)"
p1_intake="$(jq -r '.stage_statuses.intake // "MISSING"' "$state_file" 2>/dev/null || echo MISSING)"
if [[ "$p1_intake" == "complete" ]]; then
    assert_pass "stage_statuses.intake=complete"
else
    assert_fail "stage_statuses.intake=complete" "actual=$p1_intake"
fi

print_test_section "P1.T4: run_id persisted on state file"
p1_run_id="$(jq -r '.run_id // "MISSING"' "$state_file" 2>/dev/null || echo MISSING)"
if [[ "$p1_run_id" != "MISSING" && -n "$p1_run_id" ]]; then
    assert_pass "run_id=$p1_run_id"
else
    assert_fail "run_id present" "missing in state file"
fi

print_test_section "P1.T5: test stage did NOT run in phase 1"
if [[ -e "$TEST_MARKER" ]]; then
    assert_fail "test stage skipped in phase 1" "marker present: $TEST_MARKER"
else
    assert_pass "test stage skipped in phase 1"
fi

# ── Phase 2 ────────────────────────────────────────────────────────────────
# Simulate a hard-kill scenario by re-arming the sentinel between abort and
# resume. The EXIT trap from phase 1 already cleared it; this is the
# defensive case we want resume to handle.
: > "$STATE_DIR/.abort.signal"

print_test_section "P2.T0: precondition — sentinel re-armed before resume"
if [[ -e "$STATE_DIR/.abort.signal" ]]; then
    assert_pass "sentinel re-armed at $STATE_DIR/.abort.signal"
else
    assert_fail "sentinel re-armed" "could not create: $STATE_DIR/.abort.signal"
fi

# Rewrite intake and build to drop a marker file when entered, so we can
# verify intake is skipped (already complete) and build is re-run on
# resume. Build also succeeds this time so the pipeline can complete.
INTAKE_RESUME_MARKER="$TEST_TEMP_DIR/intake-ran-on-resume"
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<PLUG
intake_run() {
    : > "${INTAKE_RESUME_MARKER}"
    return 0
}
PLUG

BUILD_RESUME_MARKER="$TEST_TEMP_DIR/build-ran-on-resume"
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<PLUG
build_run() {
    : > "${BUILD_RESUME_MARKER}"
    return 0
}
PLUG

# Clear test-stage marker so we can tell whether it ran during phase 2.
rm -f "$TEST_MARKER"

set +e
bash "$RUNNER" --resume --goal "w15e resume after sigint" \
    >"$TEST_TEMP_DIR/phase2.stdout" 2>"$TEST_TEMP_DIR/phase2.stderr"
phase2_rc=$?
set -e

print_test_section "P2.T1: resume runner exits rc=0 (pipeline completes after sentinel cleanup)"
if [[ "$phase2_rc" == "0" ]]; then
    assert_pass "phase2 rc=0"
else
    assert_fail "phase2 rc=0" \
        "actual rc=$phase2_rc; stderr tail: $(tail -c 800 "$TEST_TEMP_DIR/phase2.stderr" 2>/dev/null)"
fi

print_test_section "P2.T2: sentinel cleared by resume entry (no stale .abort.signal)"
if [[ -e "$STATE_DIR/.abort.signal" ]]; then
    assert_fail "sentinel cleared on resume" \
        "stale file present after resume: $STATE_DIR/.abort.signal"
else
    assert_pass "sentinel cleared on resume entry"
fi

print_test_section "P2.T3: intake NOT re-run on resume (skipped — already complete)"
if [[ -e "$INTAKE_RESUME_MARKER" ]]; then
    assert_fail "intake skipped on resume" \
        "intake re-ran on resume — marker present: $INTAKE_RESUME_MARKER"
else
    assert_pass "intake skipped on resume"
fi

print_test_section "P2.T4: build re-ran on resume (was in_progress/failed)"
if [[ -e "$BUILD_RESUME_MARKER" ]]; then
    assert_pass "build re-ran on resume"
else
    assert_fail "build re-ran on resume" "marker not present: $BUILD_RESUME_MARKER"
fi

print_test_section "P2.T5: test stage ran on resume (pipeline continued past build)"
if [[ -e "$TEST_MARKER" ]]; then
    assert_pass "test stage ran on resume"
else
    assert_fail "test stage ran on resume" "marker not present: $TEST_MARKER"
fi

print_test_section "P2.T6: pipeline-state.json status=complete after resume"
p2_status="$(jq -r '.status // "MISSING"' "$state_file" 2>/dev/null || echo MISSING)"
assert_eq "status=complete" "complete" "$p2_status"

print_test_section "P2.T7: pipeline.resume event emitted"
if grep -q '"type":"pipeline.resume"' "$EVENTS_JSONL" 2>/dev/null; then
    assert_pass "pipeline.resume emitted"
else
    assert_fail "pipeline.resume emitted" \
        "events tail: $(tail -c 800 "$EVENTS_JSONL" 2>/dev/null)"
fi

print_test_results
exit $((FAIL > 0))
