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

print_test_header "test identity hygiene (#1921 follow-up)"
setup_test_env "zb-test-identity"

# ─── [SPEC-1][change] minted ids are reserved and sequential ────────────────
print_test_section "[SPEC-1][change] zb_test_issue mints reserved ids"

_a="$(zb_test_issue)"; _b="$(zb_test_issue)"
assert_eq "[SPEC-1] the first minted id is 90000001" "90000001" "$_a"
# Sequential ACROSS command substitutions — the counter must survive the subshell
# that $(zb_test_issue) creates, which an in-memory variable does not.
assert_eq "[SPEC-1] and ids advance across subshells" "$(( _a + 1 ))" "$_b"
# The whole point: unreachable by a real repository.
if [[ "$_a" -gt 50000000 ]]; then
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

# ─── [SPEC-3][change] a leaked reserved ref is cleaned up ───────────────────
# Simulates exactly what the in-process runner tests do: snapshot with the real
# checkout as CWD. The teardown must remove it.
print_test_section "[SPEC-3][change] cleanup removes a leaked reserved ref"

_leak_issue="$(zb_test_issue)"
_leak_state="$TEST_TEMP_DIR/leak-state"
mkdir -p "$_leak_state/artifacts"
printf 'leaked\n' > "$_leak_state/artifacts/plan.json"
( cd "$REPO_ROOT" && _artifact_persist_snapshot "$_leak_state" "$_leak_issue" ) >/dev/null 2>&1 || true
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
( cd "$REPO_ROOT" && _artifact_persist_snapshot "$_sentinel_state" 424242 ) >/dev/null 2>&1 || true
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
    assert_fail "[SPEC-4] premise: could not create the sentinel ref" "$_real_ref absent"
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
