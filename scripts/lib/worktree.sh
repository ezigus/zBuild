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

# ─── zbuild_worktree_root ────────────────────────────────────────────────────
# Where per-run worktrees live. Precedence matches the rest of the engine
# (env > template > default), the same shape as tier and persona resolution:
#   1. $ZBUILD_WORKTREE_ROOT            (operator env override)
#   2. template `config.worktree_root`  (declared data)
#   3. $HOME/.zbuild/worktrees          (default)
#
# The default is deliberately NOT under $TMPDIR. On macOS that resolves into
# /var/folders/..., which this repo has already been bitten by twice: entries
# there can vanish mid-run under a saturated pool (#1571, and the empty-state
# aborts that #1609/#1611 chased). A worktree holding in-flight work must not
# live somewhere a reaper may collect. $HOME/.zbuild mirrors the existing
# ZBUILD_STATE_ROOT convention and is writable on macOS, Linux and CI runners.
#
# It must also sit OUTSIDE the target repository. #888 proposed
# runs/<run_id>/worktree/, but ZBUILD_STATE_DIR is ${{ github.workspace }}/state
# in CI, which would nest a worktree inside the very tree it copies — anything
# walking the tree (test discovery, scope/impact scanning, find sweeps) would
# then see a duplicate of every file.
zbuild_worktree_root() {
    if [[ -n "${ZBUILD_WORKTREE_ROOT:-}" ]]; then
        printf '%s\n' "$ZBUILD_WORKTREE_ROOT"
        return 0
    fi
    local from_tpl=""
    if declare -F template_config_worktree_root >/dev/null 2>&1; then
        from_tpl="$(template_config_worktree_root 2>/dev/null || true)"
    fi
    if [[ -n "$from_tpl" ]]; then
        printf '%s\n' "$from_tpl"
        return 0
    fi
    printf '%s\n' "${HOME}/.zbuild/worktrees"
}

# ─── zbuild_worktree_path <run_id> ───────────────────────────────────────────
# The worktree directory for one run. Keyed by run_id so concurrent runs cannot
# collide, and so resume can re-derive the path from state alone.
zbuild_worktree_path() {
    local run_id="${1:-}"
    if [[ -z "$run_id" ]]; then
        printf 'zbuild_worktree_path: run_id required\n' >&2
        return 2
    fi
    printf '%s/%s\n' "$(zbuild_worktree_root)" "$run_id"
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
    local rc=0
    case "$mode" in
        create)       git worktree add -b "$branch" "$wt" >/dev/null 2>&1 || rc=$? ;;
        adopt_local)  git worktree add "$wt" "$branch"    >/dev/null 2>&1 || rc=$? ;;
        adopt_remote)
            [[ -n "$start_point" ]] || { printf 'zbuild_worktree_enter: adopt_remote needs a start_point\n' >&2; return 2; }
            git worktree add -b "$branch" "$wt" "$start_point" >/dev/null 2>&1 || rc=$? ;;
        *) printf 'zbuild_worktree_enter: unknown mode "%s"\n' "$mode" >&2; return 2 ;;
    esac
    if [[ "$rc" -ne 0 ]]; then
        printf 'zbuild_worktree_enter: git worktree add failed (mode=%s branch=%s path=%s)\n' \
            "$mode" "$branch" "$wt" >&2
        return 5
    fi
    printf '%s\n' "$wt"
    return 0
}
