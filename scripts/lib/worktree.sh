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

_ZBUILD_WORKTREE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── zbuild_run_root <run_id> ────────────────────────────────────────────────
# The single directory that owns everything for one run. Per-run state already
# lives at <base>/runs/<run_id> (core/pipeline/runner.sh:1153, #887), so the
# worktree goes under the SAME run directory rather than a parallel tree — one
# place to find for resume, one to delete for cleanup.
#
# Base precedence: $ZBUILD_RUN_ROOT > $HOME/.zbuild.
#
# CLOSED (#1638, restated #1918): CI no longer pins ZBUILD_STATE_DIR to
# ${{ github.workspace }}/state. The workflow resolves it to
# $RUNNER_TEMP/zbuild-state — outside the workspace — so state is no longer
# inside the repo the run is editing, and zbuild_worktree_assert_outside no
# longer has a state dir it must refuse to follow.
#
# The stale version of this note claimed the opposite and is what made ADR-058's
# per-stage scratch (a directory inside the job folder, uploaded from CI) look
# impossible. State and worktree still have different parents in CI — that is a
# layout choice, not the leak the note described.
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
# Consumed by the ENGINE, before the first stage dispatches (ADR-052, #1640) —
# not by any plugin. Worktree acquisition is run infrastructure, like run_id and
# state_dir, so there is no window in which a stage runs in the wrong tree.
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

# ─── zbuild_worktree_acquire <run_id> [main_repo_root] ───────────────────────
# Create-or-reuse the per-run worktree and print its path. Takes NO branch.
#
# ADR-052 (#1640): the engine calls this before the first stage dispatches, so
# every stage — intake included — is already standing in the run's own tree. The
# predecessor design had intake create the worktree, which meant the tree only
# became correct partway through the run and only for stages that knew to look;
# in practice nothing looked, and build committed to whatever branch the shared
# checkout held (see ADR-052 §Context).
#
# Branch-free by construction. The engine knows run_id but not the work branch —
# that is intake's decision, made later. A DETACHED worktree needs neither: intake
# then runs its existing checkout inside this tree, unchanged and unaware.
#
# Reuse is what makes resume work: the path is keyed by run_id, so re-acquiring
# for the same run lands in the tree the earlier stages worked in, whatever branch
# they left checked out. A non-worktree directory squatting on the path is rc=4
# rather than a silent surprise.
zbuild_worktree_acquire() {
    local run_id="${1:-}" repo_root="${2:-}"
    [[ -n "$run_id" ]] || { printf 'zbuild_worktree_acquire: run_id required\n' >&2; return 2; }
    [[ -n "$repo_root" ]] || repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    local wt
    wt="$(zbuild_worktree_path "$run_id")" || return 2
    zbuild_worktree_assert_outside "$wt" "$repo_root" || return 2

    if [[ -d "$wt" ]]; then
        # Reuse only a worktree REGISTERED TO $repo_root. `rev-parse
        # --show-toplevel` is not sufficient on its own: it also succeeds for a
        # standalone `git init` at this path, and reusing that would run the whole
        # pipeline against a repo sharing no history with the target — silently.
        # The registration round-trip is the authoritative check (PR #1643 review).
        # Paths are canonicalized because `worktree list` prints resolved paths
        # (/private/var vs /var on macOS) while $wt comes from config.
        local wt_real listed found=0
        wt_real="$(cd "$wt" 2>/dev/null && pwd -P)" || wt_real=""
        if [[ -n "$wt_real" ]]; then
            while IFS= read -r listed; do
                [[ "$listed" == worktree\ * ]] || continue
                listed="${listed#worktree }"
                [[ "$(cd "$listed" 2>/dev/null && pwd -P)" == "$wt_real" ]] && { found=1; break; }
            done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null || true)
        fi
        if [[ "$found" -eq 1 ]]; then
            printf '%s\n' "$wt"
            return 0
        fi
        printf 'zbuild_worktree_acquire: %s exists but is not a worktree of %s\n' "$wt" "$repo_root" >&2
        return 4
    fi

    mkdir -p "$(dirname "$wt")" || return 2
    local git_err
    if ! git_err="$(git -C "$repo_root" worktree add --detach "$wt" 2>&1 1>/dev/null)"; then
        printf 'zbuild_worktree_acquire: git worktree add --detach failed (%s): %s\n' \
            "$wt" "${git_err:-<no git output>}" >&2
        return 5
    fi
    # Post-condition, not paranoia: a `git` that exits 0 without creating the tree
    # (a PATH shim, a wrapper) would otherwise be reported as a successful acquire,
    # and the caller would fail later with a confusing "cannot cd". Say what is
    # actually wrong, here, where the reason is still known.
    if [[ ! -d "$wt" ]]; then
        printf 'zbuild_worktree_acquire: git reported success but %s does not exist\n' "$wt" >&2
        printf '  (is `git` shimmed on PATH? set ZBUILD_NO_WORKTREE=1 to run in place.)\n' >&2
        return 5
    fi
    printf '%s\n' "$wt"
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
        | head -1)"  # sigpipe-ok: git guarantees at most one worktree per branch
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

