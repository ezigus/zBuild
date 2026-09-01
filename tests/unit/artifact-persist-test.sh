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

# #1921 follow-up: reserved test identity (see zb_test_issue). The literals
# here were real issue numbers; a run keyed to one writes fabricated prior
# work onto that issue's state branch.
_ZB_ID1="$(zb_test_issue)"
_ZB_ID2="$(zb_test_issue)"
_ZB_ID3="$(zb_test_issue)"
_ZB_ID4="$(zb_test_issue)"
_ZB_ID5="$(zb_test_issue)"
_ZB_ID6="$(zb_test_issue)"
_ZB_ID7="$(zb_test_issue)"
_ZB_ID8="$(zb_test_issue)"
_ZB_ID9="$(zb_test_issue)"
_ZB_ID10="$(zb_test_issue)"

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
    git checkout -q -b zbuild/issue-$_ZB_ID1-ci
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
_artifact_persist_snapshot "$state_dir" $_ZB_ID1 "$fx"
rc_snap=$?
assert_eq "T1 snapshot returns 0" "0" "$rc_snap"
branch_sha="$(git -C "$fx" rev-parse -q --verify refs/heads/zbuild/state/issue-$_ZB_ID1 2>/dev/null || echo '')"
assert_pass "T1 state branch exists"
[[ -n "$branch_sha" ]] && assert_pass "T1 state branch has a commit" || assert_fail "T1 state branch has a commit" "missing"

# The state branch tree contains the artifacts under artifacts/ + scope doc.
tree_list="$(git -C "$fx" ls-tree -r --name-only refs/heads/zbuild/state/issue-$_ZB_ID1 2>/dev/null)"
assert_contains "T1 tree has artifacts/design.md" "$tree_list" "artifacts/design.md"
assert_contains "T1 tree has artifacts/plan.json" "$tree_list" "artifacts/plan.json"
assert_contains "T1 tree has scope-manifest.md" "$tree_list" "scope-manifest.md"

# ── T2: working tree + index untouched (HEAD, status, current branch) ────────
assert_eq "T2 HEAD unchanged after snapshot" "$before_head" "$(git -C "$fx" rev-parse HEAD)"
assert_eq "T2 working status unchanged" "$before_status" "$(git -C "$fx" status --porcelain)"
assert_eq "T2 still on work branch" "zbuild/issue-$_ZB_ID1-ci" "$(git -C "$fx" rev-parse --abbrev-ref HEAD)"

# ── T3: state branch is NOT an ancestor of the work branch (never merges) ────
if git -C "$fx" merge-base --is-ancestor refs/heads/zbuild/state/issue-$_ZB_ID1 zbuild/issue-$_ZB_ID1-ci 2>/dev/null; then
    assert_fail "T3 state branch is not an ancestor of work branch" "it IS an ancestor"
else
    assert_pass "T3 state branch is not an ancestor of work branch"
fi

# ── T4: restore extracts the tree into a fresh dir ───────────────────────────
restored="$TEST_TEMP_DIR/restored"
_artifact_persist_restore $_ZB_ID1 "$restored" "$fx"
assert_eq "T4 restore returns 0" "0" "$?"
assert_eq "T4 restored design.md content" "PRIOR DESIGN BODY" "$(cat "$restored/artifacts/design.md" 2>/dev/null)"
assert_pass "T4 restored plan.json present"
[[ -s "$restored/artifacts/plan.json" ]] && assert_pass "T4 plan.json non-empty" || assert_fail "T4 plan.json non-empty" "empty"

# ── T5: second snapshot with new content adds a commit (parented) ────────────
printf 'REFINED DESIGN\n' > "$state_dir/artifacts/design.md"
_artifact_persist_snapshot "$state_dir" $_ZB_ID1 "$fx"
new_sha="$(git -C "$fx" rev-parse refs/heads/zbuild/state/issue-$_ZB_ID1)"
[[ "$new_sha" != "$branch_sha" ]] && assert_pass "T5 second snapshot advances the state branch" || assert_fail "T5 second snapshot advances" "sha unchanged"
parent_of_new="$(git -C "$fx" rev-parse "refs/heads/zbuild/state/issue-$_ZB_ID1^" 2>/dev/null || echo '')"
assert_eq "T5 new commit is parented on the prior snapshot" "$branch_sha" "$parent_of_new"

