#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-gha-pipeline-test — Static validation of shipwright-pipeline.yml     ║
# ║  Tests for Phases 1-5: log artifact, npm cache, ordering, persistence,    ║
# ║  and unified retry caps                                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

WORKFLOW="$SCRIPT_DIR/../.github/workflows/shipwright-pipeline.yml"

print_test_header "GHA Pipeline Workflow: Phases 1-7 — Observability, Ordering, Persistence, Retry Caps, JSON Status, Unified Dispatch"

# ─── npm cache ─────────────────────────────────────────────────────────────

NPM_CACHE_COUNT=$(grep -c 'Restore npm cache' "$WORKFLOW" || true)
assert_eq \
    "npm cache restore step present" \
    "1" "$NPM_CACHE_COUNT"

assert_contains_regex \
    "npm cache uses actions/cache@v4" \
    "$(grep -A5 'Restore npm cache' "$WORKFLOW" || true)" \
    "actions/cache@v4"

assert_contains_regex \
    "npm cache path is ~/.npm" \
    "$(grep -A8 'Restore npm cache' "$WORKFLOW" || true)" \
    "path:.*~/.npm"

assert_contains_regex \
    "npm cache key includes hashFiles on workflow file (global tools, not package-lock.json)" \
    "$(grep -A8 'Restore npm cache' "$WORKFLOW" || true)" \
    "hashFiles.*shipwright-pipeline\.yml"

assert_contains_regex \
    "npm cache key includes runner.os" \
    "$(grep -A8 'Restore npm cache' "$WORKFLOW" || true)" \
    "runner\.os"

assert_contains_regex \
    "npm cache has restore-keys fallback" \
    "$(grep -A12 'Restore npm cache' "$WORKFLOW" || true)" \
    "restore-keys:"

# ─── upload-artifact ────────────────────────────────────────────────────────
# Workflow has two upload-artifact steps:
#   1. pipeline-logs-issue-<N>-run-<RUN_ID> — full log bundle
#   2. cost-breakdown-issue-<N>-run-<RUN_ID> — dedicated cost artifact (issue #460)

UPLOAD_COUNT=$(grep -c 'upload-artifact' "$WORKFLOW" || true)
assert_eq \
    "upload-artifact step present" \
    "2" "$UPLOAD_COUNT"

PIPELINE_LOGS_UPLOAD_COUNT=$(grep -c 'name: pipeline-logs-issue-' "$WORKFLOW" || true)
assert_eq \
    "pipeline-logs upload step present" \
    "1" "$PIPELINE_LOGS_UPLOAD_COUNT"

assert_contains_regex \
    "upload-artifact uses v4" \
    "$(grep 'upload-artifact' "$WORKFLOW" || true)" \
    "upload-artifact@v4"

assert_contains_regex \
    "upload-artifact if-condition has always() and claim_check skip guard" \
    "$(grep -B3 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "always\(\).*claim_check.*skip"

assert_contains_regex \
    "upload-artifact skips when claim_check skips" \
    "$(grep -B3 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "claim_check\.outputs\.skip"

assert_contains_regex \
    "upload-artifact includes pipeline.log" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "/tmp/pipeline\.log"

assert_contains_regex \
    "upload-artifact includes pipeline-artifacts dir" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "\.claude/pipeline-artifacts"

assert_contains_regex \
    "upload-artifact includes events.jsonl" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "events\.jsonl"

assert_contains_regex \
    "upload-artifact warns on missing files" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "if-no-files-found:.*warn"

assert_contains_regex \
    "upload-artifact has retention-days" \
    "$(grep -A15 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "retention-days:"

assert_contains_regex \
    "upload-artifact has continue-on-error" \
    "$(grep -A18 'upload-artifact@v4' "$WORKFLOW" || true)" \
    "continue-on-error: true"

# ─── cost-breakdown upload (issue #460) ─────────────────────────────────────

