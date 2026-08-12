#!/usr/bin/env bash
# Integration test (#782 + #937): impact plugin handles router failures
# gracefully (never returns rc=1 with a missing artifact).
#
# #937 amends #782: a TIMEOUT (rc=124) is RECOVERABLE — impact writes a
# best-effort verdict=incomplete (re-iterate) instead of an empty verdict=error,
# mirroring #892's rc=1 handling. reason=router_timeout is preserved in the
# plugin.result event AND the impact.json reason for postmortems. Genuine
# infra errors (OOM rc=137) keep verdict=error so the cycle blocked-predicate
# can flag them.
#
# Pinned assertions:
#   I1: rc=124 → plugin returns rc=0 (graceful)
#   I2: rc=124 → impact.json verdict=incomplete (best-effort), reason=router_timeout
#   I3: plugin.result event emitted with reason=router_timeout
#   I4: impact.verdict.incomplete event emitted (cycle re-iterates with signal)
#   I5: rc=1 (max_turns) → best-effort verdict=incomplete (#892)
#   I6: rc=137 (OOM) → verdict=error (error class preserved for genuine infra fail)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact router rc=124 → best-effort incomplete (#937); rc=137 → error (#782)"
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

# #842: impact reads design.md's ```scope block; signature is now
# <scope_manifest> <design_md> <plan_json> <impact_out> [artifact_dir].
DESIGN_MD="$ARTIFACTS/design.md"
printf '# Design\n\n```scope\nplugins/agent/foo/plugin.sh\n```\n' > "$DESIGN_MD"

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
_impact_run_inner "$SCOPE_MANIFEST" "$DESIGN_MD" "$PLAN_JSON" "$IMPACT_OUT" "$ARTIFACTS" || rc=$?

assert_eq "I1: plugin returns rc=0 on rc=124 (graceful error class)" "0" "$rc"
assert_file_exists "I2: impact.json written" "$IMPACT_OUT"

verdict="$(jq -r '.verdict' "$IMPACT_OUT" 2>/dev/null)"
assert_eq "I2: rc=124 → verdict=incomplete (best-effort, re-iterate)" "incomplete" "$verdict"

reason="$(jq -r '.reason // empty' "$IMPACT_OUT" 2>/dev/null)"
assert_eq "I2: reason=router_timeout preserved in artifact" "router_timeout" "$reason"

_i2_fb="$(jq -r '.impact_feedback_md // ""' "$IMPACT_OUT" 2>/dev/null)"
if [[ -n "${_i2_fb//[[:space:]]/}" ]]; then
    assert_pass "I2: best-effort note present (re-iterate signal)"
else
    assert_fail "I2: impact_feedback_md should carry a best-effort note"
fi

events="$(cat "$ZBUILD_EVENTS_JSONL")"
case "$events" in
    *'"type":"plugin.result"'*'"reason":"router_timeout"'*)
        assert_pass "I3: plugin.result reason=router_timeout emitted" ;;
    *)
        assert_fail "I3: plugin.result event missing reason=router_timeout: $events" ;;
esac

case "$events" in
    *'"type":"impact.verdict.incomplete"'*)
        assert_pass "I4: impact.verdict.incomplete emitted (cycle re-iterates)" ;;
    *)
        assert_fail "I4: impact.verdict.incomplete event NOT emitted" ;;
esac

# ─── I5 (#892): rc=1 (max_turns/non-timeout) → best-effort verdict=incomplete ─
# Was fail-closed (rc=1, no impact.json). Now impact NEVER returns empty on a
# router failure: it writes verdict=incomplete + a best-effort feedback note so
# the cycle re-iterates (another shot) instead of getting a missing artifact.
route_to_model() { return 1; }
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$IMPACT_OUT"

rc=0
_impact_run_inner "$SCOPE_MANIFEST" "$DESIGN_MD" "$PLAN_JSON" "$IMPACT_OUT" "$ARTIFACTS" || rc=$?

assert_eq "I5: plugin returns rc=0 (best-effort, not fail-closed)" "0" "$rc"
assert_file_exists "I5: impact.json written (never empty)" "$IMPACT_OUT"
assert_eq "I5: verdict=incomplete" "incomplete" "$(jq -r '.verdict' "$IMPACT_OUT" 2>/dev/null)"
_i5_fb="$(jq -r '.impact_feedback_md // ""' "$IMPACT_OUT" 2>/dev/null)"
if [[ -n "${_i5_fb//[[:space:]]/}" ]]; then
    assert_pass "I5: impact_feedback_md is a non-empty best-effort note"
else
    assert_fail "I5: impact_feedback_md should carry a best-effort note"
fi
case "$(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null)" in
    *'"type":"impact.verdict.incomplete"'*) assert_pass "I5: impact.verdict.incomplete emitted" ;;
    *) assert_fail "I5: impact.verdict.incomplete event NOT emitted" ;;
esac

# ─── I6 (#782 preserved): rc=137 (OOM) → verdict=error (genuine infra failure) ─
# A timeout is recoverable (best-effort incomplete); an OOM kill is a genuine
# infra error and keeps the verdict=error class so the cycle can flag it.
route_to_model() { return 137; }
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$IMPACT_OUT"
rc=0
_impact_run_inner "$SCOPE_MANIFEST" "$DESIGN_MD" "$PLAN_JSON" "$IMPACT_OUT" "$ARTIFACTS" || rc=$?
assert_eq "I6: rc=137 plugin returns rc=0 (graceful)" "0" "$rc"
assert_eq "I6: rc=137 (OOM) → verdict=error (error class preserved, not best-effort)" \
    "error" "$(jq -r '.verdict' "$IMPACT_OUT" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
