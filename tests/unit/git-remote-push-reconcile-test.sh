#!/usr/bin/env bash
# Unit test: scripts/lib/git-remote.sh zbuild_push_reconcile (Issue PR).
#
# Reconciles origin/<branch> with local HEAD before pushing so the pr-open /
# merge stages tolerate an already-pushed / diverged remote branch instead of
# hard-failing on `git push -u` (the #952 dogfood failure). A mock `git` on PATH
# records its args to a log and returns test-driven output/exit codes.
#
# SPEC coverage (design zbuild/design-issue-pr-push, red-first):
#   [T1] branch absent            → `git push -u origin B`, rc 0
#   [T2] up-to-date               → NO push, rc 0
#   [T3] fast-forward             → `git push origin B` (no --force*), rc 0
#   [T4] diverged (feature)       → `git push --force-with-lease=B:<sha> origin B`, rc 0
#   [T5] genuine push failure     → rc 3, stderr surfaced in ZBUILD_PUSH_RECONCILE_ERR
#   [T6] never force default      → rc 4, no --force*, err mentions default branch
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "git-remote.sh: zbuild_push_reconcile (Issue PR)"
setup_test_env "git-remote-push-reconcile"

# ─── Mock git ────────────────────────────────────────────────────────────────
# Behaviour is driven by MOCK_* env vars; every invocation is logged to
# GIT_MOCK_LOG so the assertions can inspect exactly which push (if any) ran.
export GIT_MOCK_LOG="$TEST_TEMP_DIR/git.log"
_mockbin="$TEST_TEMP_DIR/bin"; mkdir -p "$_mockbin"
cat > "$_mockbin/git" <<'GITMOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_MOCK_LOG"
case "${1:-}" in
    ls-remote)    printf '%s\n' "${MOCK_LS_REMOTE:-}"; exit "${MOCK_LS_REMOTE_RC:-0}" ;;
    rev-parse)    [[ "${2:-}" == "HEAD" ]] && printf '%s\n' "${MOCK_HEAD_SHA:-localsha}"; exit 0 ;;
    fetch)        exit 0 ;;
    cat-file)     exit "${MOCK_CATFILE_RC:-0}" ;;
    merge-base)   exit "${MOCK_ANCESTOR_RC:-0}" ;;
    push)         [[ -n "${MOCK_PUSH_STDERR:-}" ]] && printf '%s\n' "$MOCK_PUSH_STDERR" >&2; exit "${MOCK_PUSH_RC:-0}" ;;
    branch)       exit 0 ;;
    symbolic-ref) printf '%s\n' "${MOCK_ORIGIN_HEAD:-origin/main}"; exit "${MOCK_SYMREF_RC:-0}" ;;
    config)       printf '%s\n' "${MOCK_CONFIG_DEFAULT:-main}"; exit 0 ;;
    *)            exit 0 ;;
esac
GITMOCK
chmod +x "$_mockbin/git"
export PATH="$_mockbin:$PATH"
# Mark all knobs for export so the mock git subprocess sees per-case values.
export MOCK_LS_REMOTE MOCK_LS_REMOTE_RC MOCK_HEAD_SHA MOCK_CATFILE_RC \
       MOCK_ANCESTOR_RC MOCK_PUSH_RC MOCK_PUSH_STDERR MOCK_ORIGIN_HEAD \
       MOCK_SYMREF_RC MOCK_CONFIG_DEFAULT

# shellcheck source=../../scripts/lib/git-remote.sh
source "$REPO_ROOT/scripts/lib/git-remote.sh"

# Reset per-case mock state + log. Clear (not unset) to preserve export flags.
_reset() {
    : > "$GIT_MOCK_LOG"
    MOCK_LS_REMOTE="" MOCK_LS_REMOTE_RC="" MOCK_HEAD_SHA="" MOCK_CATFILE_RC="" \
        MOCK_ANCESTOR_RC="" MOCK_PUSH_RC="" MOCK_PUSH_STDERR="" MOCK_ORIGIN_HEAD="" \
        MOCK_SYMREF_RC="" MOCK_CONFIG_DEFAULT=""
    ZBUILD_PUSH_RECONCILE_ERR=""
}

# ─── T1: branch absent → push -u ─────────────────────────────────────────────
print_test_section "T1: absent remote branch → push -u"
_reset
MOCK_LS_REMOTE=""            # ls-remote empty ⇒ branch absent
zbuild_push_reconcile "featB"; _rc=$?
assert_eq "[T1] rc == 0" "0" "$_rc"
assert_contains "[T1] recorded 'push -u origin featB'" "$(cat "$GIT_MOCK_LOG")" "push -u origin featB"