# ─── zbuild_worktree_run_id <worktree_path> ─────────────────────────────────
# The run that owns <worktree_path>, inverting zbuild_worktree_path's two
# layouts: co-located <run_root>/<run_id>/worktree, or <override_root>/<run_id>.
# Prints nothing (rc=1) when the path carries no run id.
zbuild_worktree_run_id() {
    local wt="${1:-}"
    [[ -n "$wt" ]] || return 1
    wt="${wt%/}"
    local leaf="${wt##*/}"
    if [[ "$leaf" == "worktree" ]]; then
        local parent="${wt%/worktree}"
        leaf="${parent##*/}"
    fi
    [[ -n "$leaf" && "$leaf" != "/" ]] || return 1
    printf '%s\n' "$leaf"
}

# ─── _zbuild_worktree_state_file <run_id> ───────────────────────────────────
# The state file belonging to <run_id>, or rc=1 if none can be identified.
#
# Two layouts, because the runner writes two. A default-state run re-roots into
# <base>/runs/<run_id>/ (#887); a run given an explicit ZBUILD_STATE_DIR — which
# CI still pins to the workspace — keeps its state FLAT at that path, and skips
# the re-root entirely (core/pipeline/runner.sh, `_state_is_default`). Searching
# only the per-run layout finds nothing under CI's configuration, and a caller
# that reads "no state" as "cannot prove it finished" would then refuse forever.
#
# The `.run_id` match is required, not decorative: the flat layout is ONE file
# that any run may own, so identifying it by path alone would answer a liveness
# question about a different run — and a wrong "not live" there authorises
# removing a working tree.
_zbuild_worktree_state_file() {
    local run_id="${1:-}"
    [[ -n "$run_id" ]] || return 1
    declare -F get_state_field >/dev/null 2>&1 || return 1
    local base cand
    for base in "${ZBUILD_STATE_DIR:-}" "${ZBUILD_STATE_ROOT:-}" "$HOME/.zbuild/state"; do
        [[ -n "$base" ]] || continue
        for cand in "$base/runs/$run_id/pipeline-state.json" "$base/pipeline-state.json"; do
            [[ -f "$cand" ]] || continue
            [[ "$(get_state_field "$cand" '.run_id' '')" == "$run_id" ]] || continue
            printf '%s\n' "$cand"
            return 0
        done
    done
    return 1
}

# ─── zbuild_worktree_reclaim_dead <holder_path> [repo_root] ─────────────────
# Release the worktree of a run that is no longer working, so its branch can be
# checked out again (#1869). Without this, a run that aborted held its branch
# forever and every re-run of the same issue died at intake.
# rc=0 reclaimed; non-zero refused, with the reason on stderr:
#   2 usage   3 holder run is live   4 liveness unprovable   5 git refused
#
# Why reclaiming is not a destructive act: a branch ref lives in the repository,
# not in the worktree that has it checked out. Removing a clean tree therefore
# leaves the branch and every commit on it intact — the next run checks the same
# branch out and continues from where the dead run stopped. The only work that
# CANNOT survive is work that was never committed, and `git worktree remove`
# refuses that by itself. That refusal is why this deliberately never passes
# --force: git's own guard is the safety property, not a check we could get
# subtly wrong, and downgrading it to a warning is how uncommitted work gets
# eaten (see tests/mutation/cleanup-worktree-dirty-guard.md).
#
# Liveness is asked of the run, not the directory: an in-progress run's tree is
# off limits however clean it looks, because two runs on one branch leave a
# silently stale HEAD in one of them. Unprovable liveness refuses too (rc=4) —
# a worktree whose state has been swept is rare, an operator can still clear it
# with `zbuild cleanup --worktrees`, and guessing "probably dead" here would put
# a live run's tree at risk to save one command.
zbuild_worktree_reclaim_dead() {
    local holder="${1:-}" repo_root="${2:-}"
    [[ -n "$holder" ]] || { printf 'zbuild_worktree_reclaim_dead: holder path required\n' >&2; return 2; }
    [[ -n "$repo_root" ]] || repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    local run_id
    if ! run_id="$(zbuild_worktree_run_id "$holder")"; then
        printf 'zbuild_worktree_reclaim_dead: %s carries no run id\n' "$holder" >&2
        return 4
    fi

    # Lazily sourced so the predicate has ONE definition (core/state/resume.sh)
    # while this library stays usable by callers that never load the state layer.
    if ! declare -F zbuild_run_is_live >/dev/null 2>&1; then
        # shellcheck source=../../core/state/resume.sh
        source "$_ZBUILD_WORKTREE_LIB_DIR/../../core/state/resume.sh" 2>/dev/null || true
    fi
    if ! declare -F zbuild_run_is_live >/dev/null 2>&1; then
        printf 'zbuild_worktree_reclaim_dead: liveness predicate unavailable; refusing\n' >&2
        return 4
    fi

    local state_file
    if ! state_file="$(_zbuild_worktree_state_file "$run_id")"; then
        printf 'zbuild_worktree_reclaim_dead: no state for run %s — cannot prove it finished\n' \
            "$run_id" >&2
        return 4
    fi
    if zbuild_run_is_live "$state_file"; then
        printf 'zbuild_worktree_reclaim_dead: run %s is still in progress; refusing\n' "$run_id" >&2
        return 3
    fi

    local git_err
    if ! git_err="$(git -C "$repo_root" worktree remove "$holder" 2>&1)"; then
        printf 'zbuild_worktree_reclaim_dead: git refused to remove %s: %s\n' \
            "$holder" "${git_err:-<no git output>}" >&2
        return 5
    fi
    return 0
}

