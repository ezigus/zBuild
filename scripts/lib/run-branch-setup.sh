#!/usr/bin/env bash
# scripts/lib/run-branch-setup.sh — the engine sets the run's branch and the
# commit it started from (#2367, ADR-052, ADR-050 §10).
#
# Plumbing every repository needs, and the engine needs both to save the work.
# Intake used to decide them and write intake-branch.txt / intake-baseline-ref.txt,
# which build, pr, merge and the engine's own save step opened: the engine
# depending on a stage. Hydrate runs before intake, so in #1801 the end of
# hydrate pushed main over the issue branch — nothing had set the starting
# commit yet. Now the engine does it when the run starts, before any stage, and
# every stage gets them as ZBUILD_RUN_BRANCH and ZBUILD_RUN_START_COMMIT.
#
# The name: ZBUILD_WORKSPACE_BRANCH (a setting; CI sets it), else the
# repository's .zbuild/branch, else the template's `branch:`, else
# zbuild/{key}. {key} is the run's identity (zbuild_run_key: issue-<n>).
#
# Sourced library: no set -euo pipefail.

# ZBUILD_RUN_BRANCH_FETCH_FAILED is read by the runner (SC2034 false positive).
# shellcheck disable=SC2034

[[ -n "${_ZBUILD_RUN_BRANCH_SETUP_LOADED:-}" ]] && return 0
_ZBUILD_RUN_BRANCH_SETUP_LOADED=1

_ZBUILD_RUN_BRANCH_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./default-branch.sh
source "$_ZBUILD_RUN_BRANCH_SETUP_DIR/default-branch.sh"
# shellcheck source=./identity.sh
source "$_ZBUILD_RUN_BRANCH_SETUP_DIR/identity.sh"

# Set by zbuild_run_branch_setup when the remote branch could not be fetched,
# so the caller can say the remote is not responding.
ZBUILD_RUN_BRANCH_FETCH_FAILED=""

_rb_emit() { declare -F emit_event >/dev/null 2>&1 && emit_event "$@" 2>/dev/null; return 0; }

# zbuild_run_branch_name <issue> <goal> <pattern> <repo> — the run's branch.
zbuild_run_branch_name() {
    local issue="$1" goal="$2" pattern="$3" repo="$4" key line
    if [[ -n "${ZBUILD_WORKSPACE_BRANCH:-}" ]]; then
        printf '%s' "$ZBUILD_WORKSPACE_BRANCH"; return 0
    fi
    if [[ -n "$repo" && -s "$repo/.zbuild/branch" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"; line="${line//[[:space:]]/}"
            [[ -n "$line" ]] && { pattern="$line"; break; }
        done < "$repo/.zbuild/branch"
    fi
    [[ -n "$pattern" ]] || pattern="zbuild/{key}"
    key="$(zbuild_run_key "$issue" "$goal" 2>/dev/null || true)"
    [[ -n "$key" ]] || key="issue-0"
    printf '%s' "${pattern//\{key\}/$key}"
}

# zbuild_run_branch_valid <name> — rc 0 if safe. Rejects empty, a leading '-',
# '..' (path traversal), and shell or refname metacharacters.
zbuild_run_branch_valid() {
    local n="$1"
    [[ -n "${n//[[:space:]]/}" && "$n" != -* && "$n" != *..* ]] || return 1
    # shellcheck disable=SC1003  # '\' is a literal backslash, not an escaped quote
    case "$n" in
        *' '*|*$'\t'*|*$'\n'*|*'~'*|*'^'*|*':'*|*'?'*|*'*'*|*'['*|*'\'*) return 1 ;;
    esac
    return 0
}

# zbuild_run_branch_preflight <main_repo> — refuse a missing git, a directory
# that is not a repository, one mid-rebase/merge/bisect, or a dirty tree
# (ZBUILD_ALLOW_DIRTY=1 overrides). Checks the operator's checkout, not the
# run's worktree: a fresh worktree is always clean.
zbuild_run_branch_preflight() {
    local root="${1:-$PWD}" git_dir mid=""
    [[ -d "$root" ]] || root="$PWD"
    if ! command -v git >/dev/null 2>&1; then
        error "run branch: git not found in PATH"
        _rb_emit "pipeline.branch.refused" "reason=git_not_found"; return 1
    fi
    if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
        error "run branch: $root is not a git repository"
        _rb_emit "pipeline.branch.refused" "reason=not_a_git_repo"; return 1
    fi
    git_dir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)"
    if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then mid="rebase"
    elif [[ -f "$git_dir/MERGE_HEAD" ]]; then mid="merge"
    elif [[ -f "$git_dir/BISECT_LOG" ]]; then mid="bisect"; fi
    if [[ -n "$mid" ]]; then
        error "run branch: refusing — the repository is mid-$mid"
        _rb_emit "pipeline.branch.refused" "reason=repo_state_$mid"; return 1
    fi
    local dirty=""
    [[ "${ZBUILD_ALLOW_DIRTY:-${ZBUILD_INTAKE_ALLOW_DIRTY:-0}}" == "1" ]] \
        || dirty="$(git -C "$root" status --porcelain 2>/dev/null)"
    if [[ -n "$dirty" ]]; then
        error "run branch: refusing — $root has uncommitted changes (set ZBUILD_ALLOW_DIRTY=1 to override):"
        error "  ${dirty:0:400}"
        _rb_emit "pipeline.branch.refused" "reason=working_tree_dirty"; return 1
    fi
    return 0
}

# _rb_holder <branch> <checkout_stderr> — the worktree holding <branch>, or "".
_rb_holder() {
    local target="$1" co_err="$2" holder _tail
    case "$co_err" in
        *"is already checked out at"*|*"is already used by worktree at"*) ;;
        *) return 0 ;;
    esac
    # The branch goes in via ENVIRON, not -v (awk expands escapes in -v).
    holder="$(export _zb_b="refs/heads/$target"
        _rb_git worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{w=$2} /^branch /{if ($2==ENVIRON["_zb_b"]) {print w; exit}}')"
    if [[ -z "$holder" ]]; then
        _tail="${co_err##* at \'}"
        [[ "$_tail" != "$co_err" ]] && holder="${_tail%%\'*}"
    fi
    printf '%s' "$holder"
}