# ─── T2: up-to-date → no push ────────────────────────────────────────────────
print_test_section "T2: remote == local → skip push"
_reset
MOCK_LS_REMOTE="deadbeef refs/heads/featB"
MOCK_HEAD_SHA="deadbeef"
zbuild_push_reconcile "featB"; _rc=$?
assert_eq "[T2] rc == 0" "0" "$_rc"
if grep -q '^push' "$GIT_MOCK_LOG"; then
    assert_fail "[T2] no push recorded" "$(grep '^push' "$GIT_MOCK_LOG")"
else
    assert_pass "[T2] no push recorded"
fi

# ─── T3: fast-forward → plain push (no force) ────────────────────────────────
print_test_section "T3: remote is ancestor → fast-forward push"
_reset
MOCK_LS_REMOTE="oldsha refs/heads/featB"
MOCK_HEAD_SHA="newsha"
MOCK_ANCESTOR_RC=0           # oldsha is ancestor of HEAD
zbuild_push_reconcile "featB"; _rc=$?
assert_eq "[T3] rc == 0" "0" "$_rc"
assert_contains "[T3] recorded 'push origin featB'" "$(cat "$GIT_MOCK_LOG")" "push origin featB"
if grep -q -- '--force' "$GIT_MOCK_LOG"; then
    assert_fail "[T3] no --force on fast-forward" "$(grep '^push' "$GIT_MOCK_LOG")"
else
    assert_pass "[T3] no --force on fast-forward"
fi

# ─── T4: diverged feature branch → --force-with-lease ────────────────────────
print_test_section "T4: diverged → --force-with-lease on feature branch"
_reset
MOCK_LS_REMOTE="divsha refs/heads/featB"
MOCK_HEAD_SHA="newsha"
MOCK_ANCESTOR_RC=1           # remote NOT ancestor ⇒ diverged
MOCK_ORIGIN_HEAD="origin/main"
zbuild_push_reconcile "featB"; _rc=$?
assert_eq "[T4] rc == 0" "0" "$_rc"
assert_contains "[T4] recorded force-with-lease with expected remote sha" \
    "$(cat "$GIT_MOCK_LOG")" "push --force-with-lease=featB:divsha origin featB"

# ─── T5: genuine push failure → rc 3, stderr surfaced ────────────────────────
print_test_section "T5: push fails → rc 3 with real stderr"
_reset
MOCK_LS_REMOTE=""            # absent ⇒ push -u path
MOCK_PUSH_RC=1
MOCK_PUSH_STDERR="! [rejected] featB -> featB (fetch first)"
zbuild_push_reconcile "featB"; _rc=$?
assert_eq "[T5] rc == 3 on genuine failure" "3" "$_rc"
assert_contains "[T5] stderr surfaced in ZBUILD_PUSH_RECONCILE_ERR" \
    "$ZBUILD_PUSH_RECONCILE_ERR" "rejected"

# ─── T6: never force-push the default branch ─────────────────────────────────
print_test_section "T6: refuse to force-push default branch"
_reset
MOCK_LS_REMOTE="divsha refs/heads/main"
MOCK_HEAD_SHA="newsha"
MOCK_ANCESTOR_RC=1           # diverged
MOCK_ORIGIN_HEAD="origin/main"
zbuild_push_reconcile "main"; _rc=$?
assert_eq "[T6] rc == 4 (refused)" "4" "$_rc"
if grep -q -- '--force' "$GIT_MOCK_LOG"; then
    assert_fail "[T6] no force-push on default branch" "$(grep '^push' "$GIT_MOCK_LOG")"
else
    assert_pass "[T6] no force-push on default branch"
fi
assert_contains "[T6] err mentions default branch" \
    "$ZBUILD_PUSH_RECONCILE_ERR" "default branch"

# ─── T6b: default resolved via origin/HEAD (not literally 'main') ────────────
print_test_section "T6b: refuse when branch == resolved origin/HEAD default"
_reset
MOCK_LS_REMOTE="divsha refs/heads/develop"
MOCK_HEAD_SHA="newsha"
MOCK_ANCESTOR_RC=1
MOCK_ORIGIN_HEAD="origin/develop"   # repo default is develop
zbuild_push_reconcile "develop"; _rc=$?
assert_eq "[T6b] rc == 4 (refused via resolved default)" "4" "$_rc"
if grep -q -- '--force' "$GIT_MOCK_LOG"; then
    assert_fail "[T6b] no force-push on resolved default branch" "$(grep '^push' "$GIT_MOCK_LOG")"
else
    assert_pass "[T6b] no force-push on resolved default branch"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
