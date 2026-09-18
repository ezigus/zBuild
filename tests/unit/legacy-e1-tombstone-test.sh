#!/usr/bin/env bash
# Guard: keeper e-1 (live-updating GitHub comment, PATCH, atomic id) is
# migrated by #2131, and the pruning protocol (docs/KEEPERS.md) says what that
# means on disk: the legacy source is gone, a tombstone names the new home,
# and every doc that cited the legacy path points at the tombstone or the
# new lib — so the claim "migrated" stays checkable (the #2034 rule).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "keeper e-1 tombstone (#2131)"

TOMB="$REPO_ROOT/legacy/migrated/e-1.md"
assert_file_exists "[SPEC-1] legacy/migrated/e-1.md exists" "$TOMB"
assert_contains "[SPEC-1] tombstone names the new lib" "$(cat "$TOMB" 2>/dev/null)" 'scripts/lib/run-status-comment.sh'
assert_contains "[SPEC-1] tombstone links the issue" "$(cat "$TOMB" 2>/dev/null)" '#2131'
assert_contains "[SPEC-1] tombstone names the legacy source it replaces" "$(cat "$TOMB" 2>/dev/null)" 'legacy/scripts/lib/pipeline-github.sh'

assert_file_not_exists "[SPEC-2] the legacy source is removed" "$REPO_ROOT/legacy/scripts/lib/pipeline-github.sh"

# Docs that cited the legacy path now cite the migration, not a file that is gone.
# A mention of the removed path is fine only when the same line says where it went.
assert_eq "[SPEC-3] every KEEPERS.md mention of the removed path points at the tombstone" "0" \
    "$(grep 'legacy/scripts/lib/pipeline-github.sh' "$REPO_ROOT/docs/KEEPERS.md" | grep -vc 'legacy/migrated/e-1.md')"
assert_contains "[SPEC-3] docs/KEEPERS.md points at the tombstone" "$(cat "$REPO_ROOT/docs/KEEPERS.md")" 'legacy/migrated/e-1.md'
assert_eq "[SPEC-3] ADR-010 no longer cites pipeline-github.sh" "0" \
    "$(grep -c 'pipeline-github.sh' "$REPO_ROOT/docs/adr/ADR-010-ci-cli-parity.md")"
assert_contains "[SPEC-3] ADR-010's destination row names the new lib" \
    "$(cat "$REPO_ROOT/docs/adr/ADR-010-ci-cli-parity.md")" 'run-status-comment.sh'

print_test_results
exit $((FAIL > 0))