# ── T6: identical re-snapshot is a no-op (no empty commit) ────────────────────
sha_before_noop="$(git -C "$fx" rev-parse refs/heads/zbuild/state/issue-$_ZB_ID1)"
_artifact_persist_snapshot "$state_dir" $_ZB_ID1 "$fx"
assert_eq "T6 identical snapshot does not create a commit" "$sha_before_noop" "$(git -C "$fx" rev-parse refs/heads/zbuild/state/issue-$_ZB_ID1)"

# ── T7: restore is a clean no-op when no state branch exists ──────────────────
restored2="$TEST_TEMP_DIR/restored-none"
_artifact_persist_restore $_ZB_ID2 "$restored2" "$fx"
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
_artifact_persist_snapshot "$sd8" $_ZB_ID3
rc8=$?
cd "$_t8_prev_pwd" || true
assert_eq "[T8] 2-arg snapshot returns 0" "0" "$rc8"
assert_eq "[T8] 2-arg snapshot reports saved" "saved" "$_ARTIFACT_PERSIST_LAST_STATUS"
if git -C "$fx" rev-parse -q --verify refs/heads/zbuild/state/issue-$_ZB_ID3 >/dev/null 2>&1; then
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
_artifact_persist_snapshot "$sd9" $_ZB_ID4 "$fx"
assert_eq "[T9] absent artifact dir returns 0" "0" "$?"
assert_eq "[T9] absent artifact dir reports empty, not saved" "empty" "$_ARTIFACT_PERSIST_LAST_STATUS"
mkdir -p "$sd9/artifacts"                  # present but with no files
_artifact_persist_snapshot "$sd9" $_ZB_ID4 "$fx"
assert_eq "[T9] empty artifact dir reports empty, not saved" "empty" "$_ARTIFACT_PERSIST_LAST_STATUS"

# ── T10 [change]: an identical re-snapshot is `unchanged`, not `saved` ──────
print_test_section "T10 unchanged is distinguishable from saved"
_artifact_persist_snapshot "$sd8" $_ZB_ID3 "$fx"
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
    _artifact_persist_snapshot "$sd11" $_ZB_ID5 "$fx"
    rc11=$?
    chmod 644 "$sd11/artifacts/unreadable.json" 2>/dev/null || true
    assert_eq "[T11] snapshot still succeeds" "0" "$rc11"
    assert_eq "[T11] status is saved despite the skip" "saved" "$_ARTIFACT_PERSIST_LAST_STATUS"
    assert_eq "[T11] the bad file is counted as skipped" "1" "$_ARTIFACT_PERSIST_LAST_SKIPPED"
    t11_tree="$(git -C "$fx" ls-tree -r --name-only refs/heads/zbuild/state/issue-$_ZB_ID5 2>/dev/null)"
    assert_contains "[T11] the readable files were still committed" "$t11_tree" "artifacts/a.json"
fi

# ── T12 [change]: a failure carries a reason naming the git operation ───────
# Previously every git call was 2>/dev/null followed by a bare `return 1`, so a
# failure named itself and destroyed its own explanation (#1631's anti-pattern).
print_test_section "T12 a failure explains itself"
sd12="$fx/state12"; mkdir -p "$sd12/artifacts"; printf 'x\n' > "$sd12/artifacts/p.json"
_artifact_persist_snapshot "$sd12" $_ZB_ID6 "$TEST_TEMP_DIR/definitely-not-a-repo"
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
_artifact_persist_restore $_ZB_ID7 "$TEST_TEMP_DIR/restored-none-1878" "$fx"
assert_eq "[T13] absent state branch returns 0" "0" "$?"
assert_eq "[T13] absent state branch reports empty, not failed" \
    "empty" "$_ARTIFACT_PERSIST_LAST_STATUS"