COST_UPLOAD_COUNT=$(grep -c 'name: cost-breakdown-issue-' "$WORKFLOW" || true)
assert_eq \
    "cost-breakdown upload step present" \
    "1" "$COST_UPLOAD_COUNT"

assert_contains_regex \
    "cost-breakdown upload uses v4" \
    "$(grep -B2 'name: cost-breakdown-issue-' "$WORKFLOW" || true)" \
    "upload-artifact@v4"

assert_contains_regex \
    "cost-breakdown upload has if-condition with always() and claim_check skip guard" \
    "$(grep -B5 'name: cost-breakdown-issue-' "$WORKFLOW" || true)" \
    "always\(\).*claim_check.*skip"

assert_contains_regex \
    "cost-breakdown upload references cost-breakdown.json path" \
    "$(grep -A5 'name: cost-breakdown-issue-' "$WORKFLOW" || true)" \
    "cost-breakdown\.json"

assert_contains_regex \
    "cost-breakdown upload has 30-day retention" \
    "$(grep -A6 'name: cost-breakdown-issue-' "$WORKFLOW" || true)" \
    "retention-days:[[:space:]]*30"

# ─── ordering: upload before exit-code propagation ──────────────────────────

UPLOAD_LINE=$(grep -n 'upload-artifact@v4' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)
EXITCODE_LINE=$(grep -n 'Propagate pipeline exit code' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$UPLOAD_LINE" -gt 0 && "$EXITCODE_LINE" -gt 0 && "$UPLOAD_LINE" -lt "$EXITCODE_LINE" ]]; then
    assert_pass "upload-artifact appears before exit-code propagation step"
else
    assert_fail "upload-artifact appears before exit-code propagation step" \
        "(upload line=$UPLOAD_LINE, exitcode line=$EXITCODE_LINE)"
fi

# ─── ordering: npm cache before Install Claude Code ─────────────────────────

NPM_CACHE_LINE=$(grep -n 'Restore npm cache' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)
INSTALL_CLAUDE_LINE=$(grep -nE '^[[:space:]]*- name: Install Claude Code' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$NPM_CACHE_LINE" -gt 0 && "$INSTALL_CLAUDE_LINE" -gt 0 && "$NPM_CACHE_LINE" -lt "$INSTALL_CLAUDE_LINE" ]]; then
    assert_pass "npm cache step appears before Install Claude Code"
else
    assert_fail "npm cache step appears before Install Claude Code" \
        "(cache line=$NPM_CACHE_LINE, install line=$INSTALL_CLAUDE_LINE)"
fi

# ─── Phase 2: early-exit ordering — auth probe and claim lock before expensive install ─

# Install Claude Code before Pre-flight auth check (auth probe needs claude CLI)
INSTALL_CLAUDE_LINE2=$(grep -nE '^[[:space:]]*- name: Install Claude Code' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)
AUTH_PROBE_LINE=$(grep -nE '^[[:space:]]*- name: Pre-flight auth check' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$INSTALL_CLAUDE_LINE2" -gt 0 && "$AUTH_PROBE_LINE" -gt 0 && "$INSTALL_CLAUDE_LINE2" -lt "$AUTH_PROBE_LINE" ]]; then
    assert_pass "Install Claude Code appears before Pre-flight auth check"
else
    assert_fail "Install Claude Code appears before Pre-flight auth check" \
        "(claude line=$INSTALL_CLAUDE_LINE2, auth line=$AUTH_PROBE_LINE)"
fi

# Pre-flight auth check before Install system dependencies
INSTALL_DEPS_LINE=$(grep -nE '^[[:space:]]*- name: Install system dependencies' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$AUTH_PROBE_LINE" -gt 0 && "$INSTALL_DEPS_LINE" -gt 0 && "$AUTH_PROBE_LINE" -lt "$INSTALL_DEPS_LINE" ]]; then
    assert_pass "Pre-flight auth check appears before Install system dependencies"
else
    assert_fail "Pre-flight auth check appears before Install system dependencies" \
        "(auth line=$AUTH_PROBE_LINE, deps line=$INSTALL_DEPS_LINE)"
fi

# Check claim lock before Install system dependencies
CLAIM_LOCK_LINE=$(grep -nE '^[[:space:]]*- name: Check claim lock' "$WORKFLOW" | head -1 | cut -d: -f1 || echo 0)

if [[ "$CLAIM_LOCK_LINE" -gt 0 && "$INSTALL_DEPS_LINE" -gt 0 && "$CLAIM_LOCK_LINE" -lt "$INSTALL_DEPS_LINE" ]]; then
    assert_pass "Check claim lock appears before Install system dependencies"
else
    assert_fail "Check claim lock appears before Install system dependencies" \
        "(claim line=$CLAIM_LOCK_LINE, deps line=$INSTALL_DEPS_LINE)"
fi

# Install system dependencies has skip guard condition
assert_contains_regex \
    "Install system dependencies has claim_check skip guard" \
    "$(grep -A2 'Install system dependencies' "$WORKFLOW" || true)" \
    "claim_check.*skip"

echo ""

# ─── Phase 3: Consolidate ruflo persistence ─────────────────────────────────

RUFLO_CACHE_KEY_COUNT=$(grep -c 'ruflo-memory-' "$WORKFLOW" || true)
assert_eq \
    "ruflo-memory- cache key removed (no actions/cache steps for ruflo)" \
    "0" "$RUFLO_CACHE_KEY_COUNT"

RUFLO_CACHE_PATH_COUNT=$(grep -c '\.claude-flow/data/' "$WORKFLOW" || true)
assert_eq \
    ".claude-flow/data/ cache path removed from workflow (ruflo manages dir itself)" \
    "0" "$RUFLO_CACHE_PATH_COUNT"

ENSURE_DIR_COUNT=$(grep -c 'Ensure ruflo memory cache dir exists' "$WORKFLOW" || true)
assert_eq \
    "Ensure ruflo memory cache dir exists step removed" \
    "0" "$ENSURE_DIR_COUNT"

assert_contains_regex \
    "ruflo orphan-branch restore (ruflo_ci_memory_pull) still present" \
    "$(grep 'ruflo_ci_memory_pull' "$WORKFLOW" || true)" \
    "ruflo_ci_memory_pull"

assert_contains_regex \
    "ruflo orphan-branch save (ruflo_ci_memory_push) still present" \
    "$(grep 'ruflo_ci_memory_push' "$WORKFLOW" || true)" \
    "ruflo_ci_memory_push"

echo ""

# ─── Phase 5: Unified retry caps ────────────────────────────────────────────

AUTO_RETRY_WORKFLOW="$SCRIPT_DIR/../.github/workflows/shipwright-auto-retry.yml"
WATCHDOG_WORKFLOW="$SCRIPT_DIR/../.github/workflows/shipwright-watchdog.yml"
RETRY_POLICY_SCRIPT="$SCRIPT_DIR/lib/retry-policy.sh"
POLICY_JSON="$SCRIPT_DIR/../config/policy.json"

# policy.json has retry section
assert_contains_regex \
    "config/policy.json has retry.max_pipeline_starts" \
    "$(jq -r '.retry.max_pipeline_starts // empty' "$POLICY_JSON" 2>/dev/null || true)" \
    "[0-9]+"

assert_contains_regex \
    "config/policy.json has retry.max_auto_retries" \
    "$(jq -r '.retry.max_auto_retries // empty' "$POLICY_JSON" 2>/dev/null || true)" \
    "[0-9]+"

assert_contains_regex \
    "config/policy.json has retry.abandon_after_minutes" \
    "$(jq -r '.retry.abandon_after_minutes // empty' "$POLICY_JSON" 2>/dev/null || true)" \
    "[0-9]+"

# retry-policy.sh exists
RETRY_POLICY_EXISTS=$([ -f "$RETRY_POLICY_SCRIPT" ] && echo "yes" || echo "no")
assert_eq \
    "scripts/lib/retry-policy.sh exists" \
    "yes" "$RETRY_POLICY_EXISTS"

# pipeline.yml sources retry-policy.sh and uses variable
assert_contains_regex \
    "shipwright-pipeline.yml sources retry-policy.sh in claim_check step" \
    "$(grep 'retry-policy\.sh' "$WORKFLOW" || true)" \
    "retry-policy\.sh"

assert_contains_regex \
    "shipwright-pipeline.yml uses RETRY_MAX_PIPELINE_STARTS variable (not hardcoded 6)" \
    "$(grep 'RETRY_MAX_PIPELINE_STARTS' "$WORKFLOW" || true)" \
    "RETRY_MAX_PIPELINE_STARTS"

# auto-retry.yml has checkout + sources retry-policy.sh + uses variable
AUTORETRY_CHECKOUT_COUNT=$(grep -c 'actions/checkout' "$AUTO_RETRY_WORKFLOW" || true)
assert_eq \
    "shipwright-auto-retry.yml has checkout step" \
    "1" "$AUTORETRY_CHECKOUT_COUNT"

assert_contains_regex \
    "shipwright-auto-retry.yml sources retry-policy.sh" \
    "$(grep 'retry-policy\.sh' "$AUTO_RETRY_WORKFLOW" || true)" \
    "retry-policy\.sh"

assert_contains_regex \
    "shipwright-auto-retry.yml uses RETRY_MAX_AUTO_RETRIES variable (not hardcoded 3)" \
    "$(grep 'RETRY_MAX_AUTO_RETRIES' "$AUTO_RETRY_WORKFLOW" || true)" \
    "RETRY_MAX_AUTO_RETRIES"

# watchdog.yml has checkout + sources retry-policy.sh + uses variable
WATCHDOG_CHECKOUT_COUNT=$(grep -c 'actions/checkout' "$WATCHDOG_WORKFLOW" || true)
assert_eq \
    "shipwright-watchdog.yml has checkout step" \
    "1" "$WATCHDOG_CHECKOUT_COUNT"

assert_contains_regex \
    "shipwright-watchdog.yml sources retry-policy.sh" \
    "$(grep 'retry-policy\.sh' "$WATCHDOG_WORKFLOW" || true)" \
    "retry-policy\.sh"

assert_contains_regex \
    "shipwright-watchdog.yml uses RETRY_ABANDON_AFTER_MINUTES variable (not hardcoded 120)" \
    "$(grep 'RETRY_ABANDON_AFTER_MINUTES' "$WATCHDOG_WORKFLOW" || true)" \
    "RETRY_ABANDON_AFTER_MINUTES"

# watchdog posts SHIPWRIGHT-CANCEL-REASON: watchdog and SHIPWRIGHT-WATCHDOG-CANCEL markers
assert_contains_regex \
    "shipwright-watchdog.yml posts SHIPWRIGHT-CANCEL-REASON: watchdog marker" \
    "$(grep 'SHIPWRIGHT-CANCEL-REASON' "$WATCHDOG_WORKFLOW" || true)" \
    "SHIPWRIGHT-CANCEL-REASON:.*watchdog"

assert_contains_regex \
    "shipwright-watchdog.yml posts SHIPWRIGHT-WATCHDOG-CANCEL run-scoped marker" \
    "$(grep 'SHIPWRIGHT-WATCHDOG-CANCEL' "$WATCHDOG_WORKFLOW" || true)" \
    "SHIPWRIGHT-WATCHDOG-CANCEL"

# auto-retry detects watchdog cancel scoped to the specific run_id (not CANCEL-REASON which is unscoped)
assert_contains_regex \
    "shipwright-auto-retry.yml detects watchdog cancel via run-scoped SHIPWRIGHT-WATCHDOG-CANCEL marker" \
    "$(grep 'SHIPWRIGHT-WATCHDOG-CANCEL' "$AUTO_RETRY_WORKFLOW" || true)" \
    "SHIPWRIGHT-WATCHDOG-CANCEL"

assert_contains_regex \
    "shipwright-auto-retry.yml skips retry count on watchdog cancel (watchdog_cancel)" \
    "$(grep 'watchdog_cancel' "$AUTO_RETRY_WORKFLOW" || true)" \
    "watchdog_cancel"

echo ""

# ─── Phase 6: pipeline-status.json ─────────────────────────────────────────

PIPELINE_STATE_SH="$SCRIPT_DIR/lib/pipeline-state.sh"
RESUME_WORKFLOW="$SCRIPT_DIR/../.github/workflows/pipeline-resume.yml"

assert_contains_regex \
    "pipeline-state.sh has write_pipeline_status_json function" \
    "$(grep 'write_pipeline_status_json' "$PIPELINE_STATE_SH" || true)" \
    "write_pipeline_status_json"

assert_contains_regex \
    "pipeline-state.sh calls write_pipeline_status_json from mark_stage_complete" \
    "$(awk '/^mark_stage_complete\(\)/,/^\}/' "$PIPELINE_STATE_SH" | grep 'write_pipeline_status_json' || true)" \
    "write_pipeline_status_json"

assert_contains_regex \
    "shipwright-watchdog.yml reads pipeline-status.json for last_heartbeat" \
    "$(grep 'pipeline-status\.json' "$WATCHDOG_WORKFLOW" || true)" \
    "pipeline-status\.json"

assert_contains_regex \
    "shipwright-auto-retry.yml reads pipeline-status.json for completed_stages" \
    "$(grep 'pipeline-status\.json' "$AUTO_RETRY_WORKFLOW" || true)" \
    "pipeline-status\.json"

assert_contains_regex \
    "pipeline-resume.yml reads pipeline-status.json as primary stage source" \
    "$(grep 'pipeline-status\.json' "$RESUME_WORKFLOW" || true)" \
    "pipeline-status\.json"

assert_contains_regex \
    "shipwright-dispatch.yml reads pipeline-status.json for completed_stages (sweep absorbed)" \
    "$(grep 'pipeline-status\.json' "$SCRIPT_DIR/../.github/workflows/shipwright-dispatch.yml" 2>/dev/null || echo "")" \
    "pipeline-status\.json"

assert_contains_regex \
    "shipwright-watchdog.yml uses JSON_HEARTBEAT as primary signal" \
    "$(grep 'JSON_HEARTBEAT' "$WATCHDOG_WORKFLOW" || true)" \
    "JSON_HEARTBEAT"

assert_contains_regex \
    "shipwright-auto-retry.yml uses JSON_RETRY for retry_count" \
    "$(grep 'JSON_RETRY' "$AUTO_RETRY_WORKFLOW" || true)" \
    "JSON_RETRY"

assert_contains_regex \
    "pipeline-resume.yml fixes Bash 3.2 \\\\s → [[:space:]] in grep" \
    "$(grep 'grep -E' "$RESUME_WORKFLOW" || true)" \
    "\[\[:space:\]\]"

echo ""

# ─── Phase 7: Unified dispatch (sweep merged into dispatch) ──────────────────

DISPATCH_WORKFLOW="$SCRIPT_DIR/../.github/workflows/shipwright-dispatch.yml"
SWEEP_WORKFLOW_PATH="$SCRIPT_DIR/../.github/workflows/shipwright-sweep.yml"

# sweep.yml must not exist
SWEEP_EXISTS=$([ -f "$SWEEP_WORKFLOW_PATH" ] && echo "yes" || echo "no")
assert_eq \
    "shipwright-sweep.yml deleted (merged into dispatch)" \
    "no" "$SWEEP_EXISTS"

# dispatch.yml loads policy for stuck threshold
assert_contains_regex \
    "shipwright-dispatch.yml loads stuck_threshold_hours from policy" \
    "$(grep 'stuck_threshold_hours' "$DISPATCH_WORKFLOW" || true)" \
    "stuck_threshold_hours"

# dispatch.yml has stuck detection logic
assert_contains_regex \
    "shipwright-dispatch.yml has stuck detection (Pipeline Starting)" \
    "$(grep 'Pipeline Starting' "$DISPATCH_WORKFLOW" || true)" \
    "Pipeline Starting"

# dispatch.yml has failure-without-retry check
assert_contains_regex \
    "shipwright-dispatch.yml has failure-without-retry check (Pipeline Failed)" \
    "$(grep 'Pipeline Failed' "$DISPATCH_WORKFLOW" || true)" \
    "Pipeline Failed"

# dispatch.yml has SHIPWRIGHT-RETRY guard
assert_contains_regex \
    "shipwright-dispatch.yml guards retry with SHIPWRIGHT-RETRY marker" \
    "$(grep 'SHIPWRIGHT-RETRY' "$DISPATCH_WORKFLOW" || true)" \
    "SHIPWRIGHT-RETRY"

# dispatch.yml has pipeline-status.json reading (inherited from sweep Phase 6)
assert_contains_regex \
    "shipwright-dispatch.yml reads pipeline-status.json for stage data" \
    "$(grep 'pipeline-status\.json' "$DISPATCH_WORKFLOW" || true)" \
    "pipeline-status\.json"

# dispatch.yml handles stuck issues as a separate step
assert_contains_regex \
    "shipwright-dispatch.yml has Handle stuck issues step" \
    "$(grep 'Handle stuck issues' "$DISPATCH_WORKFLOW" || true)" \
    "Handle stuck issues"

# dispatch.yml writes stuck output key to GITHUB_OUTPUT
assert_contains_regex \
    "shipwright-dispatch.yml writes stuck output to GITHUB_OUTPUT" \
    "$(grep 'stuck<<EOF\|echo "stuck=' "$DISPATCH_WORKFLOW" || true)" \
    'stuck<<EOF|stuck='

# dispatch.yml loads retry template from policy
assert_contains_regex \
    "shipwright-dispatch.yml loads retry_template from policy" \
    "$(grep -E 'retry_template|RETRY_TEMPLATE' "$DISPATCH_WORKFLOW" || true)" \
    "retry_template|RETRY_TEMPLATE"

echo ""

# ─── Phase 8: risk_level propagation ────────────────────────────────────────

PIPELINE_INTELLIGENCE="$SCRIPT_DIR/lib/pipeline-intelligence.sh"
PIPELINE_STAGES_REVIEW="$SCRIPT_DIR/lib/pipeline-stages-review.sh"

# shipwright-pipeline.yml passes risk_level as SHIPWRIGHT_RISK_LEVEL env var to pipeline job
assert_contains_regex \
    "shipwright-pipeline.yml sets SHIPWRIGHT_RISK_LEVEL in pipeline job env" \
    "$(grep 'SHIPWRIGHT_RISK_LEVEL' "$WORKFLOW" || true)" \
    "SHIPWRIGHT_RISK_LEVEL"

assert_contains_regex \
    "SHIPWRIGHT_RISK_LEVEL references triage outputs.risk_level" \
    "$(grep 'SHIPWRIGHT_RISK_LEVEL' "$WORKFLOW" || true)" \
    "triage.*risk_level|risk_level.*triage"

# triage risk step maps overall_risk score to categorical risk_level (sw-predictive.sh emits overall_risk)
assert_contains_regex \
    "triage risk step maps overall_risk score to categorical RISK_LEVEL" \
    "$(grep 'overall_risk\|RISK_SCORE.*-ge\|RISK_LEVEL.*critical' "$WORKFLOW" || true)" \
    "overall_risk|RISK_LEVEL.*critical"

# pipeline-intelligence.sh (primary runtime path) reads SHIPWRIGHT_RISK_LEVEL
assert_contains_regex \
    "pipeline-intelligence.sh (primary stage_compound_quality) reads SHIPWRIGHT_RISK_LEVEL" \
    "$(grep 'SHIPWRIGHT_RISK_LEVEL' "$PIPELINE_INTELLIGENCE" || true)" \
    "SHIPWRIGHT_RISK_LEVEL"

# pipeline-intelligence.sh forces adversarial_enabled on high/critical risk
assert_contains_regex \
    "pipeline-intelligence.sh forces adversarial_enabled=true on high/critical risk" \
    "$(grep -A3 'SHIPWRIGHT_RISK_LEVEL' "$PIPELINE_INTELLIGENCE" | grep 'adversarial' || true)" \
    "adversarial"

# pipeline-intelligence.sh forces negative_enabled on high/critical risk
assert_contains_regex \
    "pipeline-intelligence.sh forces negative_enabled=true on high/critical risk" \
    "$(grep -A3 'SHIPWRIGHT_RISK_LEVEL' "$PIPELINE_INTELLIGENCE" | grep 'negative' || true)" \
    "negative"

# pipeline-stages-review.sh (fallback) also reads SHIPWRIGHT_RISK_LEVEL
assert_contains_regex \
    "pipeline-stages-review.sh (fallback stage_compound_quality) also reads SHIPWRIGHT_RISK_LEVEL" \
    "$(grep 'SHIPWRIGHT_RISK_LEVEL' "$PIPELINE_STAGES_REVIEW" || true)" \
    "SHIPWRIGHT_RISK_LEVEL"

echo ""

# ─── Bug fixes: Phase 6 persistence, Phase 8 flag, Phase 1 epoch ────────────

LOOP_CONVERGENCE_SH="$SCRIPT_DIR/lib/loop-convergence.sh"
LOOP_RESTART_SH="$SCRIPT_DIR/lib/loop-restart.sh"
PIPELINE_STAGES_BUILD_SH="$SCRIPT_DIR/lib/pipeline-stages-build.sh"

# Phase 6 fix: pipeline-status.json must be mirrored into issue-N/ in snapshot step
assert_contains_regex \
    "snapshot step mirrors pipeline-status.json into issue-N/ directory" \
    "$(grep 'pipeline-status.json' "$WORKFLOW" | grep 'cp ' || true)" \
    "cp.*pipeline-status\.json.*ISSUE_DIR"

# Phase 8 fix: sw-predictive.sh main() must handle --issue flag
assert_contains_regex \
    "sw-predictive.sh main() parses --issue flag" \
    "$(grep -A5 '^main()' "$SCRIPT_DIR/sw-predictive.sh" | grep '\-\-issue' || grep '\-\-issue' "$SCRIPT_DIR/sw-predictive.sh" | head -3 || true)" \
    "\-\-issue"

assert_contains_regex \
    "sw-predictive.sh fetches issue JSON via gh issue view for --issue flag" \
    "$(grep 'gh issue view' "$SCRIPT_DIR/sw-predictive.sh" || true)" \
    "gh issue view"

# check_time_budget must use CI_JOB_START_EPOCH (per-job ephemeral anchor, not persisted field)
assert_contains_regex \
    "check_time_budget in loop-convergence.sh uses CI_JOB_START_EPOCH (not persisted PIPELINE_RUN_EPOCH)" \
    "$(grep 'CI_JOB_START_EPOCH' "$LOOP_CONVERGENCE_SH" || true)" \
    "CI_JOB_START_EPOCH"

assert_contains_regex \
    "loop-convergence.sh check_time_budget falls back to LOOP_START_EPOCH when CI_JOB_START_EPOCH absent" \
    "$(grep 'LOOP_START_EPOCH\|CI_JOB_START_EPOCH' "$LOOP_CONVERGENCE_SH" || true)" \
    "LOOP_START_EPOCH"

assert_contains_regex \
    "pipeline-stages-build.sh exports CI_JOB_START_EPOCH before invoking sw loop" \
    "$(grep 'export CI_JOB_START_EPOCH' "$PIPELINE_STAGES_BUILD_SH" || true)" \
    "export CI_JOB_START_EPOCH"

echo ""
print_test_results
