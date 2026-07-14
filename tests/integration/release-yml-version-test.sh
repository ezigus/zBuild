#!/usr/bin/env bash
# Tests: .github/workflows/release.yml — VERSION file included in release PR commit
#
# SPEC-10: the 'git add' line in the open-release-pr job includes VERSION
#          (CHANGE: fails at baseline where only CHANGELOG.md docs/wiki README.md are staged)
# SPEC-11: VERSION appears before docs/wiki in the git add argument list
#          (ordering invariant — keeps the file list readable and deterministic)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.yml — VERSION included in release PR git add (#1483)"
setup_test_env "release-yml-version"

WORKFLOW_FILE="$REPO_ROOT/.github/workflows/release.yml"

# ── SPEC-10: git add in open-release-pr includes VERSION ─────────────────────
# Confirm VERSION is staged on the SAME git add command that stages CHANGELOG.md
# (unambiguously the open-release-pr staging line — not merely "VERSION appears
# somewhere after a git add token"). CHANGE-behavior spec: fails at baseline
# (VERSION missing from that line).
_spec10_version=false
if grep -qE "git add [^#]*\bCHANGELOG\.md\b[^#]*\bVERSION\b" "$WORKFLOW_FILE" 2>/dev/null; then
    _spec10_version=true
fi

if $_spec10_version; then
    assert_pass "[SPEC-10] open-release-pr git add includes VERSION"
else
    assert_fail "[SPEC-10] open-release-pr git add includes VERSION" \
        "Expected 'git add ... VERSION ...' in $WORKFLOW_FILE but VERSION was not found"
fi

# ── SPEC-11: VERSION appears before docs/wiki in the git add argument list ────
# Ordering invariant: CHANGELOG.md VERSION docs/wiki README.md
# grep for the exact expected ordering pattern.
_spec11_order=false
if grep -qE "git add CHANGELOG\.md VERSION docs/wiki" "$WORKFLOW_FILE" 2>/dev/null; then
    _spec11_order=true
fi

if $_spec11_order; then
    assert_pass "[SPEC-11] VERSION appears before docs/wiki in git add argument list"
else
    assert_fail "[SPEC-11] VERSION appears before docs/wiki in git add argument list" \
        "Expected 'git add CHANGELOG.md VERSION docs/wiki' ordering in $WORKFLOW_FILE"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
