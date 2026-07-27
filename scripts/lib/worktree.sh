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

_WT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WT_ZBUILD_ROOT="$(cd "$_WT_LIB_DIR/../.." && pwd)"

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
    local wt="$1" repo="$2"
    [[ -n "$wt" && -n "$repo" ]] || return 0
    if [[ "$wt" == "$repo" || "$wt" == "$repo"/* ]]; then
        printf 'worktree: refusing a worktree inside the target repository\n' >&2
        printf '  worktree: %s\n' "$wt" >&2
        printf '  target:   %s\n' "$repo" >&2
        printf '  set ZBUILD_WORKTREE_ROOT (or template config.worktree_root) to a path outside it.\n' >&2
        return 1
    fi
    return 0
}