# _rb_on <branch> — rc 0 when HEAD is on <branch>.
_rb_on() { [[ "$(_rb_git symbolic-ref --short HEAD 2>/dev/null)" == "$1" ]]; }

# _rb_git — git in the run's repository (ZBUILD_REPO_ROOT; the current folder
# when unset), never the folder the runner happened to start in.
_rb_git() { git -C "${ZBUILD_REPO_ROOT:-$PWD}" "$@"; }

# zbuild_run_branch_checkout <branch> — put HEAD on <branch> in the current
# tree: already there, an existing local branch (releasing a finished run's
# worktree that holds it), the remote's branch with earlier work, or a new one.
# Sets ZBUILD_RUN_BRANCH_OUTCOME (noop|reused|adopted|created).
zbuild_run_branch_checkout() {
    local target="$1" co_err holder
    ZBUILD_RUN_BRANCH_OUTCOME=""
    if _rb_on "$target"; then ZBUILD_RUN_BRANCH_OUTCOME="noop"; return 0; fi
    if _rb_git show-ref --verify --quiet "refs/heads/$target"; then
        # LC_ALL=C: _rb_holder reads git's English message.
        if ! co_err="$(LC_ALL=C _rb_git checkout "$target" 2>&1 >/dev/null)"; then
            holder="$(_rb_holder "$target" "$co_err")"
            declare -F zbuild_worktree_reclaim_dead >/dev/null 2>&1 \
                || source "$_ZBUILD_RUN_BRANCH_SETUP_DIR/worktree.sh" 2>/dev/null || true
            if [[ -n "$holder" ]] && zbuild_worktree_reclaim_dead "$holder" >/dev/null 2>&1; then
                _rb_emit "pipeline.branch.reclaimed" "branch=$target" "holder=$holder"
                co_err="$(LC_ALL=C _rb_git checkout "$target" 2>&1 >/dev/null)" || holder=""
            fi
            if ! _rb_on "$target"; then
                if [[ -n "$holder" ]]; then
                    error "run branch: '$target' is already checked out at $holder"
                    error "  held by: $(zbuild_worktree_owner "$holder" 2>/dev/null || echo unknown)"
                    error "  reclaim:  zbuild cleanup --worktrees --age-days 0 --apply"
                    _rb_emit "pipeline.branch.refused" "branch=$target" "reason=branch_held_by_worktree" "holder=$holder"
                else
                    error "run branch: checkout of '$target' failed: ${co_err:-<no git output>}"
                    _rb_emit "pipeline.branch.refused" "branch=$target" "reason=checkout_failed"
                fi
                return 1
            fi
        fi
        ZBUILD_RUN_BRANCH_OUTCOME="reused"; return 0
    fi
    if _rb_git show-ref --verify --quiet "refs/remotes/origin/$target"; then
        if ! _rb_git fetch origin "$target:$target" >/dev/null 2>&1; then
            ZBUILD_RUN_BRANCH_FETCH_FAILED="$target"
            error "run branch: could not fetch the remote branch '$target'"
            _rb_emit "pipeline.branch.refused" "branch=$target" "reason=fetch_failed"
            return 1
        fi
        if ! _rb_git checkout "$target" >/dev/null 2>&1 || ! _rb_on "$target"; then
            error "run branch: checkout of the fetched branch '$target' failed"
            _rb_emit "pipeline.branch.refused" "branch=$target" "reason=checkout_failed"
            return 1
        fi
        ZBUILD_RUN_BRANCH_OUTCOME="adopted"; return 0
    fi
    if ! _rb_git checkout -b "$target" >/dev/null 2>&1 || ! _rb_on "$target"; then
        error "run branch: could not create '$target'"
        _rb_emit "pipeline.branch.refused" "branch=$target" "reason=branch_create_failed"
        return 1
    fi
    ZBUILD_RUN_BRANCH_OUTCOME="created"
    return 0
}

