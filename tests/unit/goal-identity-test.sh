#!/usr/bin/env bash
# Tests: --goal runs get an on-disk identity of their own (#1931, ADR-059 §5).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/identity.sh
source "$REPO_ROOT/scripts/lib/identity.sh"

print_test_header "--goal run identity (#1931)"
setup_test_env "zb-goal-identity"

# ─── [SPEC-1][change] two different goals get two different keys ────────────
# The defect this removes: every --goal run shared `issue-0`. Under ADR-059's
# issue-keyed layout that is ONE worktree and ONE artifacts dir for unrelated
# goals — and zbuild_worktree_acquire creates-or-REUSES, so it would not refuse,
# it would hand the second run the first one's tree with the first one's branch
# checked out (#1640's defect class).
print_test_section "[SPEC-1][change] distinct goals are distinct identities"

_k1="$(zbuild_run_key 0 'add a retry to the uploader')"
_k2="$(zbuild_run_key 0 'rewrite the parser')"
assert_contains "[SPEC-1] a goal key is namespaced as goal-" "$_k1" "goal-"
if [[ "$_k1" == "$_k2" ]]; then
    assert_fail "[SPEC-1] two different goals must not share a key" "$_k1"
else
    assert_pass "[SPEC-1] two different goals get different keys"
fi

# The same goal re-run MUST reuse its key — that is what gives a goal run
# prior-work reuse for the first time.
assert_eq "[SPEC-1] the same goal re-run resolves to the same key" \
    "$_k1" "$(zbuild_run_key 0 'add a retry to the uploader')"

# And an issue still wins outright.
assert_eq "[SPEC-1] an issue number takes precedence over goal text" \
    "issue-1931" "$(zbuild_run_key 1931 'some goal text')"

# ─── [SPEC-2][guard] reflowing a goal does not orphan its prior work ───────
print_test_section "[SPEC-2][guard] the key is whitespace-insensitive"

assert_eq "[SPEC-2] reflowed goal text keeps the same key" \
    "$(zbuild_run_key 0 'add a retry to the uploader')" \
    "$(zbuild_run_key 0 'add   a retry
       to the uploader')"

# ─── [SPEC-3][guard] no identity is refused, never invented ───────────────
# A run with neither an issue nor a goal has no identity. Returning something
# would key unrelated work together, which is the defect being removed.
print_test_section "[SPEC-3][guard] neither issue nor goal is a refusal"

_rc=0; _out="$(zbuild_run_key 0 '')" || _rc=$?
assert_exit_code "[SPEC-3] no issue and no goal is refused" "1" "$_rc"
assert_eq "[SPEC-3] and echoes nothing" "" "$_out"
_rc=0; zbuild_run_key 0 '   ' >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-3] whitespace-only goal is refused too" "1" "$_rc"

# ─── [SPEC-4][change] the branch name carries the identity ────────────────
print_test_section "[SPEC-4][change] a goal run's branch is not zbuild/issue-0-*"

# shellcheck source=../../plugins/agent/intake/lib/branch-names.sh
source "$REPO_ROOT/plugins/agent/intake/lib/branch-names.sh"

_b_issue="$(_intake_derive_branch_name 1931 'Add a retry')"
assert_eq "[SPEC-4] an issue branch is unchanged" \
    "zbuild/issue-1931-add-a-retry" "$_b_issue"

_b_goal="$(ZBUILD_GOAL='add a retry to the uploader' _intake_derive_branch_name 0 'Add a retry')"
assert_contains "[SPEC-4] a goal branch carries the goal key" "$_b_goal" "zbuild/goal-"
if [[ "$_b_goal" == *"issue-0"* ]]; then
    assert_fail "[SPEC-4] a goal branch must not be zbuild/issue-0-*" "$_b_goal"
else
    assert_pass "[SPEC-4] a goal branch is no longer zbuild/issue-0-*"
fi

# Two goals with the SAME title produce different branches — the title is not
# the identity, the goal text is. Without this the slug alone could collide.
_b_a="$(ZBUILD_GOAL='goal alpha' _intake_derive_branch_name 0 'Same Title')"
_b_b="$(ZBUILD_GOAL='goal beta'  _intake_derive_branch_name 0 'Same Title')"
if [[ "$_b_a" == "$_b_b" ]]; then
    assert_fail "[SPEC-4] same title + different goals must not collide" "$_b_a"
else
    assert_pass "[SPEC-4] same title, different goals → different branches"
fi

# No goal text at all: the old deterministic shape, because there is no
# identity to encode.
_b_none="$(ZBUILD_GOAL='' _intake_derive_branch_name 0 '')"
assert_eq "[SPEC-4] no issue and no goal keeps the old shape" \
    "zbuild/issue-0-untitled" "$_b_none"

# Every branch produced must pass the existing validator — the key becomes a
# ref component, and a ref with bad characters is refused by git, not by us.
for _b in "$_b_issue" "$_b_goal" "$_b_a" "$_b_none"; do
    if _intake_validate_branch_name "$_b"; then
        assert_pass "[SPEC-4] '$_b' is a valid branch name"
    else
        assert_fail "[SPEC-4] '$_b' failed branch validation" "invalid"
    fi
done

# ─── [SPEC-5][change] the durable state branch follows the identity ───────
print_test_section "[SPEC-5][change] a goal run gets its own state branch"

# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

assert_eq "[SPEC-5] an issue state branch is unchanged" \
    "zbuild/state/issue-1931" "$(_artifact_persist_branch 1931)"
_sb="$(ZBUILD_GOAL='add a retry to the uploader' _artifact_persist_branch 0)"
assert_contains "[SPEC-5] a goal state branch carries the goal key" "$_sb" "zbuild/state/goal-"
assert_eq "[SPEC-5] neither issue nor goal keeps the old shape" \
    "zbuild/state/issue-0" "$(ZBUILD_GOAL='' _artifact_persist_branch 0)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
