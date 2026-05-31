#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild cleanup library — safety predicates + scanners (#570)             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Public mini-library: four reusable safety predicates plus scanners/applier
# used by `zbuild cleanup` and any future caller (e.g. `zbuild worktree
# remove`, daemon idle-detection). Predicates are fail-CLOSED: when uncertain,
# they return "unsafe" so the caller skips deletion. See ADR pinning the
# contract.

[[ -n "${_ZBUILD_CLEANUP_LOADED:-}" ]] && return 0
_ZBUILD_CLEANUP_LOADED=1

# ─── Safety predicates ──────────────────────────────────────────────────────
# Contract: exit code only (0 = condition true, 1 = condition false).
# Predicates print nothing on stdout. Missing tools / errors => fail-closed
# (return 0 from is_current / dirty / unpushed; return 1 from has_merged_pr).

# _cleanup_is_current_branch <branch>
# True if the branch is the HEAD of any worktree of the current repo.
_cleanup_is_current_branch() {
    local b="$1"
    local head
    head="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    [[ "$head" == "$b" ]] && return 0
    # Scan worktrees: any worktree HEAD matching <b> counts as "current".
    local line
    while IFS= read -r line; do
        case "$line" in
            "branch refs/heads/$b") return 0 ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null || true)
    return 1
}

# _cleanup_has_uncommitted_work <branch>
# True if a worktree checking out <branch> has unstaged, staged, OR untracked
# changes. Fail-CLOSED: any error checking returns true (caller skips delete).
_cleanup_has_uncommitted_work() {
    local b="$1"
    # Locate worktree path for the branch (porcelain v1).
    local wt_path="" line cur_path=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) cur_path="${line#worktree }" ;;
            "branch refs/heads/$b") wt_path="$cur_path"; break ;;
            "") cur_path="" ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null || true)
    # No worktree → branch cannot have uncommitted work.
    [[ -z "$wt_path" ]] && return 1
    [[ ! -d "$wt_path" ]] && return 0  # worktree path missing → fail-closed
    (
        cd "$wt_path" || exit 0
        git diff --quiet HEAD -- 2>/dev/null || exit 0
        git diff --cached --quiet 2>/dev/null || exit 0
        local untracked
        untracked="$(git ls-files --others --exclude-standard 2>/dev/null || echo "X")"
        [[ -n "$untracked" ]] && exit 0
        exit 1
    )
}

# _cleanup_has_unpushed_commits <branch>
# True if local branch is ahead of its upstream OR has no upstream configured.
# Fail-CLOSED: assume unpushed on any error.
_cleanup_has_unpushed_commits() {
    local b="$1"
    local upstream
    upstream="$(git rev-parse --abbrev-ref "$b@{upstream}" 2>/dev/null || true)"
    if [[ -z "$upstream" ]]; then
        return 0  # no upstream → treat as unpushed
    fi
    local ahead
    ahead="$(git rev-list --count "$upstream..$b" 2>/dev/null || echo "X")"
    if [[ "$ahead" == "X" ]]; then
        return 0  # error → fail-closed (unpushed)
    fi
    [[ "$ahead" -gt 0 ]] && return 0
    return 1
}

# _cleanup_has_merged_pr <branch>
# True if `gh` reports a merged PR with <branch> as head.
# Fail-CLOSED: gh missing / error / parse failure → return 1 (NOT merged →
# caller refuses to delete unless --force).
_cleanup_has_merged_pr() {
    local b="$1"
    command -v gh >/dev/null 2>&1 || return 1
    local out
    out="$(gh pr list --head "$b" --state merged --json number --jq 'length' 2>/dev/null || echo "X")"
    if [[ "$out" == "X" || -z "$out" ]]; then
        return 1
    fi
    [[ "$out" =~ ^[0-9]+$ ]] || return 1
    [[ "$out" -gt 0 ]] && return 0
    return 1
}

# ─── State-file scanner ─────────────────────────────────────────────────────
# _cleanup_scan_state_files <state_dir> <age_days> <force_bool>
# Prints one candidate per line: "<filepath>\t<reason>"
# Reason: "status=<s>;age=<days>d"
_cleanup_scan_state_files() {
    local state_dir="$1" age_days="$2" force="$3"
    [[ -d "$state_dir" ]] || return 0
    local now; now="$(date +%s)"
    local cutoff=$(( now - age_days * 86400 ))
    local f
    for f in "$state_dir"/pipeline-state*.json; do
        [[ -f "$f" ]] || continue
        # Skip .bak / .lock siblings (we never glob them anyway since pattern
        # ends in .json, but stay defensive).
        case "$f" in
            *.bak|*.lock) continue ;;
        esac
        local status
        status="$(jq -r '.status // ""' "$f" 2>/dev/null || echo "")"
        # in_progress NEVER pruned (even with --force) — running pipelines.
        [[ "$status" == "in_progress" ]] && continue
        # interrupted only with --force (preserves resume per ADR-018).
        if [[ "$status" == "interrupted" && "$force" != "true" ]]; then
            continue
        fi
        # Status must be in known terminal set OR force.
        case "$status" in
            complete|failed|aborted|interrupted) ;;
            *)
                [[ "$force" == "true" ]] || continue
                ;;
        esac
        # Age check (skip if newer than cutoff).
        # GNU stat first (Linux CI), then BSD (macOS dev). BSD stat -f doesn't
        # clean-fail on Linux — it returns garbage with rc=0, so trying it first
        # leaves non-numeric text in $mtime → arithmetic aborts under set -u.
        # (Codex P2 on #577 + Coverage CI failure.)
        local mtime
        mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0")"
        [[ "$mtime" -gt "$cutoff" ]] && continue
        local age_d=$(( (now - mtime) / 86400 ))
        printf '%s\tstatus=%s;age=%sd\n' "$f" "$status" "$age_d"
    done
}

