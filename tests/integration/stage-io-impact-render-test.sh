#!/usr/bin/env bash
# Integration (#768): impact plugin produces stage-io captures tagged with
# metadata.artifact=impact, AND the rendered terminal output shows the
# markdown header (Impact: verdict=..., missing=...) followed by the
# impact_feedback_md field — not the raw JSON envelope.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io: impact renderer dispatches via metadata.artifact (#768)"
setup_test_env "stage-io-impact-render"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# Synthesize the impact JSON envelope (matches plugins/agent/impact contract).
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"step-2","files_to_add":["tests/foo.sh"],"reason":"references modified symbol"}],"impact_feedback_md":"## Test Coverage Gaps\n- tests/foo.sh references `foo()` defined in step-2 files"}'

# T1: render_artifact with id=impact dispatches to render_impact_md
out="$(render_artifact "impact" "$impact_json")"
assert_contains "T1: render_artifact id=impact dispatches to impact renderer" "$out" "Impact: verdict=incomplete"
assert_contains "T1: renderer shows missing count" "$out" "missing=1"
assert_contains "T1: renderer renders impact_feedback_md as markdown" "$out" "## Test Coverage Gaps"
assert_contains "T1: renderer preserves the bullet body" "$out" "tests/foo.sh"

# T2: render_artifact with id=impact does NOT dump raw JSON (the bug we fixed)
case "$out" in
    *'"schema_version":1'*) assert_fail "T2: rendered output MUST NOT contain raw JSON envelope" "$out" ;;
    *) assert_pass "T2: raw JSON envelope NOT present in rendered output" ;;
esac

# T3: complete + empty feedback → header only (no spurious markdown body)
complete_json='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":""}'
out="$(render_artifact "impact" "$complete_json")"
assert_contains "T3: complete verdict header" "$out" "Impact: verdict=complete"
# Should not have any "## " heading when feedback is empty
case "$out" in
    *$'\n\n## '*) assert_fail "T3: empty feedback must not render body" "$out" ;;
    *) assert_pass "T3: complete with no gaps renders header-only" ;;
esac

# T4: producer-side tag is in the plugin source (parity with plan/review/test_assessment)
assert_contains "T4: impact plugin exports ZBUILD_ROUTER_ARTIFACT_ID=impact (#768)" \
    "$(cat "$REPO_ROOT/plugins/agent/impact/plugin.sh")" \
    "export ZBUILD_ROUTER_ARTIFACT_ID=impact"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