# ── T14 [change]: a successful restore reports `restored`, NOT `saved` ──────
# PR #1880 review: one status channel carries both operations. Reusing "saved"
# for a restore would let a caller checking `== "saved"` to confirm a SNAPSHOT be
# satisfied by the restore — which runs first, at startup, on every run.
print_test_section "T14 restore and snapshot are distinguishable on one channel"
_artifact_persist_restore $_ZB_ID3 "$TEST_TEMP_DIR/restored-$_ZB_ID3" "$fx"
assert_eq "[T14] a successful restore returns 0" "0" "$?"
assert_eq "[T14] and reports 'restored', not 'saved'" \
    "restored" "$_ARTIFACT_PERSIST_LAST_STATUS"
# The complement to T16's source=remote. Without both directions the field
# could be hardcoded to either value and still satisfy one of them — the
# point of _ARTIFACT_PERSIST_LAST_SOURCE is that it DISCRIMINATES.
assert_eq "[T14] and records source=local (the local-ref path)" \
    "local" "$_ARTIFACT_PERSIST_LAST_SOURCE"

# ── T15 [guard]: mktemp guards — a failure must not be attributed to git ────
# PR #1880 review: an unguarded `mktemp -u` left the stderr path empty, `2>""`
# then failed to open, and the git op failed for the WRONG reason with no
# captured stderr — a silent failure inside the code whose purpose is to end
# silent failures. Point TMPDIR at a non-writable location and assert the
# snapshot still reports a coherent outcome rather than crashing.
print_test_section "T15 an unusable TMPDIR does not corrupt the failure report"
sd15="$fx/state15"; mkdir -p "$sd15/artifacts"; printf 'x\n' > "$sd15/artifacts/p.json"
TMPDIR="/nonexistent-dir-for-1878" _artifact_persist_snapshot "$sd15" $_ZB_ID8 "$fx"
rc15=$?
case "$_ARTIFACT_PERSIST_LAST_STATUS" in
    saved|failed)
        assert_pass "[T15] status is coherent under an unusable TMPDIR (got: $_ARTIFACT_PERSIST_LAST_STATUS, rc=$rc15)" ;;
    *)
        assert_fail "[T15] status is coherent under an unusable TMPDIR" \
            "got: [$_ARTIFACT_PERSIST_LAST_STATUS] rc=$rc15" ;;
esac
if [[ "$_ARTIFACT_PERSIST_LAST_STATUS" == "failed" && -z "$_ARTIFACT_PERSIST_LAST_REASON" ]]; then
    assert_fail "[T15] a failure still carries a reason" "reason was empty"
else
    assert_pass "[T15] a failure still carries a reason"
fi

# ── T16 [SPEC-1] [guard]: CI cold-start restore via refs/remotes/origin ──────
# _artifact_persist_restore prefers refs/heads/<branch> but falls back to
# refs/remotes/origin/<branch> on a CI cold start where the local ref is absent.
# This path (line ~365 of artifact-persist.sh) had no test — a regression there
# would be invisible.
print_test_section "T16 [SPEC-1] restore from refs/remotes/origin (CI cold start)"
_sd16="$TEST_TEMP_DIR/t16-remote.git"
_rd16="$TEST_TEMP_DIR/t16-restored"
_fx16="$TEST_TEMP_DIR/t16-origin-repo"
_fx16b="$TEST_TEMP_DIR/t16-cold-repo"

# Build a bare remote and a repo with the state branch committed and pushed.
git init -q --bare "$_sd16" 2>/dev/null
(
    git init -q -b main "$_fx16" 2>/dev/null
    cd "$_fx16" || exit 1
    git config user.email t@t.t; git config user.name t
    git remote add origin "$_sd16"
    : > f; git add f; git commit -q -m init
    git push -q -u origin main
) >/dev/null 2>&1
state16="$TEST_TEMP_DIR/t16-state"
mkdir -p "$state16/artifacts"
printf 't16-artifact\n' > "$state16/artifacts/t16.json"
_artifact_persist_snapshot "$state16" $_ZB_ID9 "$_fx16" >/dev/null 2>&1
( cd "$_fx16" && git push -q origin \
    "refs/heads/zbuild/state/issue-$_ZB_ID9:refs/heads/zbuild/state/issue-$_ZB_ID9" ) >/dev/null 2>&1

