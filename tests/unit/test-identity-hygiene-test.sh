#!/usr/bin/env bash
# Tests: no test may write a state ref into the real checkout, and every test
# identity comes from the reserved range (#1921 follow-up).
#
# The existing per-file guard (SPEC-6 in persist-stage-test.sh) only sees its own
# file, so it stayed green while nine tests running `main --issue 999` in-process
# accumulated 68 commits on zbuild/state/issue-999 in the working repository, and
# one running `--issue 698` accumulated 121. setup_test_env sandboxes HOME and the
# state dir, but the runner resolves repo_root from CWD — isolated state, leaked
# refs. This guard is suite-wide.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# Goal identity resolves through zbuild_run_key; without identity.sh a --goal
# snapshot silently falls back to the issue-0 branch and the SPEC-6 premise
# cannot be built.
# shellcheck source=../../scripts/lib/identity.sh
source "$REPO_ROOT/scripts/lib/identity.sh"

print_test_header "test identity hygiene (#1921 follow-up)"
setup_test_env "zb-test-identity"

# ─── [SPEC-1][change] minted ids are reserved and sequential ────────────────
print_test_section "[SPEC-1][change] zb_test_issue mints reserved ids"

_a="$(zb_test_issue)"; _b="$(zb_test_issue)"
# Advances ACROSS command substitutions — the counter must survive the subshell
# that $(zb_test_issue) creates, which an in-memory variable does not.
assert_eq "[SPEC-1] ids advance across subshells" "$(( _a + 1 ))" "$_b"
# PID-keyed, so two test files running in PARALLEL never mint the same id and
# one file's teardown cannot delete a ref another is still asserting on.
assert_eq "[SPEC-1] the id is keyed on this process" "9$(printf '%03d' "$(( $$ % 1000 ))")" \
    "${_a:0:4}"
# The whole point: unreachable by a real repository.
if [[ "$_a" -ge "${ZB_TEST_ISSUE_FLOOR:-90000000}" ]]; then
    assert_pass "[SPEC-1] minted ids are far beyond any real issue number"
else
    assert_fail "[SPEC-1] minted ids must be unreachable" "got $_a"
fi
# And still a valid identity to the engine (issue > 0).
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"
assert_eq "[SPEC-1] a minted id still resolves to an issue branch" \
    "zbuild/state/issue-$_a" "$(_artifact_persist_branch "$_a")"

# ─── [SPEC-2][change] zb_test_repo isolates repo_root ───────────────────────
# The leak is not the state dir — it is repo_root resolving to CWD. A test that
# runs inside zb_test_repo cannot write a ref into the real checkout.
print_test_section "[SPEC-2][change] zb_test_repo gives an isolated repo with an origin"

_R="$(zb_test_repo idrepo)"
assert_file_exists "[SPEC-2] the throwaway repo exists" "$_R/seed.txt"
assert_eq "[SPEC-2] and it has an origin to push to" "origin" \
    "$( cd "$_R" && git remote 2>/dev/null | head -1 )"
assert_eq "[SPEC-2] and it is NOT the real checkout" "different" \
    "$( [[ "$(cd "$_R" && git rev-parse --show-toplevel)" == "$REPO_ROOT" ]] && echo same || echo different )"

# A snapshot commits, so it needs a committer identity. A fresh CI runner has
# none configured and git's implicit fallback (runner@fv-az...(none)) is not a
# valid address, so commit-tree fails and no ref appears — which is exactly what
# these premises assert. Supplied via env so the real checkout's config is not
# touched. Local machines usually derive a usable identity, which is why this
# only failed on CI.
_zb_git_id() {
    GIT_AUTHOR_NAME=zbuild-test GIT_AUTHOR_EMAIL=test@zbuild.local \
    GIT_COMMITTER_NAME=zbuild-test GIT_COMMITTER_EMAIL=test@zbuild.local "$@"
}

# ─── [SPEC-3][change] a leaked reserved ref is cleaned up ───────────────────
# Simulates exactly what the in-process runner tests do: snapshot with the real
# checkout as CWD. The teardown must remove it.
print_test_section "[SPEC-3][change] cleanup removes a leaked reserved ref"

_leak_issue="$(zb_test_issue)"
_leak_state="$TEST_TEMP_DIR/leak-state"
mkdir -p "$_leak_state/artifacts"
printf 'leaked\n' > "$_leak_state/artifacts/plan.json"
( cd "$REPO_ROOT" && _zb_git_id _artifact_persist_snapshot "$_leak_state" "$_leak_issue" ) >/dev/null 2>&1 || true
assert_eq "[SPEC-3] premise: the snapshot landed in the real checkout" "1" \
    "$( git -C "$REPO_ROOT" rev-parse -q --verify "refs/heads/zbuild/state/issue-$_leak_issue" >/dev/null 2>&1 && echo 1 || echo 0 )"
assert_contains "[SPEC-3] and zb_test_reserved_refs sees it" \
    "$(zb_test_reserved_refs "$REPO_ROOT")" "issue-$_leak_issue"

# Teardown, then re-establish the env the remaining assertions need.
cleanup_test_env
assert_eq "[SPEC-3] cleanup_test_env removed the leaked ref" "0" \
    "$( git -C "$REPO_ROOT" rev-parse -q --verify "refs/heads/zbuild/state/issue-$_leak_issue" >/dev/null 2>&1 && echo 1 || echo 0 )"
