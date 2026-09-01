#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  stage-scratch — the engine-owned per-stage scratch directory (ADR-058)    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# ADR-058 §1 names five areas a stage may write into (four as accepted; the
# `runtime/` bookkeeping area was added by the #1809 amendment, §2b). Three
# already existed —
# the job's state dir, the run's worktree (ADR-052), and the two stores that
# outlive a run (ADR-011). This file owns the fourth, which did not: a stage
# that needs a throwaway working file took one from the system temp directory,
# because nobody had ever given it anywhere better.
#
# The scratch dir is deliberately NOT under $TMPDIR. `scripts/lib/worktree.sh`
# already gives the reason for the worktree: on macOS $TMPDIR resolves into
# /var/folders/..., where entries can vanish mid-run (#1571, and the empty-state
# aborts #1609/#1611 chased). Scratch holds live work ACROSS cycle iterations —
# build re-runs up to 8× — so the same reaper hazard applies. Nothing in this
# file may read $TMPDIR; tests/unit/stage-scratch-test.sh SPEC-3 pins that
# statically, because the dispatch seam sets TMPDIR *to* the scratch dir and a
# resolver that read it back would nest scratch inside scratch every iteration.
#
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_STAGE_SCRATCH_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_SCRATCH_LOADED=1

# ─── _stage_scratch_key <stage> [<map_element>] ─────────────────────────────
# The single path component naming one stage's scratch.
#
# Keyed on <stage>[-<map_element>], not the stage alone: under `map:` all six
# lens members receive the SAME stage name concurrently
# (core/plugin-registry/lifecycle.sh, ADR-047 §2), so a stage-only key would
# hand six parallel members one directory.
#
# Carries no iteration counter by design — one dir per stage, reused across
# cycle iterations (ADR-058 §2).
#
# Everything outside [A-Za-z0-9_-] collapses to `_`, which is what makes the
# result a path component rather than a path: `.` is excluded too, so `..`
# cannot survive sanitisation and no key can climb out of the job folder.
_stage_scratch_key() {
    local stage="${1:-}"
    local element="${2:-}"
    # A stage is required before the element is folded in. Without this a
    # dispatch that knows its map element but not its stage yields the key
    # "-security" — non-empty, so the caller gets a directory instead of the
    # rc=2 refusal, and six lens members with no stage between them would share
    # it. The element qualifies an owner; it cannot be one.
    [[ -n "$stage" ]] || return 2
    local key="$stage"
    [[ -n "$element" ]] && key="${key}-${element}"
    key="${key//[^A-Za-z0-9_-]/_}"
    # Bound the component. A stage id is template-authored and short, but a map
    # element comes from a data list; 96 chars keeps the deepest realistic path
    # clear of PATH_MAX without ever truncating a real stage name.
    printf '%s' "${key:0:96}"
}

# ─── stage_scratch_dir [<state_dir>] [<stage>] [<map_element>] ──────────────
# Resolve (do not create) this stage's scratch dir. Prints the path.
#
# Every argument falls back to the ambient dispatch identity, so a caller
# already inside plugin_hook_call can call this with no arguments at all.
#
# Base precedence — env override > the job folder the caller named > the job
# folder the runner exported > the per-run default. The last arm mirrors
# _strategy_orch_scratch_dir (core/pipeline/strategies/common.sh): a scratch
# path resolved with no state dir in sight must still be per-run, or two
# concurrent runs share it.
#
# rc=2 when no stage can be named: a scratch dir with no owner is a shared
# temp dir with extra steps, which is the thing this file exists to end.
stage_scratch_dir() {
    local state_dir="${1:-${ZBUILD_STATE_DIR:-}}"
    local stage="${2:-${ZBUILD_CURRENT_STAGE:-}}"
    local element="${3:-${ZBUILD_MAP_ELEMENT:-}}"

    local key; key="$(_stage_scratch_key "$stage" "$element")"
    [[ -n "$key" ]] || return 2

    local base="${ZBUILD_SCRATCH_ROOT:-}"
    [[ -n "$base" ]] || base="$state_dir"
    [[ -n "$base" ]] || base="${ZBUILD_STATE_ROOT:-${HOME}/.zbuild/state}/runs/${ZBUILD_RUN_ID:-default}"

    printf '%s/scratch/%s\n' "${base%/}" "$key"
}

# ─── stage_scratch_ensure [<state_dir>] [<stage>] [<map_element>] ───────────
# Resolve + create, 0700. Prints the path on success.
#
# `mkdir -p` + `chmod 700` copied from the per-run orch scratch precedent
# (strategies/common.sh): scratch holds raw prompts and raw model output on a
# shared CI runner, so it is never group- or world-readable.
#
# rc=2 unnameable stage; rc=1 the directory could not be created. Both are
# non-fatal to the caller — the dispatch seam simply does not export the vars,
# and every consumer keeps the `${TMPDIR:-/tmp}` fallback it has today.
stage_scratch_ensure() {
    local dir
    dir="$(stage_scratch_dir "$@")" || return 2
    if ! { mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null; }; then
        if declare -F warn >/dev/null 2>&1; then
            warn "stage-scratch: cannot create scratch dir: ${dir}" || true
        fi
        return 1
    fi
    printf '%s\n' "$dir"
}

