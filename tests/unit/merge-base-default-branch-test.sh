#!/usr/bin/env bash
# Unit test: the merge-base baseline resolver never assumes the trunk is
# "main" and never guesses HEAD~1 (#1655).
#
# The two defects, both in scripts/lib/merge-base.sh:23:
#   (A) the candidate list is hardcoded to origin/main / main, so a repo whose
#       trunk is master/develop/trunk resolves nothing and falls through;
#   (B) `rev-parse --verify` succeeds for a ref that `git merge-base` then
#       cannot relate to HEAD (shallow clone, no visible common ancestor), so
#       the loop advances to HEAD~1 — a CONFIDENT WRONG ANSWER. Every gate then
#       judges only the most recent commit. Root cause of the 12h loss on #1848
#       (runs 33899707071 / 33944161764): the acceptance gate compared against
#       HEAD~1, so a migration committed in an earlier cycle iteration was
#       invisible and reported as "not in this commit's diff".
#
# SPEC coverage:
#   [MB-1] trunk named `master`      → resolves the TRUE merge-base, not HEAD~1
#   [MB-2] trunk named `develop` via origin/HEAD → origin/HEAD wins
#   [MB-3] trunk named `main`        → unchanged (regression guard)
#   [MB-4] shallow clone, no common ancestor → EMPTY, not HEAD~1
#   [MB-5] a consumer (reachability) reports baseline_resolve_failed, no verdict
#   [MB-6] the HEAD~1 candidate is gone from the resolver source
#   [MB-7] one shared resolver in scripts/lib/ that MAY return empty
#   [MB-8] intake has no duplicate default-branch implementation
#   [MB-9] the CI pipeline workflow checks out full history (fetch-depth: 0)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "merge-base resolver: trunk-agnostic, no HEAD~1 guess (#1655)"
setup_test_env "merge-base-default-branch"

# shellcheck source=../../scripts/lib/merge-base.sh
source "$REPO_ROOT/scripts/lib/merge-base.sh"

_git_id() {
    git -C "$1" config user.email "test@zbuild.local"
    git -C "$1" config user.name  "Test"
    git -C "$1" config commit.gpgsign false
}

# _make_trunk_repo <dir> <trunk-name>
# Trunk carries one commit (the baseline); a feature branch then carries TWO
# commits, so HEAD~1 is NOT the merge-base and a HEAD~1 guess is detectable.
_make_trunk_repo() {
    local dir="$1" trunk="$2"
    mkdir -p "$dir"
    git -C "$dir" init -q -b "$trunk"
    _git_id "$dir"
    printf 'base\n' > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "baseline on $trunk"
    git -C "$dir" checkout -q -b feat/work
    printf 'one\n' >> "$dir/file.txt"
    git -C "$dir" commit -qam "work 1"
    printf 'two\n' >> "$dir/file.txt"
    git -C "$dir" commit -qam "work 2"
}

# ─── [MB-1] trunk is `master` ────────────────────────────────────────────────
print_test_section "[MB-1] a repo whose trunk is 'master' resolves the true merge-base"

R_MASTER="$TEST_TEMP_DIR/master-repo"
_make_trunk_repo "$R_MASTER" master
EXPECT_MASTER="$(git -C "$R_MASTER" rev-parse master)"
HEAD1_MASTER="$(git -C "$R_MASTER" rev-parse 'HEAD~1')"
GOT_MASTER="$(zbuild_resolve_merge_base "$R_MASTER")"

assert_eq "[MB-1] master-trunk repo resolves the merge-base with master" \
    "$EXPECT_MASTER" "$GOT_MASTER"
if [[ "$GOT_MASTER" == "$HEAD1_MASTER" ]]; then
    assert_fail "[MB-1] resolver must not fall through to HEAD~1 on a master-trunk repo" \
        "returned HEAD~1 ($HEAD1_MASTER)"
else
    assert_pass "[MB-1] resolver did not fall through to HEAD~1"
fi

# ─── [MB-2] origin/HEAD wins over the known-name list ────────────────────────
print_test_section "[MB-2] origin/HEAD names the trunk (develop), and is honoured"

