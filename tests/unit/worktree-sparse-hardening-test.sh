#!/usr/bin/env bash
# tests/unit/worktree-sparse-hardening-test.sh
# The legacy/ exclusion (#1802, ADR-059 §2) is an optimisation, never a reason
# for a run to stop, and a keeper's widening is validated and survives resume.
#
# [#1802/FAIL-OPEN]   a failing `git sparse-checkout` does not fail acquire or
#                     enter: rc=0, the tree exists, stderr names git's error
# [#1802/GIT-VERSION] a git too old for `set --no-cone` is named on stderr and
#                     the run continues with the full tree
# [#1802/WTCONFIG]    extensions.worktreeConfig is written only when unset; an
#                     operator's explicit `false` is kept and sparse is skipped
# [#1802/WIDEN-ARGS]  zbuild_worktree_include_legacy_path refuses anything but a
#                     plain relative path under legacy/ (no options, patterns)
# [#1802/WIDEN]       an accepted widening checks out that one file, `git rm`
#                     of it works, and the rest of legacy/ stays excluded
# [#1802/RESUME]      re-acquire / re-enter keeps the widening
# [#1802/CONFLICT]    re-acquire over a different sparse config lands on the
#                     base patterns plus any keeper widenings, nothing else
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "legacy/ sparse exclusion: fail open, validated widening, resume (#1802)"
setup_test_env "worktree-sparse-hardening"

# shellcheck source=../../scripts/lib/worktree.sh
source "$REPO_ROOT/scripts/lib/worktree.sh"
set +e

REAL_GIT="$(command -v git)"
export REAL_GIT

# ── fixture: a git repo with frozen legacy files and a tombstone ────────────
_mk_repo() {
    local r="$1"
    mkdir -p "$r/legacy/migrated" "$r/legacy/sub" "$r/src"
    printf 'frozen\n'    > "$r/legacy/frozen.sh"
    printf 'other\n'     > "$r/legacy/sub/other.sh"
    printf 'tombstone\n' > "$r/legacy/migrated/tombstone.md"
    printf 'work\n'      > "$r/src/work.sh"
    git -C "$r" init -q -b main
    git -C "$r" config user.email t@t
    git -C "$r" config user.name t
    git -C "$r" config commit.gpgsign false
    git -C "$r" add -A
    git -C "$r" commit -qm init
}

# A `git` shim: SHIM_MODE=failsparse fails every sparse-checkout call the way
# git does; SHIM_MODE=old reports a pre-2.35 version. SHIM_LOG records argv.
_SHIM="$TEST_TEMP_DIR/shim"
mkdir -p "$_SHIM"
cat > "$_SHIM/git" <<'EOF'
#!/usr/bin/env bash
[[ -n "${SHIM_LOG:-}" ]] && printf '%s\n' "$*" >> "$SHIM_LOG"
if [[ "${SHIM_MODE:-}" == old && "${1:-}" == --version ]]; then
    printf 'git version 2.20.1\n'; exit 0
fi
if [[ "${SHIM_MODE:-}" == failsparse ]]; then
    for a in "$@"; do
        [[ "$a" == sparse-checkout ]] && { printf 'fatal: injected sparse failure\n' >&2; exit 128; }
    done
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$_SHIM/git"

_R="$TEST_TEMP_DIR/repo"
_mk_repo "$_R"
export ZBUILD_WORKTREE_ROOT="$TEST_TEMP_DIR/wt"
_ERR="$TEST_TEMP_DIR/stderr"

# ── FAIL-OPEN: acquire ───────────────────────────────────────────────────────
_wt="$(PATH="$_SHIM:$PATH" SHIM_MODE=failsparse zbuild_worktree_acquire failopen "$_R" 2>"$_ERR")"; _rc=$?
_err="$(<"$_ERR")"
assert_eq "[#1802/FAIL-OPEN] acquire returns 0 when sparse-checkout fails" "0" "$_rc"
if [[ -n "$_wt" && -f "$_wt/src/work.sh" ]]; then
    assert_pass "[#1802/FAIL-OPEN] acquire still prints and creates the worktree"
