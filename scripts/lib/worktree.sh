#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/lib/worktree.sh — per-run git-worktree location + enablement     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Target-side isolation (#888), the sibling of engine-side isolation (#1629).
# Engine stability answers "which zBuild code runs"; this answers "where the work
# happens", so concurrent runs stop racing one working tree's .git/index and refs.
#
# Sourced library: inherits the caller's shell options; do not add set -euo pipefail.

[[ -n "${_ZBUILD_WORKTREE_LIB_LOADED:-}" ]] && return 0
_ZBUILD_WORKTREE_LIB_LOADED=1

# ─── zbuild_run_root <run_id> ────────────────────────────────────────────────
# The single directory that owns everything for one run. Per-run state already
# lives at <base>/runs/<run_id> (core/pipeline/runner.sh:1153, #887), so the
# worktree goes under the SAME run directory rather than a parallel tree — one
# place to find for resume, one to delete for cleanup.
#
# Base precedence: $ZBUILD_RUN_ROOT > $HOME/.zbuild.
#
# KNOWN GAP: co-location is only fully realised once CI stops pinning
# ZBUILD_STATE_DIR to ${{ github.workspace }}/state. That puts pipeline state
# INSIDE the target repo — the same category of mixing #1629 fixed for the
# engine — and a worktree cannot follow it there (see
# zbuild_worktree_assert_outside). Until that moves, state and worktree share a
# layout shape but not a parent in CI.
zbuild_run_root() {
    local run_id="${1:-}"
    [[ -n "$run_id" ]] || { printf 'zbuild_run_root: run_id required\n' >&2; return 2; }
    printf '%s/runs/%s\n' "${ZBUILD_RUN_ROOT:-${HOME}/.zbuild}" "$run_id"
}

# ─── zbuild_worktree_root ────────────────────────────────────────────────────
# Explicit override for where worktrees live, when co-location is not wanted.
# Precedence matches the rest of the engine (env > template > default):
#   1. $ZBUILD_WORKTREE_ROOT            (operator env override)
#   2. template `config.worktree_root`  (declared data)
#   3. empty -> caller uses the co-located run root
#
# Any override must sit OUTSIDE the target repository, and must not be under
# $TMPDIR on macOS: that resolves into /var/folders/..., where entries can vanish
# mid-run (#1571, and the empty-state aborts #1609/#1611 chased). A worktree
# holds in-flight work; it must not live where a reaper may collect it.
zbuild_worktree_root() {
    if [[ -n "${ZBUILD_WORKTREE_ROOT:-}" ]]; then
        printf '%s\n' "$ZBUILD_WORKTREE_ROOT"
        return 0
    fi
    if declare -F template_config_worktree_root >/dev/null 2>&1; then
        local from_tpl
        from_tpl="$(template_config_worktree_root 2>/dev/null || true)"
        [[ -n "$from_tpl" ]] && { printf '%s\n' "$from_tpl"; return 0; }
    fi
    return 0   # empty: co-locate under the run root
}

# ─── zbuild_worktree_path <run_id> ───────────────────────────────────────────
# Co-located by default: <run_root>/worktree. An explicit worktree root overrides
# it, keyed by run_id so concurrent runs cannot collide either way, and so resume
# can re-derive the path from state alone.
zbuild_worktree_path() {
    local run_id="${1:-}"
    [[ -n "$run_id" ]] || { printf 'zbuild_worktree_path: run_id required\n' >&2; return 2; }
    local override
    override="$(zbuild_worktree_root)"
    if [[ -n "$override" ]]; then
        printf '%s/%s\n' "${override%/}" "$run_id"
        return 0
    fi
    printf '%s/worktree\n' "$(zbuild_run_root "$run_id")"
}

# ─── zbuild_worktree_enabled ─────────────────────────────────────────────────
# Whether this run should work inside a per-run worktree.
# Returns 0 (enabled) / 1 (disabled). Disable with ZBUILD_NO_WORKTREE=1.
#
# NOTE: the intake-side creation that consumes this is not implemented yet, so
# nothing enables a worktree in practice today — see #888. This predicate and
# the path resolver land first so the location contract is settled and tested
# before any stage starts moving the working tree around.
zbuild_worktree_enabled() {
    [[ "${ZBUILD_NO_WORKTREE:-0}" == "1" ]] && return 1
    return 0
}

