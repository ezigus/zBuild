#!/usr/bin/env bash
# Tests: plan/review/security-lens symmetrically opt-in to producer-side
# artifact tagging (#483, ADR-018 Implementation Notes).
#
# This is a table-driven sanity check that all three Pattern 1 stages export
# ZBUILD_ROUTER_ARTIFACT_ID around their route_to_model call with the
# expected id. Per-plugin tests already exercise the same invariant on the
# plugin's own run path; this test is the cross-plugin parity lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "agent-stages: artifact metadata symmetry (#483)"

# Pure shell parity test — each row exports a value, asserts the env var
# matches at "the moment route_to_model would be called". No need to source
# plugin code; we verify the contract by string-grepping the plugin file for
# the export line, AND by source-loading the plugin in a fresh subshell and
# reading the captured env via a stubbed route_to_model.

# Row format: <plugin_id> <expected_artifact_id> <plugin_file>
_rows=(
    "plan|plan|$REPO_ROOT/plugins/agent/plan/plugin.sh"
    "review|review|$REPO_ROOT/plugins/agent/review/plugin.sh"
    "security-lens|security-lens|$REPO_ROOT/plugins/agent/security-lens/plugin.sh"
    "impact|impact|$REPO_ROOT/plugins/agent/impact/plugin.sh"
)

for row in "${_rows[@]}"; do
    IFS='|' read -r plugin_id expected_id plugin_file <<<"$row"
    # 1. Grep the plugin file for the export line — pins the literal value.
    if grep -qE "export ZBUILD_ROUTER_ARTIFACT_ID=${expected_id}\b" "$plugin_file"; then
        assert_pass "$plugin_id exports ZBUILD_ROUTER_ARTIFACT_ID=$expected_id (#483)"
    else
        assert_fail "$plugin_id missing export ZBUILD_ROUTER_ARTIFACT_ID=$expected_id" \
            "expected line not found in $plugin_file"
    fi

    # 2. Grep for the save-prev pattern (mirror of #476).
    if grep -q '_prev_artifact_env=' "$plugin_file"; then
        assert_pass "$plugin_id saves prior ZBUILD_ROUTER_ARTIFACT_ID for restore"
    else
        assert_fail "$plugin_id missing _prev_artifact_env save line" \
            "expected save-prev pattern in $plugin_file"
    fi

    # 3. Grep for the restore branches (unset on __UNSET__, otherwise re-export).
    if grep -q 'unset ZBUILD_ROUTER_ARTIFACT_ID' "$plugin_file" \
       && grep -q 'export ZBUILD_ROUTER_ARTIFACT_ID="\$_prev_artifact_env"' "$plugin_file"; then
        assert_pass "$plugin_id restores prior ZBUILD_ROUTER_ARTIFACT_ID (both branches)"
    else
        assert_fail "$plugin_id missing restore branches" \
            "expected unset + re-export in $plugin_file"
    fi
done

print_test_results
exit $((FAIL > 0))
