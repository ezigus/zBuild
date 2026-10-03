#!/usr/bin/env bash
# tests/unit/head-on-run-branch-test.sh — a run's commits stay on the run's
# branch, and nothing rewinds the remote over them (#2264).
#
# Why: in #1844 run 37066147994 HEAD left the run branch mid-run (detached at
# the branch tip). Every later commit — two builds, a test-author — landed on
# HEAD only; the branch ref stayed at the first commit. The runner's stage-end
# push sends HEAD, so origin was right until the end; then the post-run step
# force-pushed the STALE ref over it (`+ 5d9ca1bc...319da3c8 (forced update)`)
# and the run's work was gone from the branch.
#
# H1 [change] HEAD detached ahead of the branch → the branch moves to HEAD and
#             HEAD is on it again; the working tree is untouched
# H2 [guard]  HEAD already on the branch → nothing changes
# H3 [guard]  the branch has a commit HEAD lacks → nothing moves (no commit is
#             ever dropped), the outcome says so
# H4 [change] no branch ref at all → it is created at HEAD
# H5 [change] HEAD on another branch that descends from the run branch → back
#             on the run branch, at HEAD
# R1 [change] a stage end puts HEAD back on the run branch and says which stage
#             left it off
# R2 [change] a stage end that cannot (diverged) moves nothing and says so
# B1 [change] the post-run push refuses a ref the remote is ahead of
# B2 [guard]  a ref ahead of the remote is pushed
# B3 [guard]  a ref that diverged from the remote (a re-run that started over)
#             still replaces it
# B4 [guard]  a branch the remote lacks is pushed
# B5 [change] the remote is ahead but its commit cannot be fetched → refuse,
#             never push blind (review on #2266)
# W1 [change] the workflow's post-run push goes through the refusing helper
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a run's commits stay on its branch; nothing rewinds the remote (#2264)"
setup_test_env "head-on-run-branch"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"

# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"
set +e   # runner.sh turns errexit on; assertions must all run

B="zbuild/issue-9-ci"
_g() { git -C "$1" "${@:2}"; }
_sha() { git -C "$1" rev-parse -q --verify "$2" 2>/dev/null; }
_on() { git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null; }
_commit() { printf '%s\n' "$2" >> "$1/f"; _g "$1" add f; _g "$1" commit -q -m "$2"; }

# _repo <dir> — main + run branch B with one commit, checked out on B.
_repo() {
    mkdir -p "$1"
    (
        cd "$1" || exit 1
        git init -q -b main .
        git config user.email t@e.st; git config user.name t
        : > f; git add f; git commit -q -m init
        git checkout -q -b "$B"
    ) >/dev/null 2>&1
    _commit "$1" c1 >/dev/null 2>&1
}

# _detach_ahead <dir> — the #1844 shape: detach at the branch tip, commit twice.
_detach_ahead() { _g "$1" checkout -q --detach; _commit "$1" c2; _commit "$1" c3; }

print_test_section "H: keeping HEAD on the run branch"
# shellcheck source=../../scripts/lib/run-branch.sh
source "$REPO_ROOT/scripts/lib/run-branch.sh" 2>/dev/null

R="$TEST_TEMP_DIR/h1"; _repo "$R"; _detach_ahead "$R" >/dev/null 2>&1
HEAD1="$(_sha "$R" HEAD)"; printf 'wip\n' > "$R/untracked.txt"
zbuild_keep_head_on_branch "$R" "$B" >/dev/null 2>&1
assert_eq "[H1] the branch moves to HEAD" "$HEAD1" "$(_sha "$R" "refs/heads/$B")"
assert_eq "[H1] HEAD is on the branch again" "$B" "$(_on "$R")"
assert_eq "[H1] the outcome is reattached" "reattached" "${ZBUILD_HEAD_OUTCOME:-}"
assert_eq "[H1] the working tree is untouched" "wip" "$(cat "$R/untracked.txt" 2>/dev/null)"

R="$TEST_TEMP_DIR/h2"; _repo "$R"; BEFORE="$(_sha "$R" HEAD)"
zbuild_keep_head_on_branch "$R" "$B" >/dev/null 2>&1; rc=$?
assert_eq "[H2] on the branch → rc 0" "0" "$rc"
assert_eq "[H2] the outcome is on_branch" "on_branch" "${ZBUILD_HEAD_OUTCOME:-}"
assert_eq "[H2] nothing moved" "$BEFORE" "$(_sha "$R" "refs/heads/$B")"

