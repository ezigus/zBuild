#!/usr/bin/env bash
# tests/unit/cleanup-forgotten-trees-test.sh — `zbuild cleanup --worktrees`
# reclaims an issue's worktree folder that git no longer lists (#2541, ADR-059).
#
# Why: _cleanup_scan_worktrees walked `git worktree list` only, so an
# issues/<N>/worktree folder git had forgotten (its registration pruned, or
# made by an older install) was never even looked at:
# ~/.zbuild/repos/ezigus/zBuild/issues/2137/worktree sat from September to
# November while `zbuild cleanup --worktrees` said "nothing to clean".
#
# G1 [change] a forgotten issue tree older than the age limit is planned for
#             pruning, saying git no longer lists it
# G2 [change] applying the plan removes it
# G3 [change] a forgotten tree newer than the limit is kept, and says why
# G4 [change] a forgotten tree whose issue a live run holds is kept, and says why
# G5 [done]   a tree git still lists is planned once, the way it always was
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "cleanup reclaims an issue tree git has forgotten (#2541)"
setup_test_env "cleanup-forgotten-trees"

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/cleanup.sh"
# shellcheck source=../../scripts/lib/worktree.sh
source "$REPO_ROOT/scripts/lib/worktree.sh"
set +e

export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/rr" ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state"
R="$TEST_TEMP_DIR/repo"; mkdir -p "$R"
git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
: > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm init
LR="$(cd "$R" && zbuild_layout_worktree_repo_root)"
# As git and the scanner report it (/private/var/... on macOS).
mkdir -p "$LR"; LR="$(cd "$LR" && pwd -P)"

_backdate() {   # <path> <age_days> — any age above 0 is the year 2000
    [[ "$2" -gt 0 ]] && touch -t 200001010000 "$1" 2>/dev/null
    return 0
}
_forgotten() {   # <issue> <age_days> — a worktree folder git does not list
    local wt="$LR/issues/$1/worktree"
    mkdir -p "$wt"; printf 'left\n' > "$wt/file.txt"
    _backdate "$wt" "$2"
    printf '%s' "$wt"
}
_line() { (cd "$R" && _cleanup_scan_worktrees 14) | awk -F'\t' -v p="$1" '$1 == p'; }

OLD="$(_forgotten 501 30)"
NEW="$(_forgotten 502 0)"
HELD="$(_forgotten 503 30)"
_lk="$(zbuild_issue_lock_path issue-503)"; mkdir -p "$(dirname "$_lk")"
printf 'run=held-run pid=%s state_file=\n' "$$" > "$_lk"
LISTED="$LR/issues/504/worktree"; mkdir -p "$(dirname "$LISTED")"
git -C "$R" worktree add -q --detach "$LISTED" >/dev/null 2>&1
_backdate "$LISTED" 30

_l="$(_line "$OLD")"
assert_contains "[G1] the old forgotten tree is planned for pruning" "$_l" "$OLD	prune"
assert_contains "[G1] ...saying git no longer lists it" "$_l" "git no longer lists"
assert_contains "[G3] the new forgotten tree is kept as too new" "$(_line "$NEW")" "skip	newer than"
assert_contains "[G4] the held one is kept: a live run holds its issue" "$(_line "$HELD")" "skip	active run holds issue-503"
assert_eq "[G5] the listed tree is planned once" "1" "$(_line "$LISTED" | /usr/bin/grep -c prune)"

(cd "$R" && _cleanup_apply_worktree_plan "$OLD") >/dev/null 2>&1
assert_eq "[G2] applying the plan removes the forgotten tree" "0" "$([[ -d "$OLD" ]] && echo 1 || echo 0)"
assert_eq "[G2] ...and leaves the others" "111" \
    "$([[ -d "$NEW" ]] && echo 1 || echo 0)$([[ -d "$HELD" ]] && echo 1 || echo 0)$([[ -d "$LISTED" ]] && echo 1 || echo 0)"

git -C "$R" worktree remove --force "$LISTED" >/dev/null 2>&1
cleanup_test_env
print_test_results
exit $((FAIL > 0))
