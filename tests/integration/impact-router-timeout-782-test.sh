#!/usr/bin/env bash
# Integration test (#782): impact plugin handles router rc=124 (gtimeout) by
# writing impact.json with verdict=error reason=router_timeout, NOT
# returning rc=1 from the plugin (which would collapse error class into fail).
#
# Pinned assertions:
#   I1: rc=124 → plugin returns rc=0 (graceful)
#   I2: impact.json written with verdict=error reason=router_timeout
#   I3: plugin.run.error event emitted with reason=router_timeout
#   I4: impact.verdict.error event emitted for cycle predicate consumption
#   I5: rc=1 (other) → plugin returns rc=1 (existing fail-closed contract preserved)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact router rc=124 → verdict=error (#782)"
setup_test_env "impact-router-timeout-782"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

ARTIFACTS="$TEST_TEMP_DIR/state/artifacts"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ARTIFACTS"

SCOPE_MANIFEST="$STATE_DIR/scope-manifest.md"
echo "+ ./" > "$SCOPE_MANIFEST"

PLAN_JSON="$ARTIFACTS/plan.json"
echo '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["plugins/agent/foo/plugin.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$PLAN_JSON"

# Empty prefilter env so #781 is no-op in these tests.
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/empty-root"; mkdir -p "$ZBUILD_REPO_ROOT/config"

# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$REPO_ROOT/plugins/agent/impact/plugin.sh"

apply_scope_redaction() { cp "$1" "$2"; return 0; }

# ─── I1+I2+I3+I4: rc=124 timeout path ───────────────────────────────────────
route_to_model() { return 124; }
: > "$ZBUILD_EVENTS_JSONL"
IMPACT_OUT="$ARTIFACTS/impact.json"
rm -f "$IMPACT_OUT"

rc=0
_impact_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$IMPACT_OUT" "$ARTIFACTS" || rc=$?

assert_eq "I1: plugin returns rc=0 on rc=124 (graceful error class)" "0" "$rc"
assert_file_exists "I2: impact.json written" "$IMPACT_OUT"

verdict="$(jq -r '.verdict' "$IMPACT_OUT" 2>/dev/null)"
assert_eq "I2: verdict=error" "error" "$verdict"

reason="$(jq -r '.reason // empty' "$IMPACT_OUT" 2>/dev/null)"
assert_eq "I2: reason=router_timeout" "router_timeout" "$reason"

events="$(cat "$ZBUILD_EVENTS_JSONL")"
case "$events" in
    *'"type":"plugin.run.error"'*'"reason":"router_timeout"'*)
        assert_pass "I3: plugin.run.error reason=router_timeout emitted" ;;
    *)
        assert_fail "I3: plugin.run.error event missing reason=router_timeout: $events" ;;
esac

case "$events" in
    *'"type":"impact.verdict.error"'*)
        assert_pass "I4: impact.verdict.error event emitted (cycle predicate)" ;;
    *)
        assert_fail "I4: impact.verdict.error event NOT emitted" ;;
esac

# ─── I5: rc=1 (non-timeout) preserves existing fail-closed contract ─────────
route_to_model() { return 1; }
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$IMPACT_OUT"

rc=0
_impact_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$IMPACT_OUT" "$ARTIFACTS" || rc=$?

assert_eq "I5: plugin returns rc=1 on rc=1 (fail class)" "1" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