# zbuild_run_branch_setup <state_dir> <issue> <goal> <pattern> — called by the
# runner in the run's tree, before any stage. Exports ZBUILD_RUN_BRANCH,
# ZBUILD_RUN_START_COMMIT and ZBUILD_RUN_UNTRACKED_AT_START (a file listing the
# untracked files already there, NUL-separated, so build never counts a stray
# from an earlier run as its own). rc 1 refuses the run.
zbuild_run_branch_setup() {
    local state_dir="$1" issue="$2" goal="$3" pattern="$4" main_repo branch start untracked
    ZBUILD_RUN_BRANCH_FETCH_FAILED=""
    main_repo="${ZBUILD_MAIN_REPO_ROOT:-$PWD}"
    branch="$(zbuild_run_branch_name "$issue" "$goal" "$pattern" "$main_repo")"
    if ! zbuild_run_branch_valid "$branch"; then
        error "run branch: '$branch' is not a valid branch name"
        _rb_emit "pipeline.branch.refused" "branch=$branch" "reason=invalid_branch_name"
        return 1
    fi
    zbuild_run_branch_preflight "$main_repo" || return 1
    zbuild_run_branch_checkout "$branch" || return 1
    start="$(_rb_git rev-parse HEAD 2>/dev/null || true)"
    untracked="$state_dir/runtime/untracked-at-start"
    mkdir -p "${untracked%/*}" 2>/dev/null || true
    _rb_git ls-files --others --exclude-standard -z > "$untracked" 2>/dev/null || : > "$untracked"
    export ZBUILD_RUN_BRANCH="$branch" ZBUILD_RUN_START_COMMIT="$start" \
        ZBUILD_RUN_UNTRACKED_AT_START="$untracked"
    # How far the branch is ahead of the default branch (earlier runs' work).
    local trunk ahead="unknown"
    trunk="$(zbuild_resolve_default_branch "${ZBUILD_REPO_ROOT:-$PWD}")"
    [[ -n "$trunk" ]] && ahead="$(_rb_git rev-list --count "$trunk..$branch" 2>/dev/null || echo unknown)"
    _rb_emit "pipeline.branch.ready" "branch=$branch" "outcome=$ZBUILD_RUN_BRANCH_OUTCOME" \
        "start=$start" "ahead_count=$ahead"
    if [[ -f "$state_dir/pipeline-state.json" ]] && declare -F _set_pipeline_branch >/dev/null 2>&1; then
        _set_pipeline_branch "$state_dir/pipeline-state.json" "$branch" 2>/dev/null || true
    fi
    return 0
}