# Build a cold-start repo: has the remote-tracking ref but NO local branch.
(
    git init -q -b main "$_fx16b" 2>/dev/null
    cd "$_fx16b" || exit 1
    git config user.email t@t.t; git config user.name t
    git remote add origin "$_sd16"
    # Fetch the state branch only into refs/remotes/origin (not refs/heads).
    git fetch -q origin \
        "refs/heads/zbuild/state/issue-$_ZB_ID9:refs/remotes/origin/zbuild/state/issue-$_ZB_ID9" \
        2>/dev/null
) >/dev/null 2>&1

# Verify the premise: local branch must not exist, only the remote-tracking ref.
_t16_local="$(git -C "$_fx16b" rev-parse -q --verify \
    refs/heads/zbuild/state/issue-$_ZB_ID9 >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "[SPEC-1] T16 premise: cold-start repo has no local state branch" "no" "$_t16_local"
_t16_remote="$(git -C "$_fx16b" rev-parse -q --verify \
    refs/remotes/origin/zbuild/state/issue-$_ZB_ID9 >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "[SPEC-1] T16 premise: but it does have the remote-tracking ref" "yes" "$_t16_remote"

# Now restore — must fall through to the refs/remotes/origin path.
_artifact_persist_restore $_ZB_ID9 "$_rd16" "$_fx16b"
_rc16=$?
assert_eq "[SPEC-1] CI cold-start restore returns 0" "0" "$_rc16"
assert_eq "[SPEC-1] CI cold-start restore reports restored, not empty or failed" \
    "restored" "$_ARTIFACT_PERSIST_LAST_STATUS"
assert_file_exists "[SPEC-1] CI cold-start restore extracts the artifact" \
    "$_rd16/artifacts/t16.json"
# _ARTIFACT_PERSIST_LAST_SOURCE records which ref path was used; "remote" means
# refs/remotes/origin/<branch> — this is the new field proving the CI cold-start
# path was taken, not the local-branch fast-path.
assert_eq "[SPEC-1] CI cold-start restore records source=remote (not local)" \
    "remote" "$_ARTIFACT_PERSIST_LAST_SOURCE"

# ── T17 [SPEC-2] [change]: a CI-shaped repo CHAINS onto the fetched tip ──────
# On a CI runner hydrate creates only refs/remotes/origin/<branch>; the local
# refs/heads/<branch> never exists. _artifact_persist_snapshot reads its parent
# from refs/heads, so every CI snapshot used to ROOT a new history — and the
# force-push then orphaned everything already on origin. The state branch could
# never accumulate in CI (local issue-999 has 344 commits across runs;
# CI issue-1836 had 20 from a single run).
print_test_section "T17 [SPEC-2] CI-shaped repo chains instead of rooting"

_sd17="$TEST_TEMP_DIR/t17-remote.git"
_fx17="$TEST_TEMP_DIR/t17-origin-repo"
_fx17b="$TEST_TEMP_DIR/t17-cold-repo"

git init -q --bare "$_sd17" 2>/dev/null
(
    git init -q -b main "$_fx17" 2>/dev/null
    cd "$_fx17" || exit 1
    git config user.email t@t.t; git config user.name t
    git remote add origin "$_sd17"
    : > f; git add f; git commit -q -m init
    git push -q -u origin main
) >/dev/null 2>&1

# Run A: seed the state branch and publish it.
_state17="$TEST_TEMP_DIR/t17-state"
mkdir -p "$_state17/artifacts"
printf 't17-run-a\n' > "$_state17/artifacts/a.json"
_artifact_persist_snapshot "$_state17" $_ZB_ID10 "$_fx17" >/dev/null 2>&1
( cd "$_fx17" && git push -q origin \
    "refs/heads/zbuild/state/issue-$_ZB_ID10:refs/heads/zbuild/state/issue-$_ZB_ID10" ) >/dev/null 2>&1
