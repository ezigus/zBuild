#!/usr/bin/env bash
# Integration test: plan contract v2 (#1835) — scope_too_large and router-failure
# paths across the real subprocess boundary. Split from plan-integration-test.sh
# (review #2237). Shared setup: plan-integration-lib.sh.
# shellcheck disable=SC2034  # PLAN_GOAL / CANNED_PLAN are read by plan-integration-lib.sh's _run_plan and model mock
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan — v2 router paths (integration, #1835)"

setup_test_env "plugin-plan-v2-router"

# shellcheck source=plan-integration-lib.sh
source "$SCRIPT_DIR/plan-integration-lib.sh"

_plan_error_boundary_env

# ═══════════════════════════════════════════════════════════════════════════
#  Issue #1835 — SPEC-3 and SPEC-8 migration assertions
# ═══════════════════════════════════════════════════════════════════════════
print_test_header "Issue #1835 — plan contract v2: scope_too_large and router failure paths"

# Restore clean state for #1835 tests.
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
PLAN_GOAL="a very large goal that exhausts the turn budget"
unset ZBUILD_PLAN_RESUME ZBUILD_ISSUE_NUMBER 2>/dev/null || true

# ─── [#1835/SPEC-3][change] scope_too_large path → rc=1, plan.json with disposition=out_of_turns ─
# After migration: max_turns exhaustion writes plan.json with result_contract:2,
# verdict=error, disposition=out_of_turns and returns rc=1 (not rc=10). plan.json
# MUST be present (not absent as in the pre-migration contract).
# Fails at baseline because the current plugin returns rc=10 and writes no plan.json.
print_test_section "[#1835/SPEC-3] max_turns → rc=1, plan.json with disposition=out_of_turns"
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
# Default error mock = error_max_turns, exit 1 (same mock as the existing SPEC-3 block).
install_envelope_mock_claude_error
unset ZBUILD_MOCK_SUBTYPE ZBUILD_MOCK_RESULT ZBUILD_MOCK_RC ZBUILD_MOCK_NUM_TURNS 2>/dev/null || true
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
_s3v2_rc=$?
set -e
assert_eq "[#1835/SPEC-3] max_turns plan_run returns rc=1 (not rc=10 after v2 migration)" "1" "$_s3v2_rc"
assert_file_exists "[#1835/SPEC-3] plan.json written on scope_too_large path" "$ARTIFACTS_DIR/plan.json"
assert_eq "[#1835/SPEC-3] plan.json result_contract=2 on out_of_turns path" "2" \
    "$(jq -r '.result_contract // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-3] plan.json verdict=error on out_of_turns path" "error" \
    "$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-3] plan.json disposition=out_of_turns" "out_of_turns" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
# plan.scope_too_large event must still fire — the signal is still needed even though
# the exit code changed from 10 to 1.
assert_event_emitted "[#1835/SPEC-3] plan.scope_too_large still emitted on v2 path" \
    "$ZBUILD_EVENTS_JSONL" "plan.scope_too_large"

# ─── [#1835/SPEC-8][change] non-max_turns router failure → plan.json via router_reason_disposition ─
# A router failure with subtype≠error_max_turns and no recoverable plan must
# write plan.json with verdict=error and disposition resolved from router_reason_disposition:
# timed_out for rc=124 (router_timeout), interrupted for rc=137 (router_oom_kill),
# misconfigured for rc=2 (router_config_error). rc=1 on all paths.
# Fails at baseline because the non-max_turns failure path does not write plan.json at all.
print_test_section "[#1835/SPEC-8] non-max_turns router failure writes plan.json via router_reason_disposition"

# rc=124 (wall-clock timeout) → disposition=timed_out
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_PLAN_RESUME=0
_S8_RESULT="$TEST_TEMP_DIR/s8-timeout-result.txt"
printf '%s' "" > "$_S8_RESULT"
_install_plan_error_mock_file --subtype "error_during_execution" \
    --result-file "$_S8_RESULT" --rc 124
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
_s8_timeout_rc=$?
set -e
assert_eq "[#1835/SPEC-8] router timeout (rc=124) → plugin rc=1" "1" "$_s8_timeout_rc"
assert_file_exists "[#1835/SPEC-8] router timeout writes plan.json" "$ARTIFACTS_DIR/plan.json"
assert_eq "[#1835/SPEC-8] router timeout result_contract=2" "2" \
    "$(jq -r '.result_contract // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-8] router timeout verdict=error" "error" \
    "$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-8] router timeout disposition=timed_out" "timed_out" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"

# rc=137 (OOM kill) → disposition=interrupted
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
_S8_OOM_RESULT="$TEST_TEMP_DIR/s8-oom-result.txt"
printf '%s' "" > "$_S8_OOM_RESULT"
_install_plan_error_mock_file --subtype "error_during_execution" \
    --result-file "$_S8_OOM_RESULT" --rc 137
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
_s8_oom_rc=$?
set -e
assert_eq "[#1835/SPEC-8] OOM kill (rc=137) → plugin rc=1" "1" "$_s8_oom_rc"
assert_file_exists "[#1835/SPEC-8] OOM kill writes plan.json" "$ARTIFACTS_DIR/plan.json"
assert_eq "[#1835/SPEC-8] OOM kill result_contract=2" "2" \
    "$(jq -r '.result_contract // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-8] OOM kill verdict=error" "error" \
    "$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-8] OOM kill disposition=interrupted" "interrupted" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"

# rc=2 (router config error) → disposition=misconfigured
# route.sh normalises all non-124/137 claude binary exit codes to rc=1 (see
# _route_call_claude case statement). The real router rc=2 path comes from the
# router's own setup checks BEFORE the claude binary is invoked — specifically
# the max_turns validation at the top of _route_call_claude. Setting
# ZBUILD_ROUTER_MAX_TURNS to a non-numeric value forces that path: the resolver
# returns the invalid value, the validator fires, and route_to_model returns 2
# without ever calling the claude binary. This is the router_config_error case
# _router_rc_classify maps to disposition=misconfigured.
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_ROUTER_MAX_TURNS="INVALID_MAX_TURNS_1835"
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
_s8_cfg_rc=$?
set -e
unset ZBUILD_ROUTER_MAX_TURNS 2>/dev/null || true
assert_eq "[#1835/SPEC-8] config error (rc=2) → plugin rc=1" "1" "$_s8_cfg_rc"
assert_file_exists "[#1835/SPEC-8] config error writes plan.json" "$ARTIFACTS_DIR/plan.json"
assert_eq "[#1835/SPEC-8] config error result_contract=2" "2" \
    "$(jq -r '.result_contract // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-8] config error verdict=error" "error" \
    "$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-8] config error disposition=misconfigured" "misconfigured" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"

unset ZBUILD_PLAN_RESUME 2>/dev/null || true


cleanup_test_env
print_test_results
exit $((FAIL > 0))
