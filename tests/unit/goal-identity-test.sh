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

# A TITLE IS NOT A GOAL. The first cut fell back to ${ZBUILD_GOAL:-$title},
# which manufactures an identity for a run that has none — contradicting
# SPEC-3's rule above. plugins/agent/intake/tests/intake-branch-test.sh caught
# it, and that test was right: a run invoked without --goal must keep the old
# shape even when it has a perfectly good title.
_b_titled="$(ZBUILD_GOAL='' _intake_derive_branch_name 0 'something')"
assert_eq "[SPEC-4][guard] a title alone does NOT become a goal identity" \
    "zbuild/issue-0-something" "$_b_titled"

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

# ─── [SPEC-6][change] the whole PIPELINE reaches a goal run, not just the name ─
# The gap review found: `_artifact_persist_branch 0` returned the right NAME
# while three `issue > 0` guards — in _artifact_persist_push, in
# _runner_snapshot_artifacts, and around the ZBUILD_RESTORED_ARTIFACTS_DIR
# export — bailed out before ever reaching it. So the branch was computed
# correctly and nothing was ever snapshotted to it or pushed from it, and
# asserting on the name alone could not see that.
#
# This drives the real functions against a real repo and remote.
print_test_section "[SPEC-6][change] a --goal run actually snapshots and pushes"

_G_REMOTE="$TEST_TEMP_DIR/goal-remote.git"
_G_REPO="$TEST_TEMP_DIR/goal-repo"
git init -q --bare "$_G_REMOTE" 2>/dev/null
mkdir -p "$_G_REPO"
(
    cd "$_G_REPO" || exit 1
    git init -q -b main .
    git config user.email t@e.st; git config user.name t
    git remote add origin "$_G_REMOTE"
    : > f; git add f; git commit -q -m init
    git push -q -u origin main
) >/dev/null 2>&1

_G_STATE="$TEST_TEMP_DIR/goal-state"
mkdir -p "$_G_STATE/artifacts"
printf 'goal work
' > "$_G_STATE/artifacts/plan.json"

_G_TEXT='make the uploader retry'
_G_KEY="$(zbuild_run_key 0 "$_G_TEXT")"

# The identity guard itself — the thing every call site now shares.
if ( ZBUILD_GOAL="$_G_TEXT" _artifact_persist_has_identity 0 ); then
    assert_pass "[SPEC-6] a goal run HAS an identity to persist under"
else
    assert_fail "[SPEC-6] a goal run must have an identity" "guard refused it"
fi
if ( ZBUILD_GOAL='' _artifact_persist_has_identity 0 ); then
    assert_fail "[SPEC-6] no issue and no goal must have NO identity" "guard allowed it"
else
    assert_pass "[SPEC-6] control: no issue and no goal has no identity"
fi

_g_snap_rc=0
( cd "$_G_REPO" && ZBUILD_GOAL="$_G_TEXT" _artifact_persist_snapshot "$_G_STATE" 0 )     >/dev/null 2>&1 || _g_snap_rc=$?
assert_exit_code "[SPEC-6] a goal run snapshots" "0" "$_g_snap_rc"
assert_eq "[SPEC-6] and the local branch carries its goal key" "1"     "$( cd "$_G_REPO" && git rev-parse -q --verify "refs/heads/zbuild/state/$_G_KEY" >/dev/null 2>&1 && echo 1 || echo 0 )"

_g_push_status="$( cd "$_G_REPO" && ZBUILD_GOAL="$_G_TEXT" _artifact_persist_push 0 >/dev/null 2>&1
    printf '%s' "${_ARTIFACT_PERSIST_LAST_STATUS:-}" )"
assert_eq "[SPEC-6] the push is NOT skipped as 'empty' for a goal run" "saved" "$_g_push_status"
assert_eq "[SPEC-6] and the goal state branch reaches ORIGIN" "1"     "$( cd "$_G_REPO" && git ls-remote --heads origin "refs/heads/zbuild/state/$_G_KEY" 2>/dev/null | /usr/bin/grep -c . )"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