R_DEV_ORIGIN="$TEST_TEMP_DIR/develop-origin"
_make_trunk_repo "$R_DEV_ORIGIN" develop
git -C "$R_DEV_ORIGIN" checkout -q develop
R_DEV="$TEST_TEMP_DIR/develop-clone"
git clone -q "$R_DEV_ORIGIN" "$R_DEV"
_git_id "$R_DEV"
git -C "$R_DEV" checkout -q -b feat/work
printf 'one\n' >> "$R_DEV/file.txt"
git -C "$R_DEV" commit -qam "work 1"
printf 'two\n' >> "$R_DEV/file.txt"
git -C "$R_DEV" commit -qam "work 2"
EXPECT_DEV="$(git -C "$R_DEV" rev-parse origin/develop)"
HEAD1_DEV="$(git -C "$R_DEV" rev-parse 'HEAD~1')"
GOT_DEV="$(zbuild_resolve_merge_base "$R_DEV")"

assert_eq "[MB-2] develop-trunk clone resolves the merge-base with origin/develop" \
    "$EXPECT_DEV" "$GOT_DEV"
if [[ "$GOT_DEV" == "$HEAD1_DEV" ]]; then
    assert_fail "[MB-2] resolver must not fall through to HEAD~1 on a develop-trunk clone" \
        "returned HEAD~1 ($HEAD1_DEV)"
else
    assert_pass "[MB-2] resolver did not fall through to HEAD~1"
fi

# ─── [MB-3] regression guard: `main` still works ─────────────────────────────
print_test_section "[MB-3] a main-trunk repo is unchanged"

R_MAIN="$TEST_TEMP_DIR/main-repo"
_make_trunk_repo "$R_MAIN" main
assert_eq "[MB-3] main-trunk repo still resolves the merge-base with main" \
    "$(git -C "$R_MAIN" rev-parse main)" "$(zbuild_resolve_merge_base "$R_MAIN")"

# ─── [MB-4] shallow clone with no common ancestor → EMPTY ────────────────────
print_test_section "[MB-4] shallow clone, no common ancestor → EMPTY (not HEAD~1)"

# Reproduces the CI shape from #1655: origin/main VERIFIES as a ref, but
# `git merge-base origin/main HEAD` returns nothing because both tips are
# shallow-grafted and share no visible ancestor. The old loop treated that as
# "try the next candidate" and landed on HEAD~1.
R_SHALLOW_ORIGIN="$TEST_TEMP_DIR/shallow-origin"
mkdir -p "$R_SHALLOW_ORIGIN"
git -C "$R_SHALLOW_ORIGIN" init -q -b main
_git_id "$R_SHALLOW_ORIGIN"
printf 'a\n' > "$R_SHALLOW_ORIGIN/file.txt"
git -C "$R_SHALLOW_ORIGIN" add file.txt
git -C "$R_SHALLOW_ORIGIN" commit -q -m "root"
git -C "$R_SHALLOW_ORIGIN" checkout -q -b feat/work
for _n in 1 2 3; do
    printf 'w%s\n' "$_n" >> "$R_SHALLOW_ORIGIN/file.txt"
    git -C "$R_SHALLOW_ORIGIN" commit -qam "work $_n"
done
git -C "$R_SHALLOW_ORIGIN" checkout -q main
for _n in 1 2 3; do
    printf 'm%s\n' "$_n" > "$R_SHALLOW_ORIGIN/main-$_n.txt"
    git -C "$R_SHALLOW_ORIGIN" add "main-$_n.txt"
    git -C "$R_SHALLOW_ORIGIN" commit -q -m "main $_n"
done

R_SHALLOW="$TEST_TEMP_DIR/shallow-clone"
git clone -q --depth 1 "file://$R_SHALLOW_ORIGIN" "$R_SHALLOW"
_git_id "$R_SHALLOW"
git -C "$R_SHALLOW" fetch -q --depth 2 origin 'refs/heads/feat/work:refs/remotes/origin/feat/work'
git -C "$R_SHALLOW" checkout -q -b feat/work origin/feat/work

# Preconditions for the trap: origin/main VERIFIES, HEAD~1 VERIFIES, and
# git merge-base between them is EMPTY. Without all three the test is vacuous.
if git -C "$R_SHALLOW" rev-parse --verify origin/main >/dev/null 2>&1; then
    assert_pass "[MB-4] precondition: origin/main verifies in the shallow clone"
else
    assert_fail "[MB-4] precondition: origin/main must verify" "did not verify"
fi
if git -C "$R_SHALLOW" rev-parse --verify 'HEAD~1' >/dev/null 2>&1; then
    assert_pass "[MB-4] precondition: HEAD~1 verifies (the wrong answer is available)"
