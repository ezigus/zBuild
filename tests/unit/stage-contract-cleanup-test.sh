#!/usr/bin/env bash
# Tests: 843-I (#924) stage input-contract cleanup / independence.
#   V8 (behavioral): cq-backtrack recovery target is config-driven.
#   V1/V3/V4/V7 (contract): manifest declarations are honest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage input-contract cleanup (843-I #924)"
setup_test_env "stage-contract-cleanup"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
emit_event() { eb_emit_event "$@"; }
# shellcheck source=../../plugins/agent/cq-backtrack/plugin.sh
source "$REPO_ROOT/plugins/agent/cq-backtrack/plugin.sh"

_run_backtrack() {  # _run_backtrack → emits recovery.suggestion (needs_backtrack=true)
    local sd="$TEST_TEMP_DIR/bt-$RANDOM"; mkdir -p "$sd/artifacts"
    printf '{"needs_backtrack":true}' > "$sd/artifacts/review.findings.json"
    : > "$ZBUILD_EVENTS_JSONL"
    cq_backtrack_run "cq-backtrack" "$sd/pipeline-state.json" >/dev/null 2>&1 || true
}

# ── V8: default recovery target is design ─────────────────────────────────────
unset ZBUILD_BACKTRACK_TARGET_STAGE 2>/dev/null || true
_run_backtrack
tgt="$(jq -r 'select(.type=="recovery.suggestion") | .data.target_stage' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "V8: default recovery target_stage=design" "design" "$tgt"

# ── V8: config overrides the recovery target ──────────────────────────────────
ZBUILD_BACKTRACK_TARGET_STAGE="plan" _run_backtrack
tgt="$(jq -r 'select(.type=="recovery.suggestion") | .data.target_stage' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "V8: ZBUILD_BACKTRACK_TARGET_STAGE overrides target_stage" "plan" "$tgt"

# ── Manifest-contract assertions (honest declarations) ───────────────────────
_input_required() {  # _input_required <manifest> <input_id> → prints true|false|MISSING
    local val
    val="$(awk -v id="$2" '
        /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ { cur=$0; sub(/.*id:[[:space:]]*/,"",cur) }
        /^[[:space:]]*required:[[:space:]]*/ {
            if (cur==id) { r=$0; sub(/.*required:[[:space:]]*/,"",r); print r; exit }
        }
    ' "$1")"
    printf '%s' "${val:-MISSING}"
}

TA="$REPO_ROOT/plugins/agent/test_assessment/manifest.yaml"
if grep -q 'id: intake_baseline_ref' "$TA"; then
    assert_pass "V1: test_assessment declares intake_baseline_ref input (honest contract)"
else
    assert_fail "V1: test_assessment declares intake_baseline_ref" "not found in manifest"
fi
# V1: the intentional fail-closed (#847) is preserved in the plugin.
if grep -q 'fail-CLOSED' "$REPO_ROOT/plugins/agent/test_assessment/plugin.sh"; then
    assert_pass "V1: test_assessment fail-closed on missing baseline preserved"
else
    assert_fail "V1: fail-closed preserved" "fail-CLOSED path missing"
fi

assert_eq "V3: review plan input is required:false (degrades to diff-only)" \
    "false" "$(_input_required "$REPO_ROOT/plugins/agent/review/manifest.yaml" plan)"
assert_eq "V4: cq-audit-plan preflight_result is required:false (gate is external)" \
    "false" "$(_input_required "$REPO_ROOT/plugins/agent/cq-audit-plan/manifest.yaml" preflight_result)"

if grep -q 'id: diff_patch' "$REPO_ROOT/plugins/agent/security-lens/manifest.yaml"; then
    assert_fail "V7: security-lens no longer declares unused diff_patch" "still present"
else
    assert_pass "V7: security-lens no longer declares unused diff_patch input"
fi

cleanup_test_env
print_test_results  # exits with $FAIL
