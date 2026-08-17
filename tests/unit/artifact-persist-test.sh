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

# ═══════════════════════════════════════════════════════════════════════════
# #1878 — the outcome channel, and the production call shape
#
# Everything above passes repo_root EXPLICITLY (3-arg) and sets git user.* in the
# fixture. Production (core/pipeline/runner.sh) passes TWO args and derives
# repo_root from $(git rev-parse --show-toplevel) against the CWD. That shape was
# covered by nothing, which is how a feature that never once produced a state
# branch stayed green across three test layers.
# ═══════════════════════════════════════════════════════════════════════════

# ── T8 [change]: the PRODUCTION 2-arg shape (repo_root derived from CWD) ─────
print_test_section "T8 production call shape — 2 args, repo_root from CWD"
sd8="$fx/state8"; mkdir -p "$sd8/artifacts"
printf 'prod-shape\n' > "$sd8/artifacts/plan.json"
# NOT a ( … ) subshell: the outcome channel is a shell global, and a subshell's
# assignment would never reach us — the branch would still be created on disk, so
# the test would look like it passed while asserting nothing about the status.
_t8_prev_pwd="$PWD"
cd "$fx" || assert_fail "[T8] could not cd into the fixture repo" "$fx"
_artifact_persist_snapshot "$sd8" 881
rc8=$?
cd "$_t8_prev_pwd" || true
assert_eq "[T8] 2-arg snapshot returns 0" "0" "$rc8"
assert_eq "[T8] 2-arg snapshot reports saved" "saved" "$_ARTIFACT_PERSIST_LAST_STATUS"
if git -C "$fx" rev-parse -q --verify refs/heads/zbuild/state/issue-881 >/dev/null 2>&1; then
    assert_pass "[T8] 2-arg snapshot created the state branch in the shared ref store"
else
    assert_fail "[T8] 2-arg snapshot created the state branch" \
        "no branch; reason=$_ARTIFACT_PERSIST_LAST_REASON"
fi

# ── T9 [change]: "nothing to snapshot" is `empty`, never `saved` ────────────
# The old code returned 0 here, so the runner emitted artifact.snapshot.saved for
# a snapshot that saved nothing — a success event for a no-op.
print_test_section "T9 empty is not success"
sd9="$fx/state9"; mkdir -p "$sd9"          # no artifacts/ subdir at all
_artifact_persist_snapshot "$sd9" 882 "$fx"
assert_eq "[T9] absent artifact dir returns 0" "0" "$?"
assert_eq "[T9] absent artifact dir reports empty, not saved" "empty" "$_ARTIFACT_PERSIST_LAST_STATUS"
mkdir -p "$sd9/artifacts"                  # present but with no files
_artifact_persist_snapshot "$sd9" 882 "$fx"
assert_eq "[T9] empty artifact dir reports empty, not saved" "empty" "$_ARTIFACT_PERSIST_LAST_STATUS"

# ── T10 [change]: an identical re-snapshot is `unchanged`, not `saved` ──────
print_test_section "T10 unchanged is distinguishable from saved"
_artifact_persist_snapshot "$sd8" 881 "$fx"
assert_eq "[T10] re-snapshot of an identical tree reports unchanged" \
    "unchanged" "$_ARTIFACT_PERSIST_LAST_STATUS"

# ── T11 [change]: one unstageable file is SKIPPED, the rest still commit ────
# The main loop used to `break` on the first failure and discard everything
# already staged, while the `extra` loop ten lines below skipped and continued.
print_test_section "T11 one bad file does not discard the snapshot"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    assert_pass "[T11] SKIPPED — running as root, chmod 000 cannot make a file unreadable"
else
    sd11="$fx/state11"; mkdir -p "$sd11/artifacts"
    printf 'good-1\n' > "$sd11/artifacts/a.json"
    printf 'good-2\n' > "$sd11/artifacts/b.json"
    printf 'nope\n'   > "$sd11/artifacts/unreadable.json"
    chmod 000 "$sd11/artifacts/unreadable.json"
    _artifact_persist_snapshot "$sd11" 883 "$fx"
    rc11=$?
    chmod 644 "$sd11/artifacts/unreadable.json" 2>/dev/null || true
    assert_eq "[T11] snapshot still succeeds" "0" "$rc11"
    assert_eq "[T11] status is saved despite the skip" "saved" "$_ARTIFACT_PERSIST_LAST_STATUS"
    assert_eq "[T11] the bad file is counted as skipped" "1" "$_ARTIFACT_PERSIST_LAST_SKIPPED"
    t11_tree="$(git -C "$fx" ls-tree -r --name-only refs/heads/zbuild/state/issue-883 2>/dev/null)"
    assert_contains "[T11] the readable files were still committed" "$t11_tree" "artifacts/a.json"
fi

# ── T12 [change]: a failure carries a reason naming the git operation ───────
# Previously every git call was 2>/dev/null followed by a bare `return 1`, so a
# failure named itself and destroyed its own explanation (#1631's anti-pattern).
print_test_section "T12 a failure explains itself"
sd12="$fx/state12"; mkdir -p "$sd12/artifacts"; printf 'x\n' > "$sd12/artifacts/p.json"
_artifact_persist_snapshot "$sd12" 884 "$TEST_TEMP_DIR/definitely-not-a-repo"
rc12=$?
assert_eq "[T12] an unresolvable repo is a FAILURE, not a silent success" "1" "$rc12"
assert_eq "[T12] status is failed" "failed" "$_ARTIFACT_PERSIST_LAST_STATUS"
if [[ -n "$_ARTIFACT_PERSIST_LAST_REASON" ]]; then
    assert_pass "[T12] the failure carries a non-empty reason"
else
    assert_fail "[T12] the failure carries a non-empty reason" "reason was empty"
fi

# ── T13 [guard]: restore still no-ops cleanly with no state branch ──────────
print_test_section "T13 restore of an absent issue is empty, not failed"
_artifact_persist_restore 999123 "$TEST_TEMP_DIR/restored-none-1878" "$fx"
assert_eq "[T13] absent state branch returns 0" "0" "$?"
assert_eq "[T13] absent state branch reports empty, not failed" \
    "empty" "$_ARTIFACT_PERSIST_LAST_STATUS"

cleanup_test_env
print_test_results