R="$TEST_TEMP_DIR/h3"; _repo "$R"
_g "$R" checkout -q --detach >/dev/null 2>&1; _commit "$R" headonly >/dev/null 2>&1
_g "$R" checkout -q "$B" >/dev/null 2>&1; _commit "$R" branchonly >/dev/null 2>&1
BR="$(_sha "$R" "refs/heads/$B")"; _g "$R" checkout -q --detach HEAD~1 >/dev/null 2>&1
_g "$R" checkout -q --detach "$(git -C "$R" rev-list --all --grep=headonly -n1)" >/dev/null 2>&1
HD="$(_sha "$R" HEAD)"
zbuild_keep_head_on_branch "$R" "$B" >/dev/null 2>&1; rc=$?
assert_eq "[H3] diverged → rc 1" "1" "$rc"
assert_eq "[H3] the outcome is diverged" "diverged" "${ZBUILD_HEAD_OUTCOME:-}"
assert_eq "[H3] the branch keeps its own commit" "$BR" "$(_sha "$R" "refs/heads/$B")"
assert_eq "[H3] HEAD keeps its commit" "$HD" "$(_sha "$R" HEAD)"

R="$TEST_TEMP_DIR/h4"; _repo "$R"; _g "$R" checkout -q --detach >/dev/null 2>&1
_g "$R" branch -q -D "$B" >/dev/null 2>&1; HD="$(_sha "$R" HEAD)"
zbuild_keep_head_on_branch "$R" "$B" >/dev/null 2>&1
assert_eq "[H4] a missing branch is created at HEAD" "$HD" "$(_sha "$R" "refs/heads/$B")"
assert_eq "[H4] HEAD is on it" "$B" "$(_on "$R")"

R="$TEST_TEMP_DIR/h5"; _repo "$R"; _g "$R" checkout -q -b stray >/dev/null 2>&1
_commit "$R" onstray >/dev/null 2>&1; HD="$(_sha "$R" HEAD)"
zbuild_keep_head_on_branch "$R" "$B" >/dev/null 2>&1
assert_eq "[H5] the run branch moves to HEAD" "$HD" "$(_sha "$R" "refs/heads/$B")"
assert_eq "[H5] HEAD is on the run branch" "$B" "$(_on "$R")"

print_test_section "R: every stage end keeps HEAD on the run branch"
R="$TEST_TEMP_DIR/r1"; _repo "$R"; _detach_ahead "$R" >/dev/null 2>&1; HD="$(_sha "$R" HEAD)"
STATE="$TEST_TEMP_DIR/state-r1"; mkdir -p "$STATE/artifacts"; printf '%s\n' "$B" > "$STATE/intake-branch.txt"
: > "$ZBUILD_EVENTS_JSONL"
( export ZBUILD_REPO_ROOT="$R"; _runner_issue=""; _runner_snapshot_artifacts "$STATE" build ) >/dev/null 2>&1
assert_eq "[R1] the run branch holds the stage's commits" "$HD" "$(_sha "$R" "refs/heads/$B")"
assert_eq "[R1] HEAD is on the run branch" "$B" "$(_on "$R")"
assert_eq "[R1] an event names the stage that left HEAD off the branch" "build" \
    "$(jq -r 'select(.type=="pipeline.head.reattached") | .data.stage' "$ZBUILD_EVENTS_JSONL" 2>/dev/null)"

R="$TEST_TEMP_DIR/r2"; _repo "$R"
_g "$R" checkout -q --detach >/dev/null 2>&1; _commit "$R" headonly >/dev/null 2>&1; HD="$(_sha "$R" HEAD)"
_g "$R" checkout -q "$B" >/dev/null 2>&1; _commit "$R" branchonly >/dev/null 2>&1; BR="$(_sha "$R" HEAD)"
_g "$R" checkout -q --detach "$HD" >/dev/null 2>&1
STATE="$TEST_TEMP_DIR/state-r2"; mkdir -p "$STATE/artifacts"; printf '%s\n' "$B" > "$STATE/intake-branch.txt"
: > "$ZBUILD_EVENTS_JSONL"
( export ZBUILD_REPO_ROOT="$R"; _runner_issue=""; _runner_snapshot_artifacts "$STATE" build ) >/dev/null 2>&1
assert_eq "[R2] the branch keeps its own commit" "$BR" "$(_sha "$R" "refs/heads/$B")"
assert_eq "[R2] HEAD keeps its commit" "$HD" "$(_sha "$R" HEAD)"
assert_eq "[R2] an event says the branch and HEAD diverged" "build" \
    "$(jq -r 'select(.type=="pipeline.head.diverged") | .data.stage' "$ZBUILD_EVENTS_JSONL" 2>/dev/null)"

