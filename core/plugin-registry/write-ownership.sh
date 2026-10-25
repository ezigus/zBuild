#!/usr/bin/env bash
# core/plugin-registry/write-ownership.sh — who may write what, decided by the
# engine from the manifests (#2174). Sourced by lifecycle.sh; the deny lists
# it produces are rendered by core/router/permissions.sh.
#
# Two rules, no stage naming another:
#   1. In the artifact dir a stage may write only the outputs its OWN manifest
#      declares and its own notes file; every other plugin's declared output,
#      and anything else already there, is read-only to it (#2379).
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
    if [[ -z "$root" ]]; then
        local _wo_d="${BASH_SOURCE[0]%/*}"; [[ "$_wo_d" == "${BASH_SOURCE[0]}" ]] && _wo_d="."
        root="$(cd "$_wo_d/../../plugins" 2>/dev/null && pwd)"
    fi
    [[ -d "$root" ]] || return 0
    declare -F manifest_index_load >/dev/null 2>&1 || return 0
    declare -F _registry_resolve_output_path >/dev/null 2>&1 || return 0
    manifest_index_load "$root"
    local artifact_dir="${state_dir}/artifacts" own_n idx_root
    # The index lists paths with `//` collapsed (_manifest_index_root); so must own.
    _manifest_path_key own_n "${own%/}"
    idx_root="$(_manifest_index_root "$root")"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        case "$f" in */tests/*) continue ;; esac
        [[ "${f%/manifest.yaml}" == "$own_n" ]] && continue
        while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            _registry_resolve_output_path_v resolved "$raw" "$state_dir" "$artifact_dir"
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


# _lc_artifacts_left_deny <own_manifest> <state_dir> <stage> — every file
# already in the artifact dir that is not this stage's own (its declared
# outputs and its notes file) into _LC_DENY_OUT (#2379). Another stage's notes,
# its attempts, the stage reports: none is declared, so _lc_other_outputs_deny
# never covered them. A folder with nothing of the stage's in it is denied as
# <dir>/**, which also covers files written into it later.
_lc_artifacts_left_deny() {
    local manifest="$1" state_dir="$2" stage="$3" artifact_dir raw resolved keep=""
    _LC_DENY_OUT=""
    artifact_dir="${state_dir}/artifacts"
    [[ -d "$artifact_dir" ]] || return 0
    if declare -F _registry_resolve_output_path >/dev/null 2>&1; then
        while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            _registry_resolve_output_path_v resolved "$raw" "$state_dir" "$artifact_dir"
            [[ -n "$resolved" ]] && keep+="$resolved"$'\n'
        done <<< "$(_lc_manifest_output_paths "$manifest")"
    fi
    declare -F stage_notes_path >/dev/null 2>&1 \
        || source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../.." && pwd)/scripts/lib/stage-prompt.sh"
    keep+="$(stage_notes_path "$state_dir" "$stage")"$'\n'
    _lc_artifacts_walk "$artifact_dir" "$keep"
}

# _lc_manifest_output_paths <manifest> — the `path:` values under `outputs:`,
# read from the file itself: the stage's own manifest need not be in the index.
_lc_manifest_output_paths() {
    [[ -f "$1" ]] || return 0
    [[ -r "$1" ]] || return 2
    # Read by the shell, rule for rule as the awk it replaced (ADR-065 §5): a
    # quote is stripped before the comment, and only a `#` after a space is one.
    local line v o=0 re='^[[:space:]]+(-[[:space:]]+)?path:[[:space:]]*'
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == outputs:* ]]; then o=1; continue; fi
        [[ "$line" =~ ^[^[:space:]#] ]] && o=0
        (( o )) && [[ "$line" =~ $re ]] || continue
        v="${line:${#BASH_REMATCH[0]}}"
        if [[ "$v" =~ ^[\"\'][[:space:]]*$ ]]; then v=""
        else
            v="${v#[\"\']}"
            [[ "$v" =~ [\"\'][[:space:]]*$ ]] && v="${v%"${BASH_REMATCH[0]}"}"
        fi
        [[ "$v" =~ [[:space:]]+# ]] && v="${v%%"${BASH_REMATCH[0]}"*}"
        printf '%s\n' "$v"
    done < "$1"
    return 0
}

# _lc_artifacts_walk <dir> <keep> — appends to _LC_DENY_OUT; recurses only
# into a folder that holds something kept.
_lc_artifacts_walk() {
    local dir="$1" keep="$2" e
    while IFS= read -r e; do
        [[ -n "$e" ]] || continue
        if [[ -d "$e" && ! -L "$e" ]]; then
            if [[ $'\n'"$keep" == *$'\n'"$e/"* ]]; then
                _lc_artifacts_walk "$e" "$keep"
            else
                _LC_DENY_OUT+="$e/**"$'\n'
            fi
        elif [[ $'\n'"$keep" != *$'\n'"$e"$'\n'* ]]; then
            _LC_DENY_OUT+="$e"$'\n'
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)
}
