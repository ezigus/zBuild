#!/usr/bin/env bash
# [SPEC-14] Change-behavior: the four forbidden verdict strings must not appear in
# .verdict positions in any plugin primary output (ADR-054 §6 / issue #1832).
#
# This test greps core/, plugins/, and config/ for the pattern
#   "verdict"[[:space:]]*:[[:space:]]*"(did_not_finish|empty_diff|scope_too_large|inert_build)"
# and fails if any match is found.
#
# Scope of the evidence this provides, stated honestly: at the merge-base the
# pattern matches exactly ONE line — design/plugin.sh's did_not_finish sidecar,
# the only one of the four ever written as a JSON verdict literal. The other
# three reached the verdict channel through shell assignment
# (`build_verdict="empty_diff"`) or a manifest valid_verdicts entry, neither of
# which a JSON-literal regex can see. So this guard reddens on one string, not
# four, and the load-bearing evidence for the rest is SPEC-1..SPEC-10 plus
# lint-verdict-classify (which pins every manifest's declared verdicts).
# Widening this to cover the assignment and manifest surfaces would make the
# SPEC self-sufficient; see the #1832 PR discussion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "verdict-no-forbidden-strings guard (#1832, ADR-054)"
setup_test_env "verdict-no-forbidden-strings-guard"

# The four strings that must never appear as .verdict values in primary
# plugin outputs (build-summary.json, design-verdict.json).
# They describe *how the stage ran*, not *what the stage found in the code*.
PATTERN='"verdict"[[:space:]]*:[[:space:]]*"(did_not_finish|empty_diff|scope_too_large|inert_build)"'

# Search scope: plugin implementations + config + core pipeline.
# Exclude test fixtures and test files themselves (they are allowed to
# reference old strings when testing the migration boundary or as comments).
SEARCH_DIRS=("$REPO_ROOT/core" "$REPO_ROOT/plugins" "$REPO_ROOT/config")

MATCHES=""
for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        found="$(grep -rE "$PATTERN" "$dir" \
            --include="*.sh" --include="*.json" --include="*.yaml" \
            2>/dev/null || true)"
        if [[ -n "$found" ]]; then
            MATCHES="${MATCHES}${found}"$'\n'
        fi
    fi
done

# [SPEC-14] Change-behavior: the forbidden strings must not appear in .verdict
# positions in any production source after the migration. Fails at merge-base
# (where all four appear in verdict positions) and passes after migration.
assert_eq "[SPEC-14] no forbidden verdict strings in core/plugins/config (ADR-054 §6)" \
    "" "$MATCHES"

print_test_results
cleanup_test_env
exit $((FAIL > 0))
