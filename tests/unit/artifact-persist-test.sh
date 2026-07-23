#!/usr/bin/env bash
# Unit tests for core/state/artifact-persist.sh (#1581): snapshot the artifact
# area onto a separate state branch via git plumbing, restore it, and prove the
# working tree/index are untouched and the state branch never merges into the
# work branch history.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "core/state/artifact-persist (#1581 durable prior-run store)"
setup_test_env "artifact-persist"

# ── Build a throwaway git repo fixture with a work branch + one code commit ──
fx="$TEST_TEMP_DIR/repo"
mkdir -p "$fx"
(
    cd "$fx" || exit 1
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    echo "code" > app.txt
    git add app.txt
    git commit -q -m "base"
    git checkout -q -b zbuild/issue-777-ci
    echo "more" >> app.txt
    git commit -qam "work"
) || { assert_fail "fixture git repo created" "git init failed"; print_test_results; }

state_dir="$fx/state"
mkdir -p "$state_dir/artifacts"
printf 'PRIOR DESIGN BODY\n' > "$state_dir/artifacts/design.md"
printf '{"schema_version":1}\n' > "$state_dir/artifacts/plan.json"
printf '# scope\n' > "$state_dir/scope-manifest.md"

# Capture working-tree + index state before snapshot to prove non-disturbance.
before_head="$(git -C "$fx" rev-parse HEAD)"
before_status="$(git -C "$fx" status --porcelain)"

# ── T1: snapshot creates the state branch with the artifacts ─────────────────
_artifact_persist_snapshot "$state_dir" 777 "$fx"
rc_snap=$?
assert_eq "T1 snapshot returns 0" "0" "$rc_snap"
branch_sha="$(git -C "$fx" rev-parse -q --verify refs/heads/zbuild/state/issue-777 2>/dev/null || echo '')"
assert_pass "T1 state branch exists"
[[ -n "$branch_sha" ]] && assert_pass "T1 state branch has a commit" || assert_fail "T1 state branch has a commit" "missing"

# The state branch tree contains the artifacts under artifacts/ + scope doc.
tree_list="$(git -C "$fx" ls-tree -r --name-only refs/heads/zbuild/state/issue-777 2>/dev/null)"
assert_contains "T1 tree has artifacts/design.md" "$tree_list" "artifacts/design.md"
assert_contains "T1 tree has artifacts/plan.json" "$tree_list" "artifacts/plan.json"
assert_contains "T1 tree has scope-manifest.md" "$tree_list" "scope-manifest.md"

# ── T2: working tree + index untouched (HEAD, status, current branch) ────────
assert_eq "T2 HEAD unchanged after snapshot" "$before_head" "$(git -C "$fx" rev-parse HEAD)"
assert_eq "T2 working status unchanged" "$before_status" "$(git -C "$fx" status --porcelain)"
assert_eq "T2 still on work branch" "zbuild/issue-777-ci" "$(git -C "$fx" rev-parse --abbrev-ref HEAD)"

# ── T3: state branch is NOT an ancestor of the work branch (never merges) ────
if git -C "$fx" merge-base --is-ancestor refs/heads/zbuild/state/issue-777 zbuild/issue-777-ci 2>/dev/null; then
    assert_fail "T3 state branch is not an ancestor of work branch" "it IS an ancestor"
else
    assert_pass "T3 state branch is not an ancestor of work branch"
fi

# ── T4: restore extracts the tree into a fresh dir ───────────────────────────
restored="$TEST_TEMP_DIR/restored"
_artifact_persist_restore 777 "$restored" "$fx"
assert_eq "T4 restore returns 0" "0" "$?"
assert_eq "T4 restored design.md content" "PRIOR DESIGN BODY" "$(cat "$restored/artifacts/design.md" 2>/dev/null)"
assert_pass "T4 restored plan.json present"
[[ -s "$restored/artifacts/plan.json" ]] && assert_pass "T4 plan.json non-empty" || assert_fail "T4 plan.json non-empty" "empty"

# ── T5: second snapshot with new content adds a commit (parented) ────────────
printf 'REFINED DESIGN\n' > "$state_dir/artifacts/design.md"
_artifact_persist_snapshot "$state_dir" 777 "$fx"
new_sha="$(git -C "$fx" rev-parse refs/heads/zbuild/state/issue-777)"
[[ "$new_sha" != "$branch_sha" ]] && assert_pass "T5 second snapshot advances the state branch" || assert_fail "T5 second snapshot advances" "sha unchanged"
parent_of_new="$(git -C "$fx" rev-parse "refs/heads/zbuild/state/issue-777^" 2>/dev/null || echo '')"
assert_eq "T5 new commit is parented on the prior snapshot" "$branch_sha" "$parent_of_new"

# ── T6: identical re-snapshot is a no-op (no empty commit) ────────────────────
sha_before_noop="$(git -C "$fx" rev-parse refs/heads/zbuild/state/issue-777)"
_artifact_persist_snapshot "$state_dir" 777 "$fx"
assert_eq "T6 identical snapshot does not create a commit" "$sha_before_noop" "$(git -C "$fx" rev-parse refs/heads/zbuild/state/issue-777)"

# ── T7: restore is a clean no-op when no state branch exists ──────────────────
restored2="$TEST_TEMP_DIR/restored-none"
_artifact_persist_restore 999 "$restored2" "$fx"
assert_eq "T7 restore of absent issue returns 0" "0" "$?"

cleanup_test_env
print_test_results
