#!/usr/bin/env bash
# Integration: CQ-1 regression — real cq-* plugin dispatch with ADR-001 arg signature
#
# Sources the four real cq-* plugin files (not stubs), calls each *_run hook
# with the correct (stage_id, state_file) signature, and asserts all declared
# output artifacts appear under state/artifacts/. Also verifies no
# 'unbound variable' abort and no mkdir/mktemp 'Not a directory' errors.
# Pins expected artifact basenames via golden snapshot.
#
# Defects caught: Bug A (wrong arg-reading: state_dir=$1, artifact_dir=$2)
#                 Bug B (unbound ZBUILD_PLUGINS_ROOT in cq-cycle under set -u)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/golden.sh
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "cq-* real plugin dispatch — ADR-001 arg signature (CQ-1 regression)"
setup_test_env "cq-plugins-real-dispatch"

STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$ARTIFACTS_DIR"

# Minimal pipeline-state.json fixture
printf '{"stage":"cq-preflight","status":"running"}\n' > "$STATE_FILE"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Bug B: must be unset (not exported) so cq-cycle's ${ZBUILD_PLUGINS_ROOT:-...}
# fallback is exercised under set -u.
unset ZBUILD_PLUGINS_ROOT

# Place a minimal mock claude binary so cq-cycle's optional lens sub-plugins
# don't trigger a real LLM call if any code path reaches route_to_model.
mock_claude

# ─── Source real plugins ─────────────────────────────────────────────────────
# plugin-bootstrap resolves _ZBUILD_PLUGIN_DIR/_ZBUILD_PLUGIN_ROOT from
# BASH_SOURCE[0] at source time — works correctly when sourcing by absolute path.

# shellcheck source=../../plugins/agent/cq-preflight/plugin.sh
source "$REPO_ROOT/plugins/agent/cq-preflight/plugin.sh"
# shellcheck source=../../plugins/agent/cq-audit-plan/plugin.sh
source "$REPO_ROOT/plugins/agent/cq-audit-plan/plugin.sh"
# shellcheck source=../../plugins/agent/cq-cycle/plugin.sh
source "$REPO_ROOT/plugins/agent/cq-cycle/plugin.sh"
# shellcheck source=../../plugins/agent/cq-backtrack/plugin.sh
source "$REPO_ROOT/plugins/agent/cq-backtrack/plugin.sh"

# Override after source so event-bus write never fails in the test sandbox.
eb_emit_event() { return 0; }
# atomic_write: pipe stdin to dest file (no flock needed in test context).
atomic_write() { local dest="$1"; cat - > "$dest"; }

# ─── T1: cq_preflight_run writes cq-preflight-result.json ───────────────────
set +e
stderr_t1="$(cq_preflight_run "cq-preflight" "$STATE_FILE" 2>&1)"
rc_t1=$?
set -e

if [[ $rc_t1 -ne 0 && $rc_t1 -ne 1 ]]; then
    assert_fail "T1: cq_preflight_run exits 0 or 1 (not unbound/error)" \
        "rc=$rc_t1 stderr=$stderr_t1"
else
    assert_pass "T1: cq_preflight_run exits cleanly (rc=$rc_t1)"
fi

assert_file_exists "T1: cq-preflight-result.json written under artifacts/" \
    "$ARTIFACTS_DIR/cq-preflight-result.json"

if echo "$stderr_t1" | grep -qE "unbound variable|Not a directory"; then
    assert_fail "T1: no 'unbound variable' or 'Not a directory' error" \
        "$stderr_t1"
else
    assert_pass "T1: no fatal env errors in cq_preflight_run"
fi

# ─── T2: cq_audit_plan_run writes audit-plan.json ───────────────────────────
set +e
stderr_t2="$(cq_audit_plan_run "cq-audit-plan" "$STATE_FILE" 2>&1)"
rc_t2=$?
set -e

assert_eq "T2: cq_audit_plan_run exits 0" "0" "$rc_t2"
assert_file_exists "T2: audit-plan.json written under artifacts/" \
    "$ARTIFACTS_DIR/audit-plan.json"

if echo "$stderr_t2" | grep -qE "unbound variable|Not a directory"; then
    assert_fail "T2: no 'unbound variable' or 'Not a directory' error" \
        "$stderr_t2"
else
    assert_pass "T2: no fatal env errors in cq_audit_plan_run"
fi

# ─── T3: cq_cycle_run writes review.findings.json and quality-feedback.md ───
set +e
stderr_t3="$(cq_cycle_run "cq-cycle" "$STATE_FILE" 2>&1)"
rc_t3=$?
set -e

assert_eq "T3: cq_cycle_run exits 0" "0" "$rc_t3"
assert_file_exists "T3: review.findings.json written under artifacts/" \
    "$ARTIFACTS_DIR/review.findings.json"
assert_file_exists "T3: quality-feedback.md written under artifacts/" \
    "$ARTIFACTS_DIR/quality-feedback.md"

if echo "$stderr_t3" | grep -qE "unbound variable|Not a directory"; then
    assert_fail "T3: no 'unbound variable' or 'Not a directory' error" \
        "$stderr_t3"
else
    assert_pass "T3: no fatal env errors in cq_cycle_run (ZBUILD_PLUGINS_ROOT unset)"
fi

# ─── T4: cq_cycle_cleanup does not error ────────────────────────────────────
set +e
stderr_t4="$(cq_cycle_cleanup "cq-cycle" "$STATE_FILE" 2>&1)"
rc_t4=$?
set -e

assert_eq "T4: cq_cycle_cleanup exits 0" "0" "$rc_t4"

# ─── T5: cq_backtrack_run writes cq-backtrack-result.json ───────────────────
set +e
stderr_t5="$(cq_backtrack_run "cq-backtrack" "$STATE_FILE" 2>&1)"
rc_t5=$?
set -e

assert_eq "T5: cq_backtrack_run exits 0" "0" "$rc_t5"
assert_file_exists "T5: cq-backtrack-result.json written under artifacts/" \
    "$ARTIFACTS_DIR/cq-backtrack-result.json"

if echo "$stderr_t5" | grep -qE "unbound variable|Not a directory"; then
    assert_fail "T5: no 'unbound variable' or 'Not a directory' error" \
        "$stderr_t5"
else
    assert_pass "T5: no fatal env errors in cq_backtrack_run"
fi

# ─── T6: golden snapshot — sorted artifact basenames ────────────────────────
actual_artifacts="$(find "$ARTIFACTS_DIR" -maxdepth 1 -type f \
    -exec basename {} \; 2>/dev/null | sort | tr '\n' '\n')"
actual_artifacts="$(printf '%s' "$actual_artifacts" | sort)"

GOLDEN_DIR="$REPO_ROOT/tests/golden"
if ! assert_golden "cq-plugins-real-dispatch-artifacts" "$actual_artifacts"; then
    assert_fail "T6: artifact golden snapshot matches" \
        "run with UPDATE_GOLDEN=1 to regenerate"
else
    assert_pass "T6: artifact golden snapshot matches expected basenames"
fi

cleanup_test_env
print_test_results