# ─── Branch scanner ─────────────────────────────────────────────────────────
# _cleanup_scan_branches <force_bool>
# Prints: "<branch>\t<decision>\t<reason>"
# decision ∈ {prune, skip}
_cleanup_scan_branches() {
    local force="$1"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    local b
    while IFS= read -r b; do
        b="${b## }"; b="${b#\* }"; b="${b## }"
        [[ -z "$b" ]] && continue
        [[ "$b" != zbuild/issue-* ]] && continue
        if _cleanup_is_current_branch "$b"; then
            printf '%s\tskip\tcurrent branch / active worktree\n' "$b"
            continue
        fi
        if _cleanup_has_uncommitted_work "$b"; then
            printf '%s\tskip\tuncommitted work in worktree\n' "$b"
            continue
        fi
        if _cleanup_has_unpushed_commits "$b"; then
            printf '%s\tskip\tunpushed commits / no upstream\n' "$b"
            continue
        fi
        if _cleanup_has_merged_pr "$b"; then
            printf '%s\tprune\tmerged PR\n' "$b"
            continue
        fi
        if [[ "$force" == "true" ]]; then
            printf '%s\tprune\tforce (clean, pushed, no merged PR)\n' "$b"
        else
            printf '%s\tskip\tno merged PR (use --force)\n' "$b"
        fi
    done < <(git branch --list 'zbuild/issue-*' --format '%(refname:short)' 2>/dev/null || true)
}

# ─── Apply plan ─────────────────────────────────────────────────────────────
# _cleanup_apply_plan <candidates_TSV> <dry_run_bool>
# candidates_TSV is the output of a scanner (one record per line).
# Returns 0 on success.
_cleanup_apply_plan() {
    local data="$1" dry_run="$2"
    [[ -z "$data" ]] && return 0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local target; target="${line%%$'\t'*}"
        if [[ "$dry_run" == "true" ]]; then
            continue
        fi
        if [[ -f "$target" ]]; then
            rm -f -- "$target" "$target.bak" "$target.lock" 2>/dev/null || true
        fi
    done <<<"$data"
}

# _cleanup_apply_branch_plan <branch_plan_TSV> <dry_run_bool>
# Each line: "<branch>\t<decision>\t<reason>". Deletes branches whose decision == prune.
_cleanup_apply_branch_plan() {
    local data="$1" dry_run="$2"
    [[ -z "$data" ]] && return 0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local b decision
        b="${line%%$'\t'*}"
        local rest="${line#*$'\t'}"
        decision="${rest%%$'\t'*}"
        [[ "$decision" != "prune" ]] && continue
        if [[ "$dry_run" == "true" ]]; then
            continue
        fi
        # Re-verify safety predicates immediately before delete (defence in depth).
        if _cleanup_is_current_branch "$b"; then continue; fi
        if _cleanup_has_uncommitted_work "$b"; then continue; fi
        if _cleanup_has_unpushed_commits "$b"; then continue; fi
        git branch -D "$b" >/dev/null 2>&1 || true
    done <<<"$data"
}

# ─── Renderer ───────────────────────────────────────────────────────────────
# _cleanup_render_plan <kind> <data> <dry_run> <quiet>
_cleanup_render_plan() {
    local kind="$1" data="$2" dry_run="$3" quiet="$4"
    [[ "$quiet" == "true" ]] && return 0
    local header_action="WOULD"
    [[ "$dry_run" != "true" ]] && header_action="WILL"
    if [[ -z "$data" ]]; then
        info "$kind: nothing to clean"
        return 0
    fi
    info "$kind ($header_action):"
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local target rest decision reason
        target="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        if [[ "$kind" == "branches" ]]; then
            decision="${rest%%$'\t'*}"
            reason="${rest#*$'\t'}"
            printf '  %-40s  %-6s  %s\n' "$target" "$decision" "$reason"
        else
            reason="$rest"
            printf '  %-60s  %s\n' "$target" "$reason"
        fi
    done <<<"$data"
}
