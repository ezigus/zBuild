#!/usr/bin/env bash
# Tests: 3-plugin sequential chain (intake → the security review lens → output).
# #2548: the middle stage was the security-lens plugin, which no template ran; it
# is now the review-lens stage running as its security lens.
# Verifies artifact handoffs, event emission, and ordering.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "artifact chain — intake → review-lens (security) → output (3-plugin sequential)"

setup_test_env "artifact-chain"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

ZBUILD_TEST_TMP="$TEST_TEMP_DIR"
STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
EVENTS_DIR="$TEST_TEMP_DIR/events"
EVENTS_JSONL="$EVENTS_DIR/events.jsonl"

export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="chain-test-run-$$"
export ZBUILD_ISSUE="$_ZB_ID"
export ZBUILD_GOAL="Test artifact chain"
export ZBUILD_OUTPUT_GH_COMMENT=0
export ZBUILD_OUTPUT_GH_CHECK_RUN=0
export NO_GITHUB=true

mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR" "$EVENTS_DIR"

# ─── Mock claude to return a valid findings JSON ─────────────────────────────
# #476: envelope-aware via the shared helper.
# A lens finding quotes a real line of a real file (ADR-072 §3).
install_envelope_mock_claude \
    '{"score":8,"findings":[{"file":"scripts/lib/helpers.sh","category":"injection","severity":"low","message":"m","quote":"_ZBUILD_HELPERS_LOADED=1","trigger":"a caller sources helpers.sh twice","introduced":false,"fix":"code"}]}'

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
# The engine names every stage's artifact dir (core/plugin-registry/lifecycle.sh);
# intake no longer guesses one beside the state file (#1837).
export ZBUILD_ARTIFACT_DIR="$STATE_DIR/artifacts"
source "$REPO_ROOT/plugins/agent/intake/plugin.sh"
set +e
intake_run "intake" "$STATE_FILE" 2>/dev/null
intake_rc=$?
set -e
assert_eq "intake plugin exits 0" "0" "$intake_rc"
assert_file_exists "intake.md created" "$STATE_DIR/intake.md"
assert_file_exists "scope-manifest.md created" "$STATE_DIR/scope-manifest.md"

# ─── Stage 2: run the security review lens ───────────────────────────────────
# Emit redaction.applied so the router C6 precondition is met
jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:1, type:"redaction.applied",
      plugin:"", kind:"", data:{}, schema_version:1}' \
    >> "$EVENTS_JSONL"

source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/router/route.sh"
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"

set +e
( export ZBUILD_MAP_ELEMENT=security ZBUILD_REVIEW_LENS_ID=security ZBUILD_REPO_ROOT="$REPO_ROOT"
  cd "$REPO_ROOT" && review_lens_run "review-lens" "$STATE_FILE" ) 2>/dev/null
sl_rc=$?
set -e
assert_eq "review-lens (security) exits 0" "0" "$sl_rc"

# Assert the lens's result artifact exists
findings_file="$ARTIFACTS_DIR/lens-security.json"
assert_file_exists "lens-security.json artifact created after the security lens" "$findings_file"

# Assert at least one finding exists
if [[ -f "$findings_file" ]]; then
    finding_count="$(jq '[.findings // [] | .[]] | length' "$findings_file" 2>/dev/null || echo 0)"
    assert_gt "lens-security.json has at least 1 finding" "$finding_count" "0"
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

# ─── Assert plugin.result events appear in intake → review-lens → output order ─
intake_pos="$(grep -n '"plugin.result"' "$EVENTS_JSONL" 2>/dev/null \
    | grep '"intake"' | head -1 | cut -d: -f1 || echo 0)"
sl_pos="$(grep -n '"plugin.result"' "$EVENTS_JSONL" 2>/dev/null \
    | grep '"review-lens"' | head -1 | cut -d: -f1 || echo 0)"
output_pos="$(grep -n '"plugin.result"' "$EVENTS_JSONL" 2>/dev/null \
    | grep '"output-github-comment"' | head -1 | cut -d: -f1 || echo 0)"

if [[ -n "$intake_pos" && -n "$sl_pos" && "$intake_pos" -gt 0 && "$sl_pos" -gt 0 ]]; then
    if [[ "$intake_pos" -lt "$sl_pos" ]]; then
        assert_pass "[SPEC-2] event ordering: intake plugin.result before review-lens"
    else
        assert_fail "event ordering: intake plugin.result before review-lens" \
            "intake line=$intake_pos sl line=$sl_pos"
    fi
    # Also assert review-lens completes before output-github-comment when
    # the output event is present (full intake → sl → output chain).
    if [[ -n "$output_pos" && "$output_pos" -gt 0 ]]; then
        if [[ "$sl_pos" -lt "$output_pos" ]]; then
            assert_pass "event ordering: review-lens plugin.result before output-github-comment"
        else
            assert_fail "event ordering: review-lens plugin.result before output-github-comment" \
                "sl line=$sl_pos output line=$output_pos"
        fi
    fi
else
    # plugin.result events emitted — verify via grep count
    intake_complete="$(grep '"plugin.result"' "$EVENTS_JSONL" 2>/dev/null \
        | grep -c '"intake"' || true)"
    sl_complete="$(grep '"plugin.result"' "$EVENTS_JSONL" 2>/dev/null \
        | grep -c '"review-lens"' || true)"
    assert_gt "intake plugin.result emitted" "$intake_complete" "0"
    assert_gt "review-lens plugin.result emitted" "$sl_complete" "0"
fi

_test_cleanup_hook() { cleanup_test_env; }
cleanup_test_env
print_test_results
exit $((FAIL > 0))