else
    assert_fail "[MB-4] precondition: HEAD~1 must verify" "did not verify"
fi
_SHALLOW_MB="$(git -C "$R_SHALLOW" merge-base origin/main HEAD 2>/dev/null || true)"
if [[ -z "$_SHALLOW_MB" ]]; then
    assert_pass "[MB-4] precondition: git merge-base origin/main HEAD is empty"
else
    assert_fail "[MB-4] precondition: merge-base must be empty in the shallow clone" \
        "got '$_SHALLOW_MB'"
fi

GOT_SHALLOW="$(zbuild_resolve_merge_base "$R_SHALLOW")"
assert_eq "[MB-4] unresolvable baseline returns EMPTY, not a HEAD~1 guess" \
    "" "$GOT_SHALLOW"

# ─── [MB-5] a consumer reports baseline_resolve_failed, not a verdict ────────
print_test_section "[MB-5] the reachability gate reports baseline_resolve_failed"

# shellcheck source=../../scripts/lib/acceptance-reachability.sh
source "$REPO_ROOT/scripts/lib/acceptance-reachability.sh"

DESIGN_MD="$TEST_TEMP_DIR/design.md"
cat > "$DESIGN_MD" <<'DESIGN'
# Design

```acceptance
SPEC-1 [change] the thing changes
TESTFILES: tests/unit/x-test.sh
WIRING: scripts/lib/x.sh
```
DESIGN

_RCH_OUT="$(acceptance_reachability_check "$DESIGN_MD" "$R_SHALLOW" 2>/dev/null)"
_RCH_RC=$?
assert_contains "[MB-5] reachability reports baseline_resolve_failed on an unresolvable baseline" \
    "$_RCH_OUT" "REACHABILITY ERROR baseline_resolve_failed"
assert_eq "[MB-5] reachability returns rc=1 (an error, not a pass/fail verdict)" \
    "1" "$_RCH_RC"
# The gate must report that it could not establish a baseline — NOT invent a
# wiring verdict (inert_wiring / wiring_not_on_path) off a HEAD~1 guess.
if [[ "$_RCH_OUT" == *"REACHABILITY FAIL"* ]]; then
    assert_fail "[MB-5] reachability must not emit a FAIL verdict without a baseline" \
        "$_RCH_OUT"
else
    assert_pass "[MB-5] no wiring verdict was invented from a guessed baseline"
fi

# ─── [MB-6] the HEAD~1 candidate is gone from the source ─────────────────────
print_test_section "[MB-6] HEAD~1 is not a candidate in the resolver source"

# The CODE must not name HEAD~1 at all outside comments — a comment explaining
# why the guess was removed is the point, an executable reference is the bug.
_MB_CODE="$(grep -vE '^[[:space:]]*#' "$REPO_ROOT/scripts/lib/merge-base.sh")"
if grep -q 'HEAD~1' <<< "$_MB_CODE"; then
    assert_fail "[MB-6] merge-base.sh must have no executable HEAD~1 candidate" \
        "$(grep -n 'HEAD~1' <<< "$_MB_CODE")"
else
    assert_pass "[MB-6] merge-base.sh has no executable HEAD~1 candidate"
fi

# The stale invariant claims ("NOT HEAD~1" while HEAD~1 was literally the last
# link in the chain) are the documentation half of the same defect. What must be
# gone is any text presenting HEAD~1 as a LINK in the candidate chain: written
# as "… → HEAD~1" / "… | HEAD~1", or as the chain's closing "… HEAD~1)" — the
# last of which is how it appeared where the sentence wrapped mid-chain.
_MB6_CHAIN='(→|\|)[[:space:]]*`?HEAD~1|HEAD~1`?[[:space:]]*\)'
for _doc in "scripts/lib/merge-base.sh" "plugins/tool/shape-floor/manifest.yaml" \
            "scripts/lib/shape-floor.sh" "plugins/agent/spec-acceptance/manifest.yaml" \
            "plugins/agent/spec-acceptance/plugin.sh" "docs/wiki/plugins/shape-floor.md" \
            "docs/wiki/plugins/spec-acceptance.md"; do
    if grep -qE "$_MB6_CHAIN" "$REPO_ROOT/$_doc"; then
        assert_fail "[MB-6] $_doc still documents HEAD~1 as a candidate in the chain" \
            "$(grep -nE "$_MB6_CHAIN" "$REPO_ROOT/$_doc")"
    else
        assert_pass "[MB-6] $_doc no longer documents the HEAD~1 chain"
    fi
