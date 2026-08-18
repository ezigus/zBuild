#!/usr/bin/env bash
# [SPEC-14] Change-behavior: the four forbidden verdict strings must not appear in
# .verdict positions in any plugin primary output (ADR-054 §6 / issue #1832).
#
# This test greps core/, plugins/, and config/ for the pattern
#   "verdict"[[:space:]]*:[[:space:]]*"(did_not_finish|empty_diff|scope_too_large|inert_build)"
# and fails if any match is found. It is RED at the merge-base baseline (where
# all four strings appear in verdict positions) and GREEN after this migration.
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

# [SPEC-14] The forbidden strings must not appear in .verdict positions in
# any production source (core/ plugins/ config/). This assertion fails at the
# merge-base baseline where all four strings appeared as verdict values.
if [[ -z "$MATCHES" ]]; then
    assert_pass "[SPEC-14] no forbidden verdict strings in core/plugins/config (ADR-054 §6)"
else
    assert_fail "[SPEC-14] forbidden verdict strings found in .verdict positions — ADR-054 §6 violation" \
        "$MATCHES"
fi

print_test_results
cleanup_test_env
exit $((FAIL > 0))