print_test_section "B: the post-run push never rewinds the remote"
# shellcheck source=../../scripts/lib/git-remote.sh
source "$REPO_ROOT/scripts/lib/git-remote.sh"
_remote_pair() {   # _remote_pair <name> → $RM (bare) and $RP (clone on B, pushed)
    RM="$TEST_TEMP_DIR/$1.git"; RP="$TEST_TEMP_DIR/$1"
    git init -q --bare "$RM"; _repo "$RP"
    _g "$RP" remote add origin "$RM"; _g "$RP" push -q origin main "$B" >/dev/null 2>&1
}
_push() { ( cd "$RP" && zbuild_push_branch_no_rewind "$B" ) >/dev/null 2>&1; }

_remote_pair b1; _detach_ahead "$RP" >/dev/null 2>&1
_g "$RP" push -q --force origin "HEAD:refs/heads/$B" >/dev/null 2>&1   # the stage-end push
AHEAD="$(_sha "$RP" HEAD)"; _g "$RP" checkout -q "$B" >/dev/null 2>&1  # local ref is stale
_push; rc=$?
assert_eq "[B1] a stale ref is refused (rc ≠ 0)" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "[B1] the remote keeps the newer commit" "$AHEAD" "$(_sha "$RM" "refs/heads/$B")"

_remote_pair b2; _commit "$RP" more >/dev/null 2>&1; NEW="$(_sha "$RP" HEAD)"
_push
assert_eq "[B2] a ref ahead of the remote is pushed" "$NEW" "$(_sha "$RM" "refs/heads/$B")"

_remote_pair b3; _g "$RP" reset -q --hard main >/dev/null 2>&1; _commit "$RP" restart >/dev/null 2>&1
NEW="$(_sha "$RP" HEAD)"; _push
assert_eq "[B3] a diverged ref (a run that started over) replaces the remote" "$NEW" "$(_sha "$RM" "refs/heads/$B")"

_remote_pair b4; _g "$RP" push -q origin --delete "$B" >/dev/null 2>&1; NEW="$(_sha "$RP" HEAD)"
_push
assert_eq "[B4] a branch the remote lacks is pushed" "$NEW" "$(_sha "$RM" "refs/heads/$B")"

# B5: ls-remote works, fetch fails, and the remote's commit is not local.
_remote_pair b5; NEWER="$TEST_TEMP_DIR/b5-other"; git clone -q "$RM" "$NEWER" >/dev/null 2>&1
( cd "$NEWER" && git config user.email t@e.st && git config user.name t && git checkout -q "$B" \
    && printf 'n\n' >> f && git add f && git commit -q -m newer && git push -q origin "$B" ) >/dev/null 2>&1
AHEAD="$(_sha "$RM" "refs/heads/$B")"
REAL_GIT="$(command -v git)"; mkdir -p "$TEST_TEMP_DIR/nofetch"
printf '#!/usr/bin/env bash\n[[ "$1" == fetch ]] && exit 1\nexec "%s" "$@"\n' "$REAL_GIT" > "$TEST_TEMP_DIR/nofetch/git"
chmod +x "$TEST_TEMP_DIR/nofetch/git"
( cd "$RP" && PATH="$TEST_TEMP_DIR/nofetch:$PATH" zbuild_push_branch_no_rewind "$B" ) >/dev/null 2>&1; rc=$?
assert_eq "[B5] an unfetchable remote tip is refused (rc 3)" "3" "$rc"
assert_eq "[B5] the remote keeps its commit" "$AHEAD" "$(_sha "$RM" "refs/heads/$B")"

print_test_section "W: the workflow uses it"
WF="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"
if grep -q 'zbuild_push_branch_no_rewind' "$WF" && ! grep -qE 'git push --force origin "refs/heads/\$branch' "$WF"; then
    assert_pass "[W1] the post-run work-branch push goes through zbuild_push_branch_no_rewind"
else
    assert_fail "[W1] the post-run work-branch push goes through zbuild_push_branch_no_rewind" \
        "the workflow still force-pushes refs/heads/\$branch directly"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