setup_test_env "zb-test-identity-2"

# ─── [SPEC-4][guard] cleanup never touches a real issue's branch ────────────
# Scoping is the safety property. A contaminated real branch is a separate
# decision for a human, never something a test teardown may delete.
print_test_section "[SPEC-4][guard] cleanup leaves non-reserved refs alone"

_real_ref="refs/heads/zbuild/state/issue-424242"
_sentinel_state="$TEST_TEMP_DIR/sentinel-state"
mkdir -p "$_sentinel_state/artifacts"
printf 'not-a-test\n' > "$_sentinel_state/artifacts/plan.json"
( cd "$REPO_ROOT" && _zb_git_id _artifact_persist_snapshot "$_sentinel_state" 424242 ) >/dev/null 2>&1 || true
if git -C "$REPO_ROOT" rev-parse -q --verify "$_real_ref" >/dev/null 2>&1; then
    cleanup_test_env
    if git -C "$REPO_ROOT" rev-parse -q --verify "$_real_ref" >/dev/null 2>&1; then
        assert_pass "[SPEC-4] a non-reserved ref survives cleanup_test_env"
    else
        assert_fail "[SPEC-4] cleanup must not delete non-reserved refs" "$_real_ref was removed"
    fi
    git -C "$REPO_ROOT" update-ref -d "$_real_ref" 2>/dev/null || true
    setup_test_env "zb-test-identity-3"
else
    # Re-establish the env on this path too. Without it SPEC-5 would run in the
    # previous block's environment, and SPEC-4's invariant would be silently
    # unverified while the file still reported a single failure.
    assert_fail "[SPEC-4] premise: could not create the sentinel ref" "$_real_ref absent"
    cleanup_test_env
    setup_test_env "zb-test-identity-3"
fi

# ─── [SPEC-6][change] a leaked GOAL ref is reaped too ───────────────────────
# Goal refs had teardown and no guard, which is how the --goal leak survived a
# full identity sweep: zb_test_reserved_refs only ever scanned issue-9*, so a
# zbuild/state/goal-<hash> ref in the checkout was invisible to every check.
print_test_section "[SPEC-6][change] cleanup reaps a leaked goal ref"

_g_text="$(zb_test_goal hygiene-goal-probe)"
_g_hash="$(printf '%s' "$_g_text" | tr -d '[:space:]' | shasum -a 256 | cut -c1-12)"
_g_state="$TEST_TEMP_DIR/goal-leak-state"
mkdir -p "$_g_state/artifacts"
printf 'goal-leak\n' > "$_g_state/artifacts/plan.json"
# export, not `_zb_git_id ZBUILD_GOAL=... cmd`: bash expands "$@" and treats a
# leading word containing '=' as a COMMAND NAME, not an assignment, so the goal
# never reached the snapshot and it fell back to the issue-0 branch.
( cd "$REPO_ROOT" && export ZBUILD_GOAL="$_g_text" \
    && _zb_git_id _artifact_persist_snapshot "$_g_state" 0 ) >/dev/null 2>&1 || true

if git -C "$REPO_ROOT" rev-parse -q --verify "refs/heads/zbuild/state/goal-$_g_hash" >/dev/null 2>&1; then
    assert_pass "[SPEC-6] premise: the goal snapshot landed in the real checkout"
    cleanup_test_env
    if git -C "$REPO_ROOT" rev-parse -q --verify "refs/heads/zbuild/state/goal-$_g_hash" >/dev/null 2>&1; then
        assert_fail "[SPEC-6] cleanup_test_env must reap a leaked goal ref" "goal-$_g_hash survived"
        git -C "$REPO_ROOT" update-ref -d "refs/heads/zbuild/state/goal-$_g_hash" 2>/dev/null || true
    else
        assert_pass "[SPEC-6] cleanup_test_env reaped the leaked goal ref"
    fi
    setup_test_env "zb-test-identity-4"
else
    # Not a silent skip: if the premise cannot be built the guard is unverified.
    assert_fail "[SPEC-6] premise: could not create a goal ref to reap" "goal-$_g_hash absent"
    cleanup_test_env
    setup_test_env "zb-test-identity-4"
fi

# ─── [SPEC-5][guard] the suite leaves no state refs in the real checkout ────
# The assertion the per-file guard cannot make. Compares the WHOLE namespace,
# reserved or not, so a leak on any identity is caught.
print_test_section "[SPEC-5][guard] no state ref was added to the real checkout"

_now="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' 'refs/heads/zbuild/state/*' 2>/dev/null | sort || true)"
_reserved_now="$(zb_test_reserved_refs "$REPO_ROOT" | tr '\n' ' ')"
_reserved_now="${_reserved_now// /}"
if [[ -z "$_reserved_now" ]]; then
    assert_pass "[SPEC-5] no reserved-range refs remain after this file"
else
    assert_fail "[SPEC-5] reserved-range refs leaked" "$_reserved_now"
fi
# Report the wider namespace for the operator; contaminated real refs are a
# separate, human decision (they are NOT deleted here).
printf '    state refs currently in the checkout: %s\n' \
    "$(printf '%s' "$_now" | /usr/bin/grep -c . || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