else
    assert_fail "[#1802/FAIL-OPEN] acquire must print an existing worktree" "path=${_wt:-<empty>}"
fi
assert_contains "[#1802/FAIL-OPEN] stderr carries git's own error" "$_err" "injected sparse failure"
assert_contains "[#1802/FAIL-OPEN] stderr names the failing step" "$_err" "sparse-checkout"
assert_contains "[#1802/FAIL-OPEN] stderr says the run continues with the full tree" "$_err" "full tree"

# ── FAIL-OPEN: enter (create) ────────────────────────────────────────────────
_wt="$(cd "$_R" && PATH="$_SHIM:$PATH" SHIM_MODE=failsparse zbuild_worktree_enter failopen-enter zbuild/fo create 2>"$_ERR")"; _rc=$?
assert_eq "[#1802/FAIL-OPEN] enter returns 0 when sparse-checkout fails" "0" "$_rc"
assert_contains "[#1802/FAIL-OPEN] enter's stderr carries git's error" "$(<"$_ERR")" "injected sparse failure"

# ── GIT-VERSION ──────────────────────────────────────────────────────────────
_wt="$(PATH="$_SHIM:$PATH" SHIM_MODE=old zbuild_worktree_acquire oldgit "$_R" 2>"$_ERR")"; _rc=$?
_err="$(<"$_ERR")"
assert_eq "[#1802/GIT-VERSION] acquire returns 0 on a too-old git" "0" "$_rc"
assert_contains "[#1802/GIT-VERSION] stderr names the git version found" "$_err" "2.20.1"
assert_contains "[#1802/GIT-VERSION] stderr names the version needed" "$_err" "2.35"
if [[ -n "$_wt" && -f "$_wt/legacy/frozen.sh" ]]; then
    assert_pass "[#1802/GIT-VERSION] the tree is full (sparse was not attempted)"
else
    assert_fail "[#1802/GIT-VERSION] the tree must be full on a too-old git" "path=${_wt:-<empty>}"
fi

# ── WTCONFIG: written once, never rewritten when already true ────────────────
_LOG="$TEST_TEMP_DIR/git.log"
: > "$_LOG"
PATH="$_SHIM:$PATH" SHIM_LOG="$_LOG" zbuild_worktree_acquire wtcfg-again "$_R" >/dev/null 2>&1
if /usr/bin/grep -q 'config extensions.worktreeConfig true' "$_LOG"; then
    assert_fail "[#1802/WTCONFIG] an already-true extensions.worktreeConfig must not be rewritten" \
        "$(<"$_LOG")"
else
    assert_pass "[#1802/WTCONFIG] extensions.worktreeConfig already true: not rewritten"
fi

# ── WTCONFIG: operator's explicit false is kept; sparse skipped, loudly ──────
_RF="$TEST_TEMP_DIR/repo-false"
_mk_repo "$_RF"
git -C "$_RF" config extensions.worktreeConfig false
_wt="$(zbuild_worktree_acquire wtfalse "$_RF" 2>"$_ERR")"; _rc=$?
_err="$(<"$_ERR")"
assert_eq "[#1802/WTCONFIG] acquire returns 0 when worktreeConfig=false" "0" "$_rc"
assert_eq "[#1802/WTCONFIG] the operator's extensions.worktreeConfig=false is kept" \
    "false" "$(git -C "$_RF" config --get extensions.worktreeConfig)"
assert_contains "[#1802/WTCONFIG] stderr names extensions.worktreeConfig" "$_err" "extensions.worktreeConfig"
if [[ -n "$_wt" && -f "$_wt/legacy/frozen.sh" && -f "$_RF/legacy/frozen.sh" ]]; then
    assert_pass "[#1802/WTCONFIG] sparse skipped: worktree and main checkout are full"
else
    assert_fail "[#1802/WTCONFIG] with worktreeConfig=false nothing may be made sparse" "wt=${_wt:-<empty>}"
fi

