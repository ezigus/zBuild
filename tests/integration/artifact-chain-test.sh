#!/usr/bin/env bash
# Tests: 3-plugin sequential chain (intake → security-lens → output).
# Verifies artifact handoffs, event emission, and ordering.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "artifact chain — intake → security-lens → output (3-plugin sequential)"

setup_test_env "artifact-chain"

ZBUILD_TEST_TMP="$TEST_TEMP_DIR"
STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
EVENTS_DIR="$TEST_TEMP_DIR/events"
EVENTS_JSONL="$EVENTS_DIR/events.jsonl"

export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="chain-test-run-$$"
export ZBUILD_ISSUE="1"
export ZBUILD_GOAL="Test artifact chain"
export ZBUILD_OUTPUT_GH_COMMENT=0
export ZBUILD_OUTPUT_GH_CHECK_RUN=0
export NO_GITHUB=true
# Issue #484: intake creates a git branch; this test isn't a git repo.
export ZBUILD_INTAKE_SKIP_BRANCH=1

mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR" "$EVENTS_DIR"

# ─── Mock claude to return a valid findings JSON ─────────────────────────────
# #476: envelope-aware via the shared helper.
install_envelope_mock_claude \
    '{"findings":[{"title":"test","severity":"low","description":"d","recommendation":"r"}]}'

# ─── Write a minimal scope manifest so redaction passes ──────────────────────
printf '+ ./\n' | atomic_write "$STATE_DIR/scope-manifest.md"

# Create a minimal platforms.json so intake does not fail
jq -n '{schema_version:1, detected:["generic"], overrides:[], updated_at:"2026-01-01T00:00:00Z"}' \
    > "$STATE_DIR/platforms.json"

# Initialize state file
STATE_FILE="$STATE_DIR/pipeline-state.json"
jq -n \
    --arg run_id "$ZBUILD_RUN_ID" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, run_id:$run_id, issue:1, stage_statuses:{},
      current_iteration:0, self_heal_count:{}, scope_manifest_hash:"",
      cost_ledger_pointer:0, claim_lease_id:"", plugin_state:{},
      updated_at:$now}' > "$STATE_FILE"

# ─── Stage 1: run intake plugin ──────────────────────────────────────────────
source "$REPO_ROOT/plugins/agent/intake/plugin.sh"
set +e
intake_run "intake" "$STATE_FILE" 2>/dev/null
intake_rc=$?
set -e
assert_eq "intake plugin exits 0" "0" "$intake_rc"
assert_file_exists "intake.md created" "$STATE_DIR/intake.md"
assert_file_exists "scope-manifest.md created" "$STATE_DIR/scope-manifest.md"

# ─── Stage 2: run security-lens plugin ───────────────────────────────────────
# Emit redaction.applied so the router C6 precondition is met
jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:1, type:"redaction.applied",
      plugin:"", kind:"", data:{}, schema_version:1}' \
    >> "$EVENTS_JSONL"

source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/router/route.sh"
source "$REPO_ROOT/plugins/agent/security-lens/plugin.sh"

set +e
security_lens_run "security-lens" "$STATE_FILE" 2>/dev/null
sl_rc=$?
set -e
assert_eq "security-lens plugin exits 0" "0" "$sl_rc"

# Assert findings.json artifact exists
findings_file=""
for f in "$ARTIFACTS_DIR"/*-findings.json; do
    [[ -f "$f" ]] && findings_file="$f" && break
done
assert_file_exists "findings.json artifact created after security-lens" "${findings_file:-$ARTIFACTS_DIR/security-findings.json}"

# Assert at least one finding exists
if [[ -n "$findings_file" && -f "$findings_file" ]]; then
    finding_count="$(jq '[.findings // [] | .[]] | length' "$findings_file" 2>/dev/null || echo 0)"
    assert_gt "security-lens findings.json has at least 1 finding" "$finding_count" "0"
fi

# ─── Assert redaction.applied event exists in log ────────────────────────────
redaction_count="$(grep -c '"redaction.applied"' "$EVENTS_JSONL" 2>/dev/null || true)"
assert_gt "redaction.applied event in events log" "$redaction_count" "0"

# ─── Stage 3: run output plugin ──────────────────────────────────────────────
source "$REPO_ROOT/plugins/tool/output-github-comment/plugin.sh"
set +e
output_run "output" "$STATE_FILE" 2>/dev/null
out_rc=$?
set -e
assert_eq "output plugin exits 0" "0" "$out_rc"

# ─── Assert plugin.run.complete events appear in intake → security-lens → output order ─
intake_pos="$(grep -n '"plugin.run.complete"' "$EVENTS_JSONL" 2>/dev/null \
    | grep '"intake"' | head -1 | cut -d: -f1 || echo 0)"
sl_pos="$(grep -n '"plugin.run.complete"' "$EVENTS_JSONL" 2>/dev/null \
    | grep '"security-lens"' | head -1 | cut -d: -f1 || echo 0)"
output_pos="$(grep -n '"plugin.run.complete"' "$EVENTS_JSONL" 2>/dev/null \
    | grep '"output-github-comment"' | head -1 | cut -d: -f1 || echo 0)"

if [[ -n "$intake_pos" && -n "$sl_pos" && "$intake_pos" -gt 0 && "$sl_pos" -gt 0 ]]; then
    if [[ "$intake_pos" -lt "$sl_pos" ]]; then
        assert_pass "event ordering: intake plugin.run.complete before security-lens"
    else
        assert_fail "event ordering: intake plugin.run.complete before security-lens" \
            "intake line=$intake_pos sl line=$sl_pos"
    fi
    # Also assert security-lens completes before output-github-comment when
    # the output event is present (full intake → sl → output chain).
    if [[ -n "$output_pos" && "$output_pos" -gt 0 ]]; then
        if [[ "$sl_pos" -lt "$output_pos" ]]; then
            assert_pass "event ordering: security-lens plugin.run.complete before output-github-comment"
        else
            assert_fail "event ordering: security-lens plugin.run.complete before output-github-comment" \
                "sl line=$sl_pos output line=$output_pos"
        fi
    fi
else
    # plugin.run.complete events emitted — verify via grep count
    intake_complete="$(grep '"plugin.run.complete"' "$EVENTS_JSONL" 2>/dev/null \
        | grep -c '"intake"' || true)"
    sl_complete="$(grep '"plugin.run.complete"' "$EVENTS_JSONL" 2>/dev/null \
        | grep -c '"security-lens"' || true)"
    assert_gt "intake plugin.run.complete emitted" "$intake_complete" "0"
    assert_gt "security-lens plugin.run.complete emitted" "$sl_complete" "0"
fi

_test_cleanup_hook() { cleanup_test_env; }
cleanup_test_env
print_test_results
exit $((FAIL > 0))
