#!/usr/bin/env bash
# Tests: impact plugin has no hardcoded artifact path constructions (#1838).
# SPEC-8 [change]: plugins/agent/impact/plugin.sh contains no hardcoded
#                  artifact path constructions — no string literals of the form
#                  artifacts_dir/design.md, state_dir/scope-manifest.md, etc.
#                  built by the plugin. Every input path comes from the engine's
#                  index (ZBUILD_STAGE_INPUTS); the plugin never derives one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "impact: no hardcoded artifact path constructions (#1838/SPEC-8)"
setup_test_env "impact-no-path-construction"

_PLUGIN="$REPO_ROOT/plugins/agent/impact/plugin.sh"

# Each pattern below matches a string literal that constructs an artifact path
# inside the plugin: <dir_var>/<known_filename>.  These are the constructions
# that must be removed when inputs are read from ZBUILD_STAGE_INPUTS instead of
# derived from state_file.

# artifacts_dir/design.md — v1 path construction for the design input.
if grep -qE 'artifacts_dir[/]design\.md|artifacts_dir/design\.md' "$_PLUGIN" 2>/dev/null; then
    assert_fail "[#1838/SPEC-8] no 'artifacts_dir/design.md' literal in plugin.sh" \
        "found hardcoded path construction: artifacts_dir/design.md"
else
    assert_pass "[#1838/SPEC-8] no 'artifacts_dir/design.md' literal in plugin.sh"
fi

# state_dir/scope-manifest.md — v1 path construction for the scope-manifest input.
if grep -qE 'state_dir[/]scope-manifest\.md|state_dir/scope-manifest\.md' "$_PLUGIN" 2>/dev/null; then
    assert_fail "[#1838/SPEC-8] no 'state_dir/scope-manifest.md' literal in plugin.sh" \
        "found hardcoded path construction: state_dir/scope-manifest.md"
else
    assert_pass "[#1838/SPEC-8] no 'state_dir/scope-manifest.md' literal in plugin.sh"
fi

# artifacts_dir/plan.json — v1 path construction for the plan input.
if grep -qE 'artifacts_dir[/]plan\.json|artifacts_dir/plan\.json' "$_PLUGIN" 2>/dev/null; then
    assert_fail "[#1838/SPEC-8] no 'artifacts_dir/plan.json' literal in plugin.sh" \
        "found hardcoded path construction: artifacts_dir/plan.json"
else
    assert_pass "[#1838/SPEC-8] no 'artifacts_dir/plan.json' literal in plugin.sh"
fi

# state_dir/artifacts — broad guard: the plugin must not derive an artifact dir
# from its state_file argument at all.  The engine sets ZBUILD_ARTIFACT_DIR.
if grep -qE 'state_dir/artifacts|state_dir\}/artifacts' "$_PLUGIN" 2>/dev/null; then
    assert_fail "[#1838/SPEC-8] no 'state_dir/artifacts' path construction in plugin.sh" \
        "found hardcoded artifact dir construction from state_dir"
else
    assert_pass "[#1838/SPEC-8] no 'state_dir/artifacts' path construction in plugin.sh"
fi

# Broader guard: no state_dir derived from state_file (v1 pattern: state_dir=$(dirname …)).
if grep -qE 'state_dir.*dirname.*state_file|dirname.*state_file.*state_dir' "$_PLUGIN" 2>/dev/null; then
    assert_fail "[#1838/SPEC-8] no state_dir derived from state_file in plugin.sh" \
        "found state_file-derived path construction (v1 calling-convention)"
else
    assert_pass "[#1838/SPEC-8] no state_dir derived from state_file in plugin.sh"
fi

# Broader guard: no $state_dir/<path> construction of any filename.
if grep -qE '\$\{?state_dir\}?/' "$_PLUGIN" 2>/dev/null; then
    assert_fail "[#1838/SPEC-8] no \$state_dir/ path constructions in plugin.sh" \
        "found \$state_dir/<path> construction — plugin must not derive paths from state_file"
else
    assert_pass "[#1838/SPEC-8] no \$state_dir/ path constructions in plugin.sh"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