# ── WIDEN-ARGS: every rejected class ─────────────────────────────────────────
_WTW="$(zbuild_worktree_acquire widen "$_R" 2>/dev/null)"
_before="$(git -C "$_WTW" sparse-checkout list 2>&1)"
for _bad in "" "legacy" "legacy/" "--cone" "/legacy/frozen.sh" "src/work.sh" \
            "legacy/*" "legacy/fr?zen.sh" "legacy/[f]rozen.sh" "!legacy/frozen.sh" \
            "legacy/../src/work.sh" "legacy/sub/../frozen.sh" "legacy//frozen.sh" \
            "legacy/./frozen.sh" $'legacy/a\nb' 'legacy/a\b'; do
    zbuild_worktree_include_legacy_path "$_WTW" "$_bad" >/dev/null 2>"$_ERR"; _rc=$?
    if [[ "$_rc" -ne 0 && -s "$_ERR" ]]; then
        assert_pass "[#1802/WIDEN-ARGS] rejects '${_bad//$'\n'/\\n}' with a message"
    else
        assert_fail "[#1802/WIDEN-ARGS] must reject '${_bad//$'\n'/\\n}' non-zero with a message" "rc=$_rc"
    fi
done
assert_eq "[#1802/WIDEN-ARGS] rejected calls left the pattern set untouched" \
    "$_before" "$(git -C "$_WTW" sparse-checkout list 2>&1)"
[[ ! -f "$_WTW/legacy/frozen.sh" ]] \
    && assert_pass "[#1802/WIDEN-ARGS] legacy/ still excluded after the rejections" \
    || assert_fail "[#1802/WIDEN-ARGS] a rejected call widened the tree"

# ── WIDEN: one accepted path ─────────────────────────────────────────────────
zbuild_worktree_include_legacy_path "$_WTW" "legacy/frozen.sh" >/dev/null 2>"$_ERR"; _rc=$?
assert_eq "[#1802/WIDEN] accepts legacy/frozen.sh" "0" "$_rc"
[[ -f "$_WTW/legacy/frozen.sh" ]] \
    && assert_pass "[#1802/WIDEN] legacy/frozen.sh is checked out" \
    || assert_fail "[#1802/WIDEN] legacy/frozen.sh must be checked out after widening" "$(<"$_ERR")"
[[ ! -f "$_WTW/legacy/sub/other.sh" ]] \
    && assert_pass "[#1802/WIDEN] legacy/sub/other.sh stays excluded" \
    || assert_fail "[#1802/WIDEN] widening one path must not re-include the rest of legacy/"
# Idempotent: the same widening twice is rc=0 and adds no second pattern line.
_list1="$(git -C "$_WTW" sparse-checkout list 2>&1)"
zbuild_worktree_include_legacy_path "$_WTW" "legacy/frozen.sh" >/dev/null 2>"$_ERR"; _rc=$?
assert_eq "[#1802/WIDEN] a second identical widening returns 0" "0" "$_rc"
assert_eq "[#1802/WIDEN] a second identical widening leaves the pattern set unchanged" \
    "$_list1" "$(git -C "$_WTW" sparse-checkout list 2>&1)"

# ── RESUME: acquire's reuse path keeps the widening ──────────────────────────
_again="$(zbuild_worktree_acquire widen "$_R" 2>"$_ERR")"; _rc=$?
assert_eq "[#1802/RESUME] re-acquire returns 0" "0" "$_rc"
assert_eq "[#1802/RESUME] re-acquire lands in the same tree" "$_WTW" "$_again"
[[ -f "$_WTW/legacy/frozen.sh" ]] \
    && assert_pass "[#1802/RESUME] widened legacy/frozen.sh survives re-acquire" \
    || assert_fail "[#1802/RESUME] re-acquire wiped the keeper's widening" \
        "$(git -C "$_WTW" sparse-checkout list 2>&1)"
