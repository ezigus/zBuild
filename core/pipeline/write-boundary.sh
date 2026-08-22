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
    [[ -n "${ZBUILD_REPO_ROOT:-}" ]] && printf '%s\n' "$ZBUILD_REPO_ROOT"
    local _sb="${ZBUILD_SCRATCH_ROOT:-$_sd}"
    [[ -n "$_sb" ]] && printf '%s\n' "${_sb%/}/scratch"
    # ADR-011 stores live under ~/.zbuild.
    printf '%s\n' "$HOME/.zbuild"

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
        find "$_path" -maxdepth "$_depth" -mindepth 1 -newer "$_marker" 2>/dev/null || true
    done <<< "$(write_boundary_watch_list)"
}

# ─── write_boundary_classify <candidate> <state_dir> <plugin_dir> ────────────
# Print: declared | allowed | violation
write_boundary_classify() {
    local _cand="$1" _sd="${2:-}" _pd="${3:-}"

    # Resolve candidate to a canonical absolute path.
    local _cd; _cd="$(cd "$(dirname "$_cand")" 2>/dev/null && pwd)/$(basename "$_cand")" \
        || _cd="$_cand"

    # 1. Check declared outputs from plugin manifest.
    if [[ -n "$_pd" && -f "$_pd/manifest.yaml" ]]; then
        local _art="${_sd}/artifacts"
        local _rp _res _v _n
        while IFS=$'\t' read -r _rp _; do
            [[ -z "$_rp" ]] && continue
            _res="$_rp"
            _res="${_res//\$\{state_dir\}/$_sd}"
            _res="${_res//\$\{artifact_dir\}/$_art}"
            _res="${_res//\$\{artifacts_dir\}/$_art}"
            _n=0
            while [[ $_n -lt 16 ]] && [[ "$_res" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
                _v="${BASH_REMATCH[1]}"
                [[ -z "${!_v+x}" ]] && break
                _res="${_res//\$\{$_v\}/${!_v}}"
                _n=$((_n + 1))
            done
            local _cr; _cr="$(cd "$(dirname "$_res")" 2>/dev/null && pwd)/$(basename "$_res")" \
                || _cr="$_res"
            local _dd; _dd="$(dirname "$_cr")"
            if [[ "$_cd" == "$_cr" || "$_cd" == "${_dd}/"* ]]; then
                printf 'declared'; return 0
            fi
        done < <(awk '
            BEGIN { b=0; p=""; r="" }
            function flush() { if (p!="" && r!="false") print p"\t"; p=""; r="" }
            /^outputs:[[:space:]]*$/ { b=1; next }
            b && /^[a-zA-Z_]/ { flush(); b=0 }
            b && /^[[:space:]]*-[[:space:]]/ { flush() }
            b && /^[[:space:]]+path:[[:space:]]*/ {
                l=$0; sub(/^[[:space:]]+path:[[:space:]]*/,"",l)
                sub(/[[:space:]]*#.*/,"",l); gsub(/^["'"'"']|["'"'"']$/,"",l)
                p=l; next }
            b && /^[[:space:]]+required:[[:space:]]*/ {
                l=$0; sub(/^[[:space:]]+required:[[:space:]]*/,"",l)
                sub(/[[:space:]]*#.*/,"",l); gsub(/^["'"'"']|["'"'"']$/,"",l)
                r=l; next }
            END { flush() }
        ' "$_pd/manifest.yaml" 2>/dev/null)
    fi

    # 2. Check allowed areas.
    local _ar _ca
    while IFS= read -r _ar; do
        [[ -z "$_ar" ]] && continue
        _ca="$(cd "$_ar" 2>/dev/null && pwd)" || _ca="$_ar"
        if [[ "$_cd" == "$_ca" || "$_cd" == "${_ca}/"* ]]; then
            printf 'allowed'; return 0
        fi
    done <<< "$(write_boundary_allow_list "$_sd")"

    printf 'violation'
}

# ─── write_boundary_violation_recorded <state_dir> <stage> ──────────────────
# Mark the violation and emit the declared event.
write_boundary_violation_recorded() {
    local _sd="$1" _stage="${2:-}"
    mkdir -p "${_sd}/runtime" 2>/dev/null || true
    touch "${_sd}/runtime/write-boundary-violated" 2>/dev/null || true
    if declare -F emit_event >/dev/null 2>&1; then
        emit_event "stage.write_boundary.violated" "stage=${_stage}" || true
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
    local _cand _cls
    while IFS= read -r _cand; do
        [[ -z "$_cand" ]] && continue
        _cls="$(write_boundary_classify "$_cand" "$_sd" "$_pd")"
        if [[ "$_cls" == "violation" ]]; then
            write_boundary_violation_recorded "$_sd" "$_stage"
            return 1
        fi
    done <<< "$(write_boundary_sweep "$_marker")"
    return 0
}
