#!/usr/bin/env bash
# Integration: resumed run after timed_out uses a fresh watchdog (#1944)
#
# SPEC-4 [code]: a run resumed after a timed_out end is not stopped
#   immediately — its watchdog is armed from the resumed run's wall-clock
#   start, not the original run's.
#
# Phases:
#   P1 (unit):        get_resume_recommendation(timed_out) = manual_resume_only;
#                     not auto_resume and not fresh_start.
#   P2 (unit):        _runner_resolve_run_limit_s is defined in stage-limits.sh
#                     — the function that arms the watchdog on every invocation,
#                     including --resume. Absent before the implementation.
#   P3 (integration): a run resumed (--force) after a timed_out state with a
#                     generous max_run_s completes normally — not stopped
#                     immediately, proving the watchdog was armed from the
#                     resumed run's wall-clock start.
#
# Why the test fails before implementation:
#   P1: get_resume_recommendation has no timed_out case; the `*` catch-all
#       returns fresh_start, not manual_resume_only. The assert_eq fails.
#   P2: _runner_resolve_run_limit_s is not yet defined. The assert_fail fires.
#   P3: passes even before implementation (no watchdog → run completes
#       normally), but the earlier failures already cause the test to exit
#       non-zero.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "resume-after-run-timeout: watchdog armed from resumed run's wall-clock start (#1944 SPEC-4)"
setup_test_env "resume-after-run-timeout"

# ─── P1: get_resume_recommendation returns manual_resume_only for timed_out ──
print_test_section "[#1944/SPEC-4] P1: get_resume_recommendation(timed_out) = manual_resume_only"

# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh" 2>/dev/null || true

P1_STATE="$TEST_TEMP_DIR/p1-timed-out-state.json"
jq -n \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, run_id:"test-run-timed-out", issue:0,
      status:"timed_out", stage_statuses:{}, current_iteration:0,
      self_heal_count:{}, scope_manifest_hash:"", cost_ledger_pointer:0,
      claim_lease_id:"", plugin_state:{}, updated_at:$now}' \
    > "$P1_STATE"

if declare -F get_resume_recommendation >/dev/null 2>&1; then
    _p1_rec="$(get_resume_recommendation "$P1_STATE" 2>/dev/null || true)"
    # Must be manual_resume_only — not fresh_start (the `*` catch-all before
    # implementation) and not auto_resume (which would silently re-run it).
    assert_eq "[#1944/SPEC-4] P1: get_resume_recommendation(timed_out) = manual_resume_only" \
        "manual_resume_only" "$_p1_rec"
else
    assert_fail "[#1944/SPEC-4] P1: get_resume_recommendation is defined" \
        "function not found after sourcing core/state/resume.sh"
fi

# ─── P2: _runner_resolve_run_limit_s is defined ───────────────────────────────
print_test_section "[#1944/SPEC-4] P2: _runner_resolve_run_limit_s defined (watchdog arms on every invocation)"

# shellcheck source=../../scripts/lib/stage-limits.sh
source "$REPO_ROOT/scripts/lib/stage-limits.sh" 2>/dev/null || true

if declare -F _runner_resolve_run_limit_s >/dev/null 2>&1; then
    assert_pass "[#1944/SPEC-4] P2: _runner_resolve_run_limit_s is defined in stage-limits.sh"
else
    assert_fail "[#1944/SPEC-4] P2: _runner_resolve_run_limit_s is defined in stage-limits.sh" \
        "function not found — the watchdog cannot be armed on resume without it"
fi

# ─── P3: resumed run with generous limit completes — not stopped immediately ─
print_test_section "[#1944/SPEC-4] P3: resumed run completes normally with generous max_run_s"

export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0
export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_EVENTS_DIR" "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

# Quick-completing plugin (no sleep) — the resumed run's stage completes fast
mock_plugin_factory "resume-stage" "agent" 0 >/dev/null

# Overlay repo with a single-stage template
RESUME_OVERLAY="$(setup_git_temp_repo resume-after-timeout)"
mkdir -p "$RESUME_OVERLAY/.zbuild/templates"
cat > "$RESUME_OVERLAY/.zbuild/templates/resume-timeout.yaml" <<'EOF'
id: resume-timeout
extends: simple
stages:
  - id: resume-stage
    gate: auto
    io:
      destinations: [file]
      tail_lines: 50
EOF
(cd "$RESUME_OVERLAY" && git add .zbuild && git commit -q -m "add resume-timeout template") \
    >/dev/null 2>&1

# Seed the state dir with a timed_out state, as if a previous run timed out.
# The resumed run must arm its OWN watchdog from ITS wall-clock start, not
# from the original run's start. With max_run_s=30 the new run has 30 s —
# far more than the fast stage needs — so it must NOT be stopped immediately.
RESUME_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, run_id:"prev-timed-out-run", issue:0,
      status:"timed_out", stage_statuses:{}, current_iteration:0,
      self_heal_count:{}, scope_manifest_hash:"", cost_ledger_pointer:0,
      claim_lease_id:"", plugin_state:{}, updated_at:$now}' \
    > "$RESUME_STATE_FILE"

export ZBUILD_STATE_FILE="$RESUME_STATE_FILE"

set +e
( cd "$RESUME_OVERLAY" && ZBUILD_MAX_RUN_S=30 bash "$RUNNER" \
    --template resume-timeout --goal "resume-after-timeout test p3" \
    --resume --force ) \
    >"$TEST_TEMP_DIR/p3.stdout" 2>"$TEST_TEMP_DIR/p3.stderr"
_p3_rc=$?
set -e

# The resumed run must NOT end with timed_out — the fresh watchdog has
# 30 s, and the stage completes in < 5 s.
if [[ -f "$RESUME_STATE_FILE" ]]; then
    _p3_status="$(jq -r '.status // empty' "$RESUME_STATE_FILE" 2>/dev/null || true)"
    if [[ "$_p3_status" == "timed_out" ]]; then
        assert_fail "[#1944/SPEC-4] P3: resumed run did not time out (watchdog is fresh)" \
            "pipeline status is still timed_out — watchdog may have fired immediately"
    else
        assert_pass "[#1944/SPEC-4] P3: resumed run did not time out (status=$_p3_status)"
    fi
else
    assert_fail "[#1944/SPEC-4] P3: pipeline-state.json accessible after resumed run" \
        "state file not found: $RESUME_STATE_FILE"
fi

# No pipeline.end event with status=timed_out in the resumed run's events
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    _p3_to_events="$(jq -r \
        'select(.type=="pipeline.end" and .data.status=="timed_out") | .type' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    assert_eq "[#1944/SPEC-4] P3: no pipeline.end/timed_out event in resumed run" \
        "0" "$_p3_to_events"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