[[ ! -f "$_WTW/legacy/sub/other.sh" && -f "$_WTW/legacy/migrated/tombstone.md" ]] \
    && assert_pass "[#1802/RESUME] rest of legacy/ excluded, migrated/ kept, after re-acquire" \
    || assert_fail "[#1802/RESUME] base patterns must still hold after re-acquire"

# ── WIDEN: git rm of the widened path works inside the worktree ──────────────
git -C "$_WTW" rm -q legacy/frozen.sh 2>"$_ERR"; _rc=$?
assert_eq "[#1802/WIDEN] git rm of the widened legacy path succeeds" "0" "$_rc"
assert_contains "[#1802/WIDEN] the removal is staged" \
    "$(git -C "$_WTW" diff --cached --name-status)" "legacy/frozen.sh"
git -C "$_WTW" reset -q --hard

# ── RESUME: enter's reuse path keeps the widening ────────────────────────────
_WTE="$(cd "$_R" && zbuild_worktree_enter widen-enter zbuild/widen-enter create 2>/dev/null)"
# A directory widening (trailing slash) is accepted: it names one subtree.
zbuild_worktree_include_legacy_path "$_WTE" "legacy/sub/" >/dev/null 2>"$_ERR"; _rc=$?
assert_eq "[#1802/WIDEN] accepts a directory, legacy/sub/" "0" "$_rc"
_again="$(cd "$_R" && zbuild_worktree_enter widen-enter zbuild/widen-enter create 2>"$_ERR")"; _rc=$?
assert_eq "[#1802/RESUME] re-enter returns 0" "0" "$_rc"
[[ -f "$_WTE/legacy/sub/other.sh" && ! -f "$_WTE/legacy/frozen.sh" ]] \
    && assert_pass "[#1802/RESUME] widening survives re-enter; the rest stays excluded" \
    || assert_fail "[#1802/RESUME] re-enter must keep the widening and the exclusion" \
        "$(git -C "$_WTE" sparse-checkout list 2>&1)"

# ── CONFLICT: re-acquire over a different, pre-existing sparse config ────────
_base=$'/*\n!/legacy/\n/legacy/migrated/'
_WTC="$TEST_TEMP_DIR/wt/conflict"
git -C "$_R" worktree add -q --detach "$_WTC"
git -C "$_WTC" sparse-checkout set --no-cone -- '/src/'
zbuild_worktree_acquire conflict "$_R" >/dev/null 2>"$_ERR"; _rc=$?
assert_eq "[#1802/CONFLICT] acquire over a foreign sparse config returns 0" "0" "$_rc"
assert_eq "[#1802/CONFLICT] the foreign pattern set is replaced by exactly the base set" \
    "$_base" "$(git -C "$_WTC" sparse-checkout list 2>&1)"
[[ -f "$_WTC/src/work.sh" ]] && [[ ! -f "$_WTC/legacy/frozen.sh" ]] \
    && [[ -f "$_WTC/legacy/migrated/tombstone.md" ]] \
    && assert_pass "[#1802/CONFLICT] tree matches the base set (src/ in, legacy/ out, migrated/ in)" \
    || assert_fail "[#1802/CONFLICT] tree does not match the base pattern set"

git -C "$_WTC" sparse-checkout set --no-cone -- '/src/' '!/src/' '/legacy/sub/other.sh' '/legacy/*'
zbuild_worktree_acquire conflict "$_R" >/dev/null 2>"$_ERR"; _rc=$?
assert_eq "[#1802/CONFLICT] acquire over a mixed config returns 0" "0" "$_rc"
assert_eq "[#1802/CONFLICT] only a valid keeper widening is carried over the base set" \
    "$_base"$'\n/legacy/sub/other.sh' "$(git -C "$_WTC" sparse-checkout list 2>&1)"

# ── main checkout is never made sparse ───────────────────────────────────────
[[ -f "$_R/legacy/frozen.sh" && -f "$_R/legacy/sub/other.sh" ]] \
    && assert_pass "[#1802/WTCONFIG] the main checkout still has all of legacy/" \
    || assert_fail "[#1802/WTCONFIG] the main checkout was made sparse"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
