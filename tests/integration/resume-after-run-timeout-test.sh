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
#   P4 (integration): a run resumed with a tight max_run_s and a slow stage
#                     DOES time out — proving the watchdog is actually ARMED
#                     on the resumed run (not absent or disarmed). Together
#                     P3 + P4 establish "armed from the resumed run's start":
#                     P3 shows it doesn't fire too early, P4 shows it fires
#                     when the resumed run's OWN limit is genuinely exceeded.
#
# Why the test fails before implementation:
#   P1: get_resume_recommendation has no timed_out case; the `*` catch-all
#       returns fresh_start, not manual_resume_only. The assert_eq fails.
#   P2: _runner_resolve_run_limit_s is not yet defined. The assert_fail fires.
#   P3 and P4: blocked by P1 and P2 failures.
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

# ─── Common setup for P3 + P4 ────────────────────────────────────────────────
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

# Overlay repo with two templates: one for the quick stage (P3) and one for the
# slow stage (P4).
RESUME_OVERLAY="$(setup_git_temp_repo resume-after-timeout)"
mkdir -p "$RESUME_OVERLAY/.zbuild/templates"

# Quick-completing plugin (no sleep) for P3
mock_plugin_factory "resume-stage" "agent" 0 >/dev/null

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

# Slow plugin for P4: sleeps longer than the tight max_run_s
mock_plugin_factory "slow-resume-stage" "agent" 0 >/dev/null
cat > "$TEST_TEMP_DIR/plugins/agent/slow-resume-stage/plugin.sh" <<PLUG
slow_resume_stage_run() {
    sleep 30
    $(mock_v2_result_line slow-resume-stage)
    return 0
}
PLUG

cat > "$RESUME_OVERLAY/.zbuild/templates/resume-timeout-slow.yaml" <<'EOF'
id: resume-timeout-slow
extends: simple
stages:
  - id: slow-resume-stage
    gate: auto
    io:
      destinations: [file]
      tail_lines: 50
    router:
      timeout_s: 120
EOF

(cd "$RESUME_OVERLAY" && git add .zbuild && git commit -q -m "add resume-timeout templates") \
    >/dev/null 2>&1

# ─── P3: resumed run with generous limit completes — not stopped immediately ─
print_test_section "[#1944/SPEC-4] P3: resumed run with generous max_run_s completes normally"

RESUME_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, run_id:"prev-timed-out-run", issue:0,
      status:"timed_out", stage_statuses:{}, current_iteration:0,
      self_heal_count:{}, scope_manifest_hash:"", cost_ledger_pointer:0,
      claim_lease_id:"", plugin_state:{}, updated_at:$now}' \
    > "$RESUME_STATE_FILE"

export ZBUILD_STATE_FILE="$RESUME_STATE_FILE"

# max_run_s=30: the quick stage completes in < 5s, well within the limit.
# A watchdog that fires immediately (stale from original run) would produce
# timed_out status even though the stage finished quickly. A watchdog armed
# from the resumed run's start gives 30s — more than enough.
_p3_rc=0
( cd "$RESUME_OVERLAY" && ZBUILD_MAX_RUN_S=30 bash "$RUNNER" \
    --template resume-timeout --goal "resume-after-timeout test p3" \
    --resume --force ) \
    >"$TEST_TEMP_DIR/p3.stdout" 2>"$TEST_TEMP_DIR/p3.stderr" \
    || _p3_rc=$?

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

# ─── P4: resumed run with tight limit and slow stage DOES time out ────────────
# Proves the watchdog is ARMED on the resumed run, not absent or disarmed.
# Without a watchdog: slow stage runs until the outer timeout 25s kills it
# (rc=137), not rc=1 from a clean watchdog-driven timed_out exit.
# With a watchdog armed from the resumed run's start (max_run_s=2): the run
# ends with status=timed_out and rc=1 before the outer timeout fires.
print_test_section "[#1944/SPEC-4] P4: resumed run with tight limit times out — watchdog is armed"

# Fresh state and events for P4
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-p4"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events-p4"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_EVENTS_DIR"

RESUME_STATE_P4="$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, run_id:"prev-timed-out-run-p4", issue:0,
      status:"timed_out", stage_statuses:{}, current_iteration:0,
      self_heal_count:{}, scope_manifest_hash:"", cost_ledger_pointer:0,
      claim_lease_id:"", plugin_state:{}, updated_at:$now}' \
    > "$RESUME_STATE_P4"

export ZBUILD_STATE_FILE="$RESUME_STATE_P4"

# max_run_s=2, slow stage sleeps 30s → watchdog fires at 2s if armed correctly
# Outer timeout 25s as safety net; rc=1 proves watchdog (not rc=137 from outer timeout)
_p4_rc=0
( cd "$RESUME_OVERLAY" && ZBUILD_MAX_RUN_S=2 timeout 25 bash "$RUNNER" \
    --template resume-timeout-slow --goal "resume-after-timeout test p4" \
    --resume --force ) \
    >"$TEST_TEMP_DIR/p4.stdout" 2>"$TEST_TEMP_DIR/p4.stderr" \
    || _p4_rc=$?

# rc=1 means the watchdog fired cleanly (not rc=137 from outer timeout)
assert_eq "[#1944/SPEC-4] P4: resumed run exits 1 (watchdog fired, not outer timeout)" \
    "1" "$_p4_rc"

if [[ -f "$RESUME_STATE_P4" ]]; then
    _p4_status="$(jq -r '.status // empty' "$RESUME_STATE_P4" 2>/dev/null || true)"
    assert_eq "[#1944/SPEC-4] P4: resumed run with slow stage ends timed_out (watchdog is armed)" \
        "timed_out" "$_p4_status"
else
    assert_fail "[#1944/SPEC-4] P4: pipeline-state.json written after timed-out resumed run" \
        "state file not found: $RESUME_STATE_P4"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