_t17_runa_tip="$( git -C "$_fx17" rev-parse refs/heads/zbuild/state/issue-$_ZB_ID10 )"

# Run B: a COLD runner — remote-tracking ref only, exactly what _hydrate_fetch
# leaves behind. No local refs/heads.
(
    git init -q -b main "$_fx17b" 2>/dev/null
    cd "$_fx17b" || exit 1
    git config user.email t@t.t; git config user.name t
    git remote add origin "$_sd17"
    git fetch -q origin \
        "refs/heads/zbuild/state/issue-$_ZB_ID10:refs/remotes/origin/zbuild/state/issue-$_ZB_ID10" \
        2>/dev/null
) >/dev/null 2>&1
assert_eq "[SPEC-2] T17 premise: cold repo has no local state branch" "no" \
    "$(git -C "$_fx17b" rev-parse -q --verify refs/heads/zbuild/state/issue-$_ZB_ID10 >/dev/null 2>&1 && echo yes || echo no)"

# Adopt the fetched tip, then snapshot as run B would.
_artifact_persist_adopt_remote $_ZB_ID10 "$_fx17b" >/dev/null 2>&1
_state17b="$TEST_TEMP_DIR/t17-state-b"
mkdir -p "$_state17b/artifacts"
printf 't17-run-b\n' > "$_state17b/artifacts/b.json"
_artifact_persist_snapshot "$_state17b" $_ZB_ID10 "$_fx17b" >/dev/null 2>&1
_t17_runb_tip="$( git -C "$_fx17b" rev-parse refs/heads/zbuild/state/issue-$_ZB_ID10 2>/dev/null || echo none )"

# THE ASSERTION: run B builds ON run A, rather than orphaning it.
if git -C "$_fx17b" merge-base --is-ancestor "$_t17_runa_tip" "$_t17_runb_tip" 2>/dev/null; then
    assert_pass "[SPEC-2] run B's snapshot keeps run A's commit as an ancestor"
else
    assert_fail "[SPEC-2] run B must chain onto run A, not orphan it" \
        "runA=$_t17_runa_tip runB=$_t17_runb_tip"
fi
# Ancestry alone could be satisfied by an empty chain, so assert the retained
# history is USABLE: run A's artifact is still readable at its own commit,
# reachable from run B's tip. (Run B's own tree correctly holds only run B's
# artifacts — a snapshot captures the current state dir, and prior work reaches
# a stage through hydrate's separate restored-artifacts seam, not through this
# tree.)
assert_eq "[SPEC-2] run A's artifact is still readable from the retained history" \
    "t17-run-a" \
    "$(git -C "$_fx17b" show "${_t17_runa_tip}:artifacts/a.json" 2>/dev/null | tr -d '\n')"

# ── T18 [SPEC-3] [guard]: adopt NEVER overwrites an existing local ref ───────
# plugins/tool/hydrate/manifest.yaml states the invariant: a LOCAL snapshot wins
# on read when both exist, because it may carry work an earlier push never
# delivered. An unconditional update-ref would destroy exactly that.
print_test_section "T18 [SPEC-3] adopt leaves an existing local ref alone"

_t18_local_tip="$( git -C "$_fx17" rev-parse refs/heads/zbuild/state/issue-$_ZB_ID10 )"
# Give the origin-side repo a DIFFERENT remote-tracking tip, then adopt.
( cd "$_fx17" && git fetch -q origin \
    "+refs/heads/zbuild/state/issue-$_ZB_ID10:refs/remotes/origin/zbuild/state/issue-$_ZB_ID10" ) >/dev/null 2>&1
_artifact_persist_adopt_remote $_ZB_ID10 "$_fx17" >/dev/null 2>&1
assert_eq "[SPEC-3] an existing local ref is not moved by adopt" "$_t18_local_tip" \
    "$( git -C "$_fx17" rev-parse refs/heads/zbuild/state/issue-$_ZB_ID10 )"
assert_eq "[SPEC-3] and adopt reports it kept the local ref" "kept" \
    "$_ARTIFACT_PERSIST_LAST_STATUS"

cleanup_test_env
print_test_results
