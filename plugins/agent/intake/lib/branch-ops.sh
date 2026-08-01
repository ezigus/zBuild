#!/usr/bin/env bash
# plugins/agent/intake/lib/branch-ops.sh — branch preflight, checkout, and workspace creation

[[ -n "${_ZBUILD_INTAKE_BRANCH_OPS_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_BRANCH_OPS_LOADED=1

# ═══════════════════════════════════════════════════════════════════════════
# Issue #484 — Branch operations (fail-closed)
#
# Mirrors legacy/scripts/lib/pipeline-stages-intake.sh:66-94 BUT replaces
# the `git checkout || true` silent-failure pattern with strict error
# classification + named refusal events. Branch format diverges from
# legacy's `feature/slug-N` per stakeholder decision: `zbuild/issue-N-slug`
# (issue number BEFORE slug).
# ═══════════════════════════════════════════════════════════════════════════

# _intake_check_preflight
# Validates the working-tree state before any branch op. Emits a refusal
# event on failure and returns 2; returns 0 if all clear.
#
# ADR-052 (#1640): targets the MAIN checkout, not $PWD. Since the engine re-roots
# into the run's worktree before intake runs, $PWD is a tree the engine just
# created — always clean, never mid-rebase — so preflighting it would be vacuous
# and would quietly make worktree mode more permissive than the in-place path.
# The operator's tree is the one whose state should stop a run. Falls back to $PWD
# when ZBUILD_MAIN_REPO_ROOT is unset (in-place runs, direct callers, unit tests).
_intake_check_preflight() {
    # 1) git binary present
    if ! command -v git >/dev/null 2>&1; then
        error "intake_branch: git not found in PATH"
        emit_event "intake.refused.git_unavailable" \
            "plugin=intake" "reason=git_not_found"
        return 2
    fi
    local _pf_root="${ZBUILD_MAIN_REPO_ROOT:-$PWD}"
    [[ -d "$_pf_root" ]] || _pf_root="$PWD"
    # 2) inside a git repo
    if ! git -C "$_pf_root" rev-parse --git-dir >/dev/null 2>&1; then
        error "intake_branch: not inside a git repository"
        emit_event "intake.refused.git_unavailable" \
            "plugin=intake" "reason=not_a_git_repo"
        return 2
    fi
    # 3) repo not mid-rebase/bisect/merge
    local git_dir
    # --absolute-git-dir needs git >= 2.13; on older git it exits non-zero and the
    # 2>/dev/null would leave git_dir empty, silently disabling every mid-state
    # guard below. Fall back to --git-dir, which with -C returns a path RELATIVE to
    # $_pf_root (verified: it prints a bare ".git"), so absolutize it or the -d/-f
    # tests would resolve against the worktree CWD (PR #1643 review).
    git_dir="$(git -C "$_pf_root" rev-parse --absolute-git-dir 2>/dev/null \
               || git -C "$_pf_root" rev-parse --git-dir 2>/dev/null)"
    [[ -z "$git_dir" || "$git_dir" == /* ]] || git_dir="${_pf_root%/}/$git_dir"
    local mid_state=""
    if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
        mid_state="rebase"
    elif [[ -f "$git_dir/MERGE_HEAD" ]]; then
        mid_state="merge"
    elif [[ -f "$git_dir/BISECT_LOG" ]]; then
        mid_state="bisect"
    fi
    if [[ -n "$mid_state" ]]; then
        error "intake_branch: refusing — repository is mid-${mid_state}"
        emit_event "intake.refused.repo_state" \
            "plugin=intake" "reason=repo_state_${mid_state}"
        return 2
    fi
    # 4) dirty working tree (unless override). Use `git status --porcelain` —
    #    non-empty output means tracked changes or untracked files exist.
    if [[ "${ZBUILD_INTAKE_ALLOW_DIRTY:-0}" != "1" ]]; then
        local dirty
        dirty="$(git -C "$_pf_root" status --porcelain 2>/dev/null)"
        if [[ -n "$dirty" ]]; then
            error "intake_branch: refusing — working tree is dirty (set ZBUILD_INTAKE_ALLOW_DIRTY=1 to override)"
            emit_event "intake.refused.dirty_tree" \
                "plugin=intake" "reason=working_tree_dirty"
            return 2
        fi
    fi
    return 0
}

# _intake_resolve_default_branch [repo] — resolve the remote default branch name.
# Resolution order: (1) refs/remotes/origin/HEAD symbolic-ref stripped of
# "origin/", (2) recognized remote refs: main/master/develop/trunk in order,
# (3) local refs/heads/main then refs/heads/master. Returns empty string (no
# output, rc=0) when nothing resolves — caller emits ahead_count=unknown.
#
# Every git call is anchored with `git -C` so the repo is explicit rather than
# whatever $PWD happens to be, matching _intake_check_preflight's ZBUILD_MAIN_
# REPO_ROOT handling. Defaults to $PWD, so bare calls behave as before.
#
# The prefix strip is `#origin/` (not `##*/`) on purpose: the symbolic-ref query
# is pinned to refs/remotes/origin/HEAD, so the answer is always "origin/<name>",
# and <name> may itself contain slashes (e.g. "release/v2"). Stripping to the
# last slash would truncate those to "v2".
_intake_resolve_default_branch() {
    local repo="${1:-$PWD}"
    local ref
    ref="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
    if [[ -n "$ref" ]]; then
        printf '%s\n' "${ref#origin/}"
        return 0
    fi
    local candidate
    for candidate in main master develop trunk; do
        if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    for candidate in main master; do
        if git -C "$repo" show-ref --verify --quiet "refs/heads/$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 0
}

# _intake_checkout_branch <branch>
# Idempotent checkout with error classification. Emits:
#   - intake.branch.noop      (already on target)
#   - intake.branch.reused    (local branch existed)
#   - intake.branch.adopted   (remote branch fetched and checked out)
#   - intake.branch.created   (new local branch)
#   - intake.error            (checkout/fetch failures)
# Sets _INTAKE_BRANCH_OUTCOME to one of: noop|reused|adopted|created
_intake_checkout_branch() {
    local target="$1"
    _INTAKE_BRANCH_OUTCOME=""

    # Validate up front so callers don't have to.
    if ! _intake_validate_branch_name "$target"; then
        error "intake_branch: invalid branch name: '$target'"
        emit_event "intake.refused.invalid_branch_name" \
            "plugin=intake" "branch=$target" "reason=invalid_branch_name"
        return 2
    fi

    # Capture current state for event payloads.
    local current previous_head base_sha
    current="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    previous_head="${current:-detached}"
    base_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

    # Detached HEAD info event (non-fatal — we branch from current commit).
    if [[ -z "$current" ]]; then
        emit_event "intake.branch.from_detached" \
            "plugin=intake" "base=$base_sha" "target=$target"
    fi

    # Already on target → no-op.
    if [[ -n "$current" && "$current" == "$target" ]]; then
        emit_event "intake.branch.noop" \
            "plugin=intake" "branch=$target" "base=$base_sha"
        _INTAKE_BRANCH_OUTCOME="noop"
        return 0
    fi

    # Does local branch exist?
    if git show-ref --verify --quiet "refs/heads/$target"; then
        local _co_err=""
        # LC_ALL=C pins git's stderr to English: both the case-match below and the
        # fallback parse read that message, and a translated locale would silently
        # degrade the diagnostic back to the generic checkout_failed path.
        # Capture stderr (2>&1 >/dev/null): stderr → $() pipe, stdout discarded.
        if ! _co_err="$(LC_ALL=C git checkout "$target" 2>&1 >/dev/null)"; then
            # Detect branch held by another worktree. Git's phrasing varies by version:
            #   < 2.31: "fatal: '<b>' is already checked out at '<path>'"
            #   ≥ 2.31: "fatal: '<b>' is already used by worktree at '<path>'"
            local _holder=""
            case "$_co_err" in
                *"is already checked out at"*|*"is already used by worktree at"*)
                    # First try porcelain (authoritative); fall back to stderr parse.
                    # The branch goes in via ENVIRON, not -v: awk expands backslash
                    # escapes in a -v assignment, so a crafted branch name would
                    # corrupt the comparison. `exit` on the first hit replaces a
                    # `| head -1` that could SIGPIPE awk under pipefail.
                    _holder="$(_zb_b="refs/heads/$target" git worktree list --porcelain 2>/dev/null \
                        | awk '/^worktree /{w=$2} /^branch /{if ($2==ENVIRON["_zb_b"]) {print w; exit}}')"
                    if [[ -z "$_holder" ]]; then
                        # Extract the path from git's own error message with pure
                        # bash — no grep/sed, which pins neither PATH nor semantics.
                        # Longest-prefix strip so the LAST " at '" wins — the path
                        # is always the final quoted field of the message.
                        local _tail="${_co_err##* at \'}"
                        [[ "$_tail" != "$_co_err" ]] && _holder="${_tail%%\'*}"
                    fi
                    ;;
            esac
            if [[ -n "$_holder" ]]; then
                local _dead_run_id="${_holder##*/}"
                # Co-located layout: .../runs/<run_id>/worktree → extract run_id
                if [[ "$_dead_run_id" == "worktree" ]]; then
                    _dead_run_id="${_holder%/worktree}"; _dead_run_id="${_dead_run_id##*/}"
                fi
                error "intake_branch: branch '$target' is already checked out at $_holder"
                error "  dead run: ${_dead_run_id:-unknown}"
                # --age-days 0 is REQUIRED, not decorative: the scanner's default
                # is 14 days, so the bare form reclaims nothing for a run that
                # died today — which is exactly the case that lands here.
                error "  reclaim:  zbuild cleanup --worktrees --age-days 0 --apply"
                emit_event "intake.error" \
                    "plugin=intake" "branch=$target" \
                    "reason=branch_held_by_worktree" "holder=$_holder"
            else
                error "intake_branch: checkout of existing branch '$target' failed"
                emit_event "intake.error" \
                    "plugin=intake" "branch=$target" "reason=checkout_failed"
            fi
            return 2
        fi
        # Verify post-checkout
        local after
        after="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
        if [[ "$after" != "$target" ]]; then
            error "intake_branch: post-checkout HEAD mismatch (expected '$target', got '$after')"
            emit_event "intake.error" \
                "plugin=intake" "branch=$target" "reason=post_checkout_mismatch"
            return 2
        fi
        local default_branch ahead_count
        default_branch="$(_intake_resolve_default_branch "$PWD")"
        if [[ -z "$default_branch" ]]; then
            ahead_count="unknown"
        else
            ahead_count="$(git rev-list --count "${default_branch}..$target" 2>/dev/null || echo unknown)"
        fi
        emit_event "intake.branch.reused" \
            "plugin=intake" "branch=$target" "base=$base_sha" \
            "previous_head=$previous_head" "ahead_count=$ahead_count"
        _INTAKE_BRANCH_OUTCOME="reused"
        return 0
    fi

    # Local branch absent — does it exist on remote? Adopt it.
    # `git show-ref` won't list remote refs unless we look at remotes/.
    if git show-ref --verify --quiet "refs/remotes/origin/$target"; then
        # Fetch the remote branch as a local tracking branch.
        if ! git fetch origin "$target:$target" >/dev/null 2>&1; then
            error "intake_branch: failed to fetch remote branch '$target'"
            emit_event "intake.error" \
                "plugin=intake" "branch=$target" "reason=fetch_failed"
            return 2
        fi
        # Checkout the newly fetched branch.
        if ! git checkout "$target" >/dev/null 2>&1; then
            error "intake_branch: checkout of fetched branch '$target' failed"
            emit_event "intake.error" \
                "plugin=intake" "branch=$target" "reason=checkout_failed"
            return 2
        fi
        # Verify post-checkout.
        local after
        after="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
        if [[ "$after" != "$target" ]]; then
            error "intake_branch: post-checkout HEAD mismatch (expected '$target', got '$after')"
            emit_event "intake.error" \
                "plugin=intake" "branch=$target" "reason=post_checkout_mismatch"
            return 2
        fi
        local default_branch ahead_count
        default_branch="$(_intake_resolve_default_branch "$PWD")"
        if [[ -z "$default_branch" ]]; then
            ahead_count="unknown"
        else
            ahead_count="$(git rev-list --count "${default_branch}..$target" 2>/dev/null || echo unknown)"
        fi
        emit_event "intake.branch.adopted" \
            "plugin=intake" "branch=$target" "base=$base_sha" \
            "previous_head=$previous_head" "ahead_count=$ahead_count" "source=remote"
        _INTAKE_BRANCH_OUTCOME="adopted"
        return 0
    fi

    # Create new branch.
    if ! git checkout -b "$target" >/dev/null 2>&1; then
        error "intake_branch: 'git checkout -b $target' failed"
        emit_event "intake.error" \
            "plugin=intake" "branch=$target" "reason=branch_create_failed"
        return 2
    fi
    # Verify post-checkout.
    local after
    after="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ "$after" != "$target" ]]; then
        error "intake_branch: post-create HEAD mismatch (expected '$target', got '$after')"
        emit_event "intake.error" \
            "plugin=intake" "branch=$target" "reason=post_create_mismatch"
        return 2
    fi
    emit_event "intake.branch.created" \
        "plugin=intake" "branch=$target" "base=$base_sha" \
        "previous_head=$previous_head"
    _INTAKE_BRANCH_OUTCOME="created"
    return 0
}

# _intake_create_workspace_branch <state_dir> <issue> <title>
# Top-level orchestrator: env override > preflight > derive > checkout >
# state writes. Returns 0 on success, 2 on any refusal/error.
_intake_create_workspace_branch() {
    local state_dir="$1" issue="$2" title="$3"

    # Env override (with deprecated WORKSPACE_BRANCH alias).
    local override="${ZBUILD_WORKSPACE_BRANCH:-}"
    if [[ -z "$override" && -n "${WORKSPACE_BRANCH:-}" ]]; then
        warn "intake_branch: WORKSPACE_BRANCH is deprecated; use ZBUILD_WORKSPACE_BRANCH"
        override="$WORKSPACE_BRANCH"
    fi

    # CI mode: refuse if no override.
    local ci_mode=0
    if [[ "${CI:-false}" == "true" || "${CI_MODE:-false}" == "true" ]]; then
        ci_mode=1
    fi
    if [[ $ci_mode -eq 1 && -z "$override" ]]; then
        error "intake_branch: CI mode requires ZBUILD_WORKSPACE_BRANCH to be set"
        emit_event "intake.refused.invalid_branch_name" \
            "plugin=intake" "reason=ci_workspace_branch_unset"
        return 2
    fi

    # Preflight (git binary, repo state, dirty tree).
    _intake_check_preflight || return 2

    local target
    if [[ -n "$override" ]]; then
        if ! _intake_validate_branch_name "$override"; then
            error "intake_branch: ZBUILD_WORKSPACE_BRANCH='$override' is invalid"
            emit_event "intake.refused.invalid_branch_name" \
                "plugin=intake" "branch=$override" "reason=env_override_invalid"
            return 2
        fi
        target="$override"
    else
        target="$(_intake_derive_branch_name "$issue" "$title")"
    fi

    # ADR-052 (#1640): intake knows nothing about worktrees. The engine has already
    # put this process in the run's own tree, so the checkout below simply lands
    # there — which is why intake's four branch paths stay the single source of
    # truth for branch selection. #888 had intake acquire the worktree itself; its
    # cd and export died with this dispatch subshell and every later stage fell
    # back to the main checkout, on whatever branch it held.
    _intake_checkout_branch "$target" || return 2

    # State writes — atomic single-line file + optional pipeline-state JSON
    # field (only when the state JSON exists and the helper is loaded).
    printf '%s\n' "$target" | atomic_write "$state_dir/intake-branch.txt"

    # Wave 8 #614: record post-checkout HEAD as the "intake baseline".
    # Build plugin + router loop read this back when assembling iter prompts
    # so the LLM can see commits already on the branch ("already done"
    # recognition). Bare SHA, no trailing newline — printf '%s', not 'echo'.
    local _baseline_sha
    _baseline_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$_baseline_sha" ]]; then
        printf '%s' "$_baseline_sha" > "$state_dir/intake-baseline-ref.txt"
        emit_event "intake.baseline.captured" \
            "plugin=intake" "sha=$_baseline_sha"
    fi

    # #1265: snapshot the PRE-EXISTING untracked set at run-start. The build's
    # scope-census baselines against this so a stray file left in the working
    # tree by a PRIOR run (present at intake, NOT created by THIS run) is never
    # false-flagged as build-created out-of-scope collateral (ADR-030). NUL-
    # delimited so paths with spaces/newlines survive. Unconditional — captured
    # even under ZBUILD_INTAKE_ALLOW_DIRTY (the dogfood path where strays enter).
    local _untracked_baseline="$state_dir/intake-untracked-baseline.txt"
    if git ls-files --others --exclude-standard -z > "$_untracked_baseline" 2>/dev/null; then
        local _untracked_count
        _untracked_count="$(tr -cd '\0' < "$_untracked_baseline" | wc -c | tr -d ' ')"
        emit_event "intake.untracked_baseline.captured" \
            "plugin=intake" "count=${_untracked_count:-0}"
    fi

    local pipeline_state="$state_dir/pipeline-state.json"
    if [[ -f "$pipeline_state" ]] && declare -F _set_pipeline_branch >/dev/null 2>&1; then
        _set_pipeline_branch "$pipeline_state" "$target" 2>/dev/null || \
            warn "intake_branch: failed to record .branch in pipeline-state.json (non-fatal)"
    fi

    return 0
}