# ─── zbuild_worktree_assert_outside <path> <repo_root> ───────────────────────
# Guard: a worktree nested inside the target repo defeats the purpose and
# confuses every tree walk. Fail loudly rather than producing a subtly wrong run.
zbuild_worktree_assert_outside() {
    local wt="${1:-}" repo="${2:-}"
    # Empty args must NOT pass. A caller doing
    #   zbuild_worktree_assert_outside "$(zbuild_worktree_path)" "$ZBUILD_REPO_ROOT"
    # captures "" when zbuild_worktree_path fails (missing run_id), and a guard
    # that returns 0 there would approve exactly the run it exists to refuse —
    # contradicting this function's own "fail loudly" contract.
    [[ -n "$wt" ]]   || { printf 'zbuild_worktree_assert_outside: worktree path required\n' >&2; return 2; }
    [[ -n "$repo" ]] || { printf 'zbuild_worktree_assert_outside: repo path required\n' >&2; return 2; }
    if [[ "$wt" == "$repo" || "$wt" == "$repo"/* ]]; then
        printf 'worktree: refusing a worktree inside the target repository\n' >&2
        printf '  worktree: %s\n' "$wt" >&2
        printf '  target:   %s\n' "$repo" >&2
        printf '  set ZBUILD_WORKTREE_ROOT (or template config.worktree_root) to a path outside it.\n' >&2
        return 1
    fi
    return 0
}

# ─── zbuild_worktree_enter <run_id> <branch> <mode> [start_point] ────────────
# Create (or reuse) the per-run worktree for <branch> and print its path.
# mode: create | adopt_local | adopt_remote
#
# ONE mechanism for all three of intake's branch paths, rather than three
# divergent worktree implementations. The differences are only in what git is
# told to base the tree on:
#   create        -> git worktree add -b <branch> <path>
#   adopt_local   -> git worktree add    <path> <branch>
#   adopt_remote  -> git worktree add -b <branch> <path> <start_point>
#
# Resume-safe: an existing path that is already a registered worktree for
# <branch> is REUSED, because `git worktree add` fails on an existing path and a
# resumed run must land in the tree its earlier stages were working in.
#
# Deliberately does NOT use `--force` when <branch> is checked out elsewhere.
# git refuses that by default, and forcing it would leave two trees on one branch
# with a silently stale HEAD in the other — a worse failure than stopping. The
# caller gets rc=3 and a message naming the tree that holds it.
zbuild_worktree_enter() {
    local run_id="${1:-}" branch="${2:-}" mode="${3:-create}" start_point="${4:-}"
    [[ -n "$run_id" ]] || { printf 'zbuild_worktree_enter: run_id required\n' >&2; return 2; }
    [[ -n "$branch" ]] || { printf 'zbuild_worktree_enter: branch required\n' >&2; return 2; }

    local repo_root wt
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    wt="$(zbuild_worktree_path "$run_id")" || return 2
    zbuild_worktree_assert_outside "$wt" "$repo_root" || return 2

    # Reuse on resume: same path, already a worktree, already on <branch>.
    if [[ -d "$wt" ]]; then
        local existing_branch
        existing_branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
        if [[ "$existing_branch" == "$branch" ]]; then
            printf '%s\n' "$wt"
            return 0
        fi
        printf 'zbuild_worktree_enter: %s exists but is on "%s", not "%s"\n' \
            "$wt" "${existing_branch:-<not a worktree>}" "$branch" >&2
        return 4
    fi

    # Refuse rather than --force when the branch is live in another tree.
    local holder
    holder="$(git worktree list --porcelain 2>/dev/null \
        | awk -v b="refs/heads/$branch" '/^worktree /{w=$2} /^branch /{if ($2==b) print w}' \
        | head -1)"
    if [[ -n "$holder" ]]; then
        printf 'zbuild_worktree_enter: branch "%s" is already checked out at %s\n' "$branch" "$holder" >&2
        printf '  refusing --force: two trees on one branch leaves a silently stale HEAD.\n' >&2
        return 3
    fi

    mkdir -p "$(dirname "$wt")" || return 2
    # Capture git's stderr rather than discarding it. The holder check above
    # catches the common refusal, but everything else — a branch that does not
    # exist locally, a bad start_point, unreadable refs — would otherwise report
    # only "git worktree add failed" with no reason. That is the same swallowing
    # this PR fixed one commit earlier in pr-open; no sense re-introducing it.
    local rc=0 git_err=""
    case "$mode" in
        create)
            git_err="$(git worktree add -b "$branch" "$wt" 2>&1 1>/dev/null)" || rc=$? ;;
        adopt_local)
            git_err="$(git worktree add "$wt" "$branch" 2>&1 1>/dev/null)" || rc=$? ;;
        adopt_remote)
            [[ -n "$start_point" ]] || { printf 'zbuild_worktree_enter: adopt_remote needs a start_point\n' >&2; return 2; }
            git_err="$(git worktree add -b "$branch" "$wt" "$start_point" 2>&1 1>/dev/null)" || rc=$? ;;
        *) printf 'zbuild_worktree_enter: unknown mode "%s"\n' "$mode" >&2; return 2 ;;
    esac
    if [[ "$rc" -ne 0 ]]; then
        printf 'zbuild_worktree_enter: git worktree add failed (mode=%s branch=%s path=%s): %s\n' \
            "$mode" "$branch" "$wt" "${git_err:-<no git output>}" >&2
        return 5
    fi
    printf '%s\n' "$wt"
    return 0
}
