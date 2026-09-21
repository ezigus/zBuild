#!/usr/bin/env bash
# core/plugin-registry/write-ownership.sh — who may write what, decided by the
# engine from the manifests (#2174). Sourced by lifecycle.sh; the deny lists
# it produces are rendered by core/router/permissions.sh.
#
# Two rules, no stage naming another:
#   1. In the artifact dir a stage may write only the outputs its OWN manifest
#      declares; every other plugin's declared output is read-only to it.
#   2. Only a plugin declaring capabilities.writes_repository: true may edit
#      the target repository: every tracked top-level entry is denied otherwise.
# Both results come back in _LC_DENY_OUT (newline-separated paths); callers
# run them in the PARENT shell — a memo filled in a subshell is lost (ADR-065 §3).

# _lc_other_outputs_deny <plugin_dir> <state_dir> — every OTHER plugin's
# declared outputs, resolved into this run's artifact dir, into _LC_DENY_OUT
# (newline-separated) (#2174). Served from the manifest index's outputs.path
# list key — the one find + one awk the run already pays (ADR-065 §4) — so
# this forks nothing. Call it in the PARENT shell (ADR-065 §3).
_LC_DENY_OUT=""
_lc_other_outputs_deny() {
    local own="$1" state_dir="$2" root="${ZBUILD_PLUGINS_ROOT:-}" f raw resolved
    _LC_DENY_OUT=""
    [[ -n "$root" ]] || root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../plugins" 2>/dev/null && pwd)"
    [[ -d "$root" ]] || return 0
    declare -F manifest_index_load >/dev/null 2>&1 || return 0
    declare -F _registry_resolve_output_path >/dev/null 2>&1 || return 0
    manifest_index_load "$root"
    local artifact_dir="${state_dir}/artifacts" own_n="${own%/}" idx_root
    idx_root="$(_manifest_index_root "$root")"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        case "$f" in */tests/*) continue ;; esac
        [[ "${f%/manifest.yaml}" == "$own_n" ]] && continue
        while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            resolved="$(_registry_resolve_output_path "$raw" "$state_dir" "$artifact_dir" 2>/dev/null || true)"
            [[ -n "$resolved" ]] && _LC_DENY_OUT+="$resolved"$'\n'
        done <<< "$(manifest_index_get "$f" outputs.path 2>/dev/null || true)"
    done <<< "${_ZBUILD_MIDX_FILES[$idx_root]:-}"
}

# _lc_repo_entries_deny <repo_root> — the repo's tracked top-level entries as
# deny paths (dirs as <dir>/**) into _LC_DENY_OUT (#2174). Memoised per root;
# same parent-shell rule as above.
declare -gA _LC_REPO_ENTRIES_MEMO=()
_lc_repo_entries_deny() {
    local root="$1" abs e acc=""
    _LC_DENY_OUT=""
    # Logical path (not -P): the rule must match the path the model sees.
    abs="$(cd "$root" 2>/dev/null && pwd)" || return 0
    if [[ -z "${_LC_REPO_ENTRIES_MEMO[$abs]+x}" ]]; then
        while IFS= read -r e; do
            [[ -n "$e" ]] || continue
            if [[ -d "$abs/$e" ]]; then acc+="$abs/$e/**"$'\n'; else acc+="$abs/$e"$'\n'; fi
        done < <(git -C "$abs" ls-tree --name-only HEAD 2>/dev/null)
        _LC_REPO_ENTRIES_MEMO[$abs]="$acc"
    fi
    _LC_DENY_OUT="${_LC_REPO_ENTRIES_MEMO[$abs]}"
}

