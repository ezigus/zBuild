#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/lib/worktree-sparse.sh — leave frozen legacy/ out of issue trees  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# ADR-059 §2 (#1802). Every linked worktree the engine acquires leaves out
# legacy/ (keeping legacy/migrated/) so agents never traverse the frozen import.
#
# This is an OPTIMISATION, not a safety property: write-scope to legacy/ is
# already refused by scope_floor_denied (scripts/lib/scope-governance.sh). So
# every failure here FAILS OPEN — a warning on stderr naming the step and git's
# own words, and the run carries on with the full tree. It never stops a run.
#
# Sourced library: inherits the caller's shell options; do not add set -euo pipefail.

[[ -n "${_ZBUILD_WORKTREE_SPARSE_LOADED:-}" ]] && return 0
_ZBUILD_WORKTREE_SPARSE_LOADED=1

# `sparse-checkout set --no-cone` / `add --` are git 2.35+.
_ZBUILD_SPARSE_MIN_GIT="2.35"

_zbuild_sparse_warn() {
    printf 'zbuild: warning: could not leave legacy/ out of %s: %s\n' "$1" "$2" >&2
    printf '  continuing with the full tree (an optimisation only; ADR-059 §2).\n' >&2
}

# A keeper widening: a plain relative path strictly under legacy/, with no
# pattern syntax, no option shape and no `..` segment. Anything else would be
# read by git as a pattern or option and could widen or undo the exclusion.
_zbuild_sparse_legacy_path_ok() {
    local p="$1" rest seg
    [[ "$p" == legacy/?* ]] || return 1
    case "$p" in
        *[\!\*\?\[\]\\]*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    esac
    rest="${p#legacy/}"
    local IFS=/
    for seg in $rest; do
        [[ -n "$seg" && "$seg" != ".." && "$seg" != "." ]] || return 1
    done
    return 0
}

# ─── _zbuild_worktree_apply_sparse <wt> <repo_root> ────────────────────────
# Apply the base patterns to a linked worktree, carrying over any keeper
# widenings already present (a resume must not wipe them). Always rc=0 once its
# arguments are present: see the fail-open note at the top of this file.
_zbuild_worktree_apply_sparse() {
    local wt="${1:-}" repo_root="${2:-}"
    [[ -n "$wt" ]]        || { printf '_zbuild_worktree_apply_sparse: wt required\n' >&2; return 2; }
    [[ -n "$repo_root" ]] || { printf '_zbuild_worktree_apply_sparse: repo_root required\n' >&2; return 2; }

    local ver major minor
    ver="$(git --version 2>/dev/null)"
    if [[ "$ver" =~ ([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
    else
        major=0; minor=0
    fi
    if (( major < 2 || (major == 2 && minor < 35) )); then
        _zbuild_sparse_warn "$wt" "${ver:-git --version gave nothing}; sparse-checkout --no-cone needs git >= ${_ZBUILD_SPARSE_MIN_GIT}"
        return 0
    fi

    # Per-worktree config is what keeps the operator's main checkout non-sparse.
    # Write it only when unset; an explicit false is the operator's decision.
    local wtcfg err
    wtcfg="$(git -C "$repo_root" config --bool --get extensions.worktreeConfig 2>/dev/null)"
    case "$wtcfg" in
        true) ;;
        false)
            _zbuild_sparse_warn "$wt" "extensions.worktreeConfig=false is set in $repo_root; not overriding it (sparse would then reach the main checkout)"
            return 0 ;;
        *)
            if ! err="$(git -C "$repo_root" config extensions.worktreeConfig true 2>&1)"; then
                _zbuild_sparse_warn "$wt" "git config extensions.worktreeConfig true failed: ${err:-<no git output>}"
                return 0
            fi ;;
    esac

    local -a patterns=('/*' '!/legacy/' '/legacy/migrated/')
    local line
    if [[ "$(git -C "$wt" config --bool --get core.sparseCheckout 2>/dev/null)" == "true" ]]; then
        while IFS= read -r line; do
            case "$line" in
                '/legacy/migrated/') continue ;;
            esac
            [[ "$line" == /* ]] && _zbuild_sparse_legacy_path_ok "${line#/}" && patterns+=("$line")
        done < <(git -C "$wt" sparse-checkout list 2>/dev/null || true)
    fi

    if ! err="$(git -C "$wt" sparse-checkout set --no-cone -- "${patterns[@]}" 2>&1 >/dev/null)"; then
        _zbuild_sparse_warn "$wt" "git sparse-checkout set failed: ${err:-<no git output>}"
    fi
    return 0
}

# ─── zbuild_worktree_include_legacy_path <wt> <path> ────────────────────────
# Widen one worktree to a single legacy/ file or directory, e.g. so a keeper
# prune can `git rm` it. Additive, idempotent, and kept by every later
# re-acquire. Not called by the engine (build may not write legacy/ at all);
# it is the operator's tool for a by-hand prune (ADR-059 §2).
zbuild_worktree_include_legacy_path() {
    local wt="${1:-}" path="${2:-}" err
    [[ -n "$wt" ]]   || { printf 'zbuild_worktree_include_legacy_path: wt required\n' >&2; return 2; }
    if ! _zbuild_sparse_legacy_path_ok "$path"; then
        printf 'zbuild_worktree_include_legacy_path: refusing %q\n' "$path" >&2
        printf '  give a relative path under legacy/ (not legacy/ itself) with no * ? [ ] ! \\ or .. in it.\n' >&2
        return 2
    fi
    # `sparse-checkout add` appends even an existing line; skip it so repeated
    # widenings do not pile up duplicate patterns.
    local line
    while IFS= read -r line; do
        [[ "$line" == "/$path" ]] && return 0
    done < <(git -C "$wt" sparse-checkout list 2>/dev/null || true)
    if ! err="$(git -C "$wt" sparse-checkout add -- "/$path" 2>&1 >/dev/null)"; then
        printf 'zbuild_worktree_include_legacy_path: git sparse-checkout add failed in %s: %s\n' \
            "$wt" "${err:-<no git output>}" >&2
        return 5
    fi
    return 0
}