done

# ─── [MB-7] one shared default-branch resolver that may return empty ─────────
print_test_section "[MB-7] a single shared resolver in scripts/lib/"

if [[ -f "$REPO_ROOT/scripts/lib/default-branch.sh" ]]; then
    assert_pass "[MB-7] scripts/lib/default-branch.sh exists"
else
    assert_fail "[MB-7] scripts/lib/default-branch.sh must exist" "absent"
fi
# shellcheck source=../../scripts/lib/default-branch.sh
source "$REPO_ROOT/scripts/lib/default-branch.sh" 2>/dev/null || true

if declare -F zbuild_resolve_default_branch >/dev/null 2>&1; then
    assert_pass "[MB-7] zbuild_resolve_default_branch is defined"
    assert_eq "[MB-7] resolves 'master' in a master-trunk repo" \
        "master" "$(zbuild_resolve_default_branch "$R_MASTER")"
    assert_eq "[MB-7] resolves 'develop' from origin/HEAD" \
        "develop" "$(zbuild_resolve_default_branch "$R_DEV")"
    assert_eq "[MB-7] resolves 'main' in a main-trunk repo" \
        "main" "$(zbuild_resolve_default_branch "$R_MAIN")"

    # MAY return empty: a repo with no trunk under any known name.
    R_NOTRUNK="$TEST_TEMP_DIR/no-trunk"
    mkdir -p "$R_NOTRUNK"
    git -C "$R_NOTRUNK" init -q -b wip/only
    _git_id "$R_NOTRUNK"
    printf 'x\n' > "$R_NOTRUNK/f.txt"
    git -C "$R_NOTRUNK" add f.txt
    git -C "$R_NOTRUNK" commit -q -m "only"
    assert_eq "[MB-7] returns EMPTY when no trunk resolves (never defaults to 'main')" \
        "" "$(zbuild_resolve_default_branch "$R_NOTRUNK")"
    _NT_RC=0; zbuild_resolve_default_branch "$R_NOTRUNK" >/dev/null 2>&1 || _NT_RC=$?
    assert_eq "[MB-7] an empty resolution is rc=0, not an error" "0" "$_NT_RC"
else
    assert_fail "[MB-7] zbuild_resolve_default_branch must be defined" "absent"
fi

# ─── [MB-8] intake carries no duplicate implementation ───────────────────────
print_test_section "[MB-8] intake is migrated onto the shared resolver"

_BOPS="$REPO_ROOT/plugins/agent/intake/lib/branch-ops.sh"
if grep -qE '^_intake_resolve_default_branch\(\)' "$_BOPS"; then
    assert_fail "[MB-8] intake must not define its own default-branch resolver" \
        "_intake_resolve_default_branch() is still defined in branch-ops.sh"
else
    assert_pass "[MB-8] intake defines no private default-branch resolver"
fi
if grep -q 'zbuild_resolve_default_branch' "$_BOPS"; then
    assert_pass "[MB-8] intake calls the shared zbuild_resolve_default_branch"
else
    assert_fail "[MB-8] intake must call zbuild_resolve_default_branch" "absent"
fi

# ─── [MB-9] CI checks out full history ───────────────────────────────────────
print_test_section "[MB-9] the pipeline workflow checks out full history"

_WF="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"
# Removing the HEAD~1 guess makes a depth-1 checkout fail LOUDLY on every gate,
# so full history is now a hard requirement of the workflow that runs them.
# Read the checkout step's OWN `with:` block (up to the next step's `- name:`),
# so a fetch-depth belonging to some later step cannot satisfy this.
_CHECKOUT_BLOCK="$(awk '
    /uses: actions\/checkout/ { f = 1; print; next }
    f && /^[[:space:]]*-[[:space:]]+(name|uses):/ { exit }
    f { print }
' "$_WF")"
if [[ -n "$_CHECKOUT_BLOCK" ]]; then
    assert_pass "[MB-9] precondition: located the actions/checkout step"
else
    assert_fail "[MB-9] precondition: actions/checkout step not found" "empty block"
fi
assert_contains "[MB-9] actions/checkout in zbuild-pipeline.yml sets fetch-depth: 0" \
    "$_CHECKOUT_BLOCK" "fetch-depth: 0"

print_test_results
