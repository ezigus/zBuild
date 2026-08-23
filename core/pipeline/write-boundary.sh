#!/usr/bin/env bash
# core/pipeline/write-boundary.sh — post-dispatch write-boundary enforcement (#1809, ADR-058 C9)
#
# Six functions: mark, watch_list, allow_list, sweep, classify, violation_recorded,
# and check. Wire write_boundary_mark before plugin.$hook_name.start in lifecycle.sh,
# and write_boundary_check as a sibling of scan_plugin_outputs in the rc=0 run branch.
# Both are guarded on state_file being an absolute path.
#
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_WRITE_BOUNDARY_LOADED:-}" ]] && return 0
_ZBUILD_WRITE_BOUNDARY_LOADED=1

_ZBUILD_WB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_WB_ROOT="$(cd "$_ZBUILD_WB_DIR/../.." && pwd)"

# #1809 (ADR-058 C9): the SAME resolver scan_plugin_outputs uses. Two copies of
# this logic is how the two halves of the boundary drift apart.
# shellcheck source=../plugin-registry/output-paths.sh
source "$_ZBUILD_WB_ROOT/core/plugin-registry/output-paths.sh"

# ─── write_boundary_mark <state_file> ────────────────────────────────────────
# Touch the per-dispatch marker. No-op when state_file is empty or relative.
write_boundary_mark() {
    local state_file="${1:-}"
    [[ "$state_file" == /* ]] || return 0
    local state_dir; state_dir="$(dirname "$state_file")"
    mkdir -p "${state_dir}/runtime" 2>/dev/null || return 0
    touch "${state_dir}/runtime/write-boundary.marker" 2>/dev/null || true
}

# ─── write_boundary_watch_list ───────────────────────────────────────────────
# Emit the watch-location list, one entry per line: "<path>[ maxdepth:<N>]".
# Three-tier override: ZBUILD_WRITE_BOUNDARY_WATCH env > ~/.zbuild/ > shipped default.
write_boundary_watch_list() {
    local _cfg="${ZBUILD_WRITE_BOUNDARY_WATCH:-}"
    if [[ -z "$_cfg" ]]; then
        local _user="${HOME}/.zbuild/write-boundary-watch.txt"
        [[ -f "$_user" ]] && _cfg="$_user"
    fi
    [[ -z "$_cfg" ]] && _cfg="$_ZBUILD_WB_ROOT/config/write-boundary-watch.txt"

    if [[ -f "$_cfg" ]]; then
        while IFS= read -r _line; do
            [[ -z "$_line" || "$_line" =~ ^# ]] && continue
            # Expand simple ${VAR} tokens. Handle ${TMPDIR:-/tmp} and ${PWD} as specials.
            local _exp="$_line" _v _n=0
            _exp="${_exp//\$\{TMPDIR:-\/tmp\}/${TMPDIR:-/tmp}}"
            while [[ $_n -lt 8 ]] && [[ "$_exp" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
                _v="${BASH_REMATCH[1]}"
                [[ -z "${!_v+x}" ]] && break
                _exp="${_exp//\$\{$_v\}/${!_v}}"
                _n=$((_n + 1))
            done
            printf '%s\n' "$_exp"
        done < "$_cfg"
    else
        # Built-in defaults when config file is absent.
        printf '%s maxdepth:1\n' "$HOME"
        printf '%s\n' "$HOME/.zbuild"
        printf '%s maxdepth:1\n' "${TMPDIR:-/tmp}"
        [[ "${TMPDIR:-/tmp}" != "/tmp" ]] && printf '/tmp maxdepth:1\n'
        printf '%s maxdepth:1\n' "$PWD"
        printf '%s maxdepth:2\n' "$_ZBUILD_WB_ROOT"
    fi
}

# ─── write_boundary_allow_list <state_dir> ───────────────────────────────────
# Emit the allowed-root list. Engine-owned roots are always emitted from code
# (additive-only guarantee: no config file can remove them).
write_boundary_allow_list() {
    local _sd="${1:-}"

    # Engine-owned roots — always allowed, cannot be removed by any override.
    [[ -n "$_sd" ]] && printf '%s\n' "$_sd"
    if [[ -n "${ZBUILD_REPO_ROOT:-}" ]]; then
        printf '%s\n' "$ZBUILD_REPO_ROOT"
    else
        # Fallback: derive from git when ZBUILD_REPO_ROOT is not yet exported
        # (e.g. during in-place dispatch before the runner sets it, or in tests
        # that explicitly unset it).
        local _gr; _gr="$(git rev-parse --show-toplevel 2>/dev/null)" \
            && [[ -n "$_gr" ]] && printf '%s\n' "$_gr" || true
    fi
    local _sb="${ZBUILD_SCRATCH_ROOT:-$_sd}"
    [[ -n "$_sb" ]] && printf '%s\n' "${_sb%/}/scratch"
    # ADR-011 stores live under ~/.zbuild.
    printf '%s\n' "$HOME/.zbuild"
    # The event bus's own files. With nothing pinned it falls back to an
    # ephemeral per-process dir under $TMPDIR (core/event-bus/event-bus.sh:37),
    # which resolves to /tmp on Linux where TMPDIR is unset — i.e. inside a
    # watched root. The engine writing its own event log during a dispatch is
    # not a stage writing out of bounds, and every emit_event on the path does
    # exactly that. /dev/null is the "JSONL only, no mirror" sentinel and has no
    # meaningful parent to allow.
    if [[ -n "${ZBUILD_EVENTS_DIR:-}" ]]; then
        printf '%s\n' "$ZBUILD_EVENTS_DIR"
    fi
    if [[ -n "${ZBUILD_EVENTS_JSONL:-}" && "${ZBUILD_EVENTS_JSONL}" != "/dev/null" ]]; then
        printf '%s\n' "$(dirname "$ZBUILD_EVENTS_JSONL")"
    fi
    if [[ -n "${ZBUILD_EVENTS_DB:-}" && "${ZBUILD_EVENTS_DB}" != "/dev/null" ]]; then
        printf '%s\n' "$(dirname "$ZBUILD_EVENTS_DB")"
    fi

    # Config additions (all tiers loaded — truly additive, not override).
    local _shipped="$_ZBUILD_WB_ROOT/config/write-boundary-allow.txt"
    local _user="${HOME}/.zbuild/write-boundary-allow.txt"
    local _env_cfg="${ZBUILD_WRITE_BOUNDARY_ALLOW:-}"
    for _cfg in "$_shipped" "$_user" "${_env_cfg:+$_env_cfg}"; do
        [[ -f "$_cfg" ]] || continue
        while IFS= read -r _line; do
            [[ -z "$_line" || "$_line" =~ ^# ]] && continue
            local _exp="$_line" _v _n=0
            _exp="${_exp//\$\{CLAUDE_CONFIG_DIR:-\$\{HOME\}\/.claude\}/${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
            _exp="${_exp//\$\{CLAUDE_CONFIG_DIR:-\$HOME\/.claude\}/${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
            while [[ $_n -lt 8 ]] && [[ "$_exp" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
                _v="${BASH_REMATCH[1]}"
                [[ -z "${!_v+x}" ]] && break
                _exp="${_exp//\$\{$_v\}/${!_v}}"
                _n=$((_n + 1))
            done
            printf '%s\n' "$_exp"
        done < "$_cfg"
    done
}

# ─── write_boundary_sweep <marker_file> ─────────────────────────────────────
# Print paths of files written after <marker_file> in the watch locations.
write_boundary_sweep() {
    local _marker="$1"
    [[ -f "$_marker" ]] || return 0
    local _entry _path _depth
    while IFS= read -r _entry; do
        [[ -z "$_entry" || "$_entry" =~ ^# ]] && continue
        _path="${_entry%% maxdepth:*}"
        _path="${_path%% *}"
        _depth=3
        [[ "$_entry" =~ maxdepth:([0-9]+) ]] && _depth="${BASH_REMATCH[1]}"
        [[ -d "$_path" ]] || continue
        # -type f: the sweep asks "did this stage drop a FILE where nothing
        # should be?" — the issue's own honesty argument for -maxdepth 1. A bare
        # directory entry cannot answer it. A directory's mtime changes whenever
        # ANY process creates a child inside it, and mtime does not carry
        # authorship, so directory hits are unattributable by construction: CI
        # flagged two other integration tests' mktemp -d dirs and a child
        # process's event dir, none of them written by the stage under check.
        # Restricting to regular files keeps the measured defect (a stage wrote
        # to /tmp) and drops the class that cannot be attributed.
        find "$_path" -maxdepth "$_depth" -mindepth 1 -type f -newer "$_marker" 2>/dev/null || true
    done <<< "$(write_boundary_watch_list)"
}

# ─── write_boundary_classify <candidate> <state_dir> <plugin_dir> ────────────
# Print: declared | allowed | violation
write_boundary_classify() {
    local _cand="$1" _sd="${2:-}" _pd="${3:-}" _allow="${4:-}"

    # Resolve candidate to a canonical absolute path.
    # pwd -P, not pwd: on macOS /var is a symlink to /private/var, and the
    # allow roots arrive already canonicalised (git rev-parse --show-toplevel
    # returns /private/...). Bare pwd returns the LOGICAL path, so the candidate
    # and the root disagree and every in-place dispatch reports a false
    # violation. cleanup.sh:534-537 paid for this once already.
    local _cd; _cd="$(cd "$(dirname "$_cand")" 2>/dev/null && pwd -P)/$(basename "$_cand")" \
        || _cd="$_cand"

    # 1. Check declared outputs from plugin manifest.
    if [[ -n "$_pd" && -f "$_pd/manifest.yaml" ]]; then
        local _art="${_sd}/artifacts"
        local _rp _res
        while IFS=$'\t' read -r _rp _; do
            [[ -z "$_rp" ]] && continue
            _res="$(_registry_resolve_output_path "$_rp" "$_sd" "$_art")"
            local _cr; _cr="$(cd "$(dirname "$_res")" 2>/dev/null && pwd -P)/$(basename "$_res")" \
                || _cr="$_res"
            local _dd; _dd="$(dirname "$_cr")"
            if [[ "$_cd" == "$_cr" || "$_cd" == "${_dd}/"* ]]; then
                printf 'declared'; return 0
            fi
        done < <(_registry_output_path_rows "$_pd/manifest.yaml")
    fi

    # 2. Check allowed areas.
    # The caller may hand in a precomputed allow list. write_boundary_allow_list
    # shells out to `git rev-parse --show-toplevel` when ZBUILD_REPO_ROOT is
    # unset, and the sweep can hand this function many candidates — recomputing
    # per candidate meant one git subprocess each. Computed here only when the
    # caller did not (direct callers, including the unit tests, pass nothing).
    [[ -z "$_allow" ]] && _allow="$(write_boundary_allow_list "$_sd")"
    local _ar _ca
    while IFS= read -r _ar; do
        [[ -z "$_ar" ]] && continue
        _ca="$(cd "$_ar" 2>/dev/null && pwd -P)" || _ca="$_ar"
        # Candidate under an allowed root, OR the candidate is a strict ANCESTOR
        # of one. The ancestor arm is not a loophole: `find` reports directories,
        # and a directory's mtime changes when a child is created inside it — so
        # the state dir's own parent surfaces in the sweep whenever the state dir
        # lives under a watched root. That is the normal shape on Linux, where
        # TMPDIR is unset and everything lands under /tmp; the write it reflects
        # landed INSIDE an allowed root. A file can never be an ancestor, and a
        # genuinely stray directory (/tmp/newdir holding no allowed root) still
        # classifies as a violation.
        if [[ "$_cd" == "$_ca" || "$_cd" == "${_ca}/"* || "$_ca" == "${_cd}/"* ]]; then
            printf 'allowed'; return 0
        fi
    done <<< "$_allow"

    printf 'violation'
}

# ─── write_boundary_violation_recorded <state_dir> <stage> ──────────────────
# Mark the violation and emit the declared event.
write_boundary_violation_recorded() {
    local _sd="$1" _stage="${2:-}" _path="${3:-}"
    mkdir -p "${_sd}/runtime" 2>/dev/null || true
    # The marker carries the offending path as its content. Only its EXISTENCE
    # is load-bearing (verdict.sh tests -f), so the body is free to be evidence:
    # `broken` is terminal, and the state dir is what survives the run.
    printf '%s\n' "$_path" > "${_sd}/runtime/write-boundary-violated" 2>/dev/null || true
    # The offending path, on both channels. A run that halts naming no path
    # leaves the operator with nothing to act on, and the disposition is
    # `broken` — terminal, not retryable — so there is no second chance to
    # observe it. `path=` is a data field on an already-declared event, so the
    # event NAME set is unchanged and the sequence goldens are untouched.
    printf 'write-boundary violation: stage=%s wrote outside every allowed area: %s\n' \
        "$_stage" "$_path" >&2
    # ZBUILD_WRITE_BOUNDARY_LOG: an append-only sink for the same line, for
    # contexts that discard the dispatch's stderr. Most integration tests send
    # the runner's stderr to /dev/null, so a halt there reports only a non-zero
    # rc and the operator (or CI) never learns which path caused it. Off unless
    # the variable is set; failure to write is ignored, since a diagnostic must
    # never be the reason a run behaves differently.
    if [[ -n "${ZBUILD_WRITE_BOUNDARY_LOG:-}" ]]; then
        printf 'stage=%s path=%s\n' "$_stage" "$_path" \
            >> "$ZBUILD_WRITE_BOUNDARY_LOG" 2>/dev/null || true
    fi
    if declare -F emit_event >/dev/null 2>&1; then
        emit_event "stage.write_boundary.violated" "stage=${_stage}" "path=${_path}" || true
    fi
}

# ─── write_boundary_check <plugin_dir> <state_file> <stage> [<map_element>] ──
# Orchestrate sweep + classify. Returns 1 on first violation, 0 otherwise.
# First line guards on empty state_file.
write_boundary_check() {
    local _pd="$1" _sf="${2:-}" _stage="${3:-}" _el="${4:-}"
    [[ -z "$_sf" ]] && return 0
    [[ "$_sf" == /* ]] || return 0
    local _sd; _sd="$(dirname "$_sf")"
    local _marker="${_sd}/runtime/write-boundary.marker"
    [[ -f "$_marker" ]] || return 0
    # Resolve the allow list ONCE per dispatch, not once per swept candidate.
    local _allow; _allow="$(write_boundary_allow_list "$_sd")"
    local _cand _cls
    while IFS= read -r _cand; do
        [[ -z "$_cand" ]] && continue
        _cls="$(write_boundary_classify "$_cand" "$_sd" "$_pd" "$_allow")"
        if [[ "$_cls" == "violation" ]]; then
            write_boundary_violation_recorded "$_sd" "$_stage" "$_cand"
            return 1
        fi
    done <<< "$(write_boundary_sweep "$_marker")"
    return 0
}
