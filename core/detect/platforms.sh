#!/usr/bin/env bash
# core/detect/platforms.sh — Platform detection engine (issues #194, #195, #196, #197)
# ADR-009 (platform-aware modularity)
# v2: manifest-based detect.signals, v2 config schema, conflict resolution.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_DETECT_LOADED:-}" ]] && return 0
_ZBUILD_DETECT_LOADED=1

_ZBUILD_DETECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ZBUILD_DETECT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../state/atomic.sh
source "$_ZBUILD_ROOT/core/state/atomic.sh"
# shellcheck source=../plugin-registry/registry.sh
source "$_ZBUILD_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../event-bus/event-bus.sh
source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"

# Legacy hardcoded indicator patterns — used when a plugin has no detect.signals block.
_PLATFORM_INDICATORS_ios="Package.swift:*.xcodeproj:*.xcworkspace:Podfile"
_PLATFORM_INDICATORS_node="package.json"
_PLATFORM_INDICATORS_python="requirements.txt:setup.py:pyproject.toml"
_PLATFORM_INDICATORS_go="go.mod"

# ─── _strength_to_score ─────────────────────────────────────────────────────
_strength_to_score() {
    case "$1" in
        high)   echo 3 ;;
        medium) echo 2 ;;
        low)    echo 1 ;;
        *)      echo 0 ;;
    esac
}

# ─── _parse_detect_signals ───────────────────────────────────────────────────
# Parse detect.signals from a manifest YAML for a given kind (files|directories).
# Emits lines: pattern:strength
_parse_detect_signals() {
    local manifest="$1"
    local kind="$2"
    [[ -f "$manifest" ]] || return 0
    awk -v kind="$kind" '
        /^detect:[[:space:]]*$/        { in_detect=1; next }
        in_detect && /^[a-zA-Z_]/ && !/^[[:space:]]/ { in_detect=0; in_signals=0; in_kind=0 }
        in_detect && /^[[:space:]]+signals:[[:space:]]*$/ { in_signals=1; next }
        in_signals && /^[[:space:]]+[a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$/ {
            blk=$0; sub(/^[[:space:]]+/, "", blk); sub(/:.*/, "", blk)
            in_kind=(blk == kind)
            next
        }
        in_kind && /^[[:space:]]+-[[:space:]]+pattern:/ {
            val=$0; sub(/^[^:]+:[[:space:]]*/, "", val)
            gsub(/[[:space:]]*$|"/, "", val)
            cur_pat=val
        }
        in_kind && cur_pat != "" && /^[[:space:]]+strength:/ {
            val=$0; sub(/^[^:]+:[[:space:]]*/, "", val)
            gsub(/[[:space:]]*$|"/, "", val)
            if (val == "") val="low"
            print cur_pat ":" val
            cur_pat=""
        }
    ' "$manifest" 2>/dev/null
}

# ─── _platform_detected_in_repo_legacy ──────────────────────────────────────
# Hardcoded indicator check — used when plugin has no detect.signals.
_platform_detected_in_repo_legacy() {
    local platform="$1"
    local repo_root="$2"
    local indicator_var="_PLATFORM_INDICATORS_${platform}"
    local indicators="${!indicator_var:-}"
    if [[ -z "$indicators" ]]; then
        return 0  # unknown platform — conservative: detected
    fi
    local IFS=':'
    for pattern in $indicators; do
        # -print -quit: find stops at the first hit, so this neither races a reader (#1884) nor buffers the walk.
        if [[ -n "$(find "$repo_root" -maxdepth 3 -name "$pattern" -print -quit 2>/dev/null)" ]]; then
            return 0
        fi
    done
    return 1
}

# ─── _score_platform_signals ─────────────────────────────────────────────────
# Score a platform against repo_root using detect.signals from its manifests.
# disable_paths: colon-delimited path prefixes (relative to repo_root) to skip.
# Prints integer score; 0 = not detected.
_score_platform_signals() {
    local platform="$1"
    local repo_root="$2"
    local plugins_root="$3"
    local disable_paths="${4:-}"
    local total=0
    local has_signals=false

    # Pre-split disable_paths to avoid IFS conflicts inside nested loops
    local disable_arr=()
    if [[ -n "$disable_paths" ]]; then
        local _ifs_save="$IFS"
        IFS=':' read -ra disable_arr <<< "$disable_paths"
        IFS="$_ifs_save"
    fi

    while IFS= read -r plugin_dir; do
        local manifest="$plugin_dir/manifest.yaml"
        [[ -f "$manifest" ]] || continue
        local mp
        mp="$(yaml_get "$manifest" "platform" 2>/dev/null || true)"
        [[ "$mp" == "$platform" ]] || continue

        # Score file signals
        local sig_line
        while IFS= read -r sig_line; do
            [[ -z "$sig_line" ]] && continue
            has_signals=true
            local pat="${sig_line%%:*}"
            local str="${sig_line#*:}"
            local weight; weight="$(_strength_to_score "$str")"
            (( weight == 0 )) && continue

            local found=false
            local fpath
            while IFS= read -r fpath; do
                [[ -z "$fpath" ]] && continue
                local excluded=false
                local dis
                for dis in "${disable_arr[@]+"${disable_arr[@]}"}"; do
                    [[ -z "$dis" ]] && continue
                    local dis_abs="$repo_root/${dis%/}"
                    if [[ "$fpath" == "$dis_abs"/* || "$fpath" == "$dis_abs" ]]; then
                        excluded=true; break
                    fi
                done
                if ! $excluded; then found=true; break; fi
            done < <(find "$repo_root" -maxdepth 3 -name "$pat" 2>/dev/null)

            $found && total=$((total + weight))
        done < <(_parse_detect_signals "$manifest" "files")

        # Score directory signals
        while IFS= read -r sig_line; do
            [[ -z "$sig_line" ]] && continue
            has_signals=true
            local pat="${sig_line%%:*}"
            local str="${sig_line#*:}"
            local weight; weight="$(_strength_to_score "$str")"
            (( weight == 0 )) && continue
            local dir_pat="${pat%/}"
            if [[ -n "$(find "$repo_root" -maxdepth 3 -type d -name "$dir_pat" -print -quit 2>/dev/null)" ]]; then
                total=$((total + weight))
            fi
        done < <(_parse_detect_signals "$manifest" "directories")
    done < <(discover_plugins "$plugins_root" 2>/dev/null)

    if ! $has_signals; then
        # No detect.signals declared — fall back to legacy hardcoded indicators
        if _platform_detected_in_repo_legacy "$platform" "$repo_root"; then
            echo 1
        else
            echo 0
        fi
        return 0
    fi

    echo "$total"
}

# ─── _load_platforms_config ──────────────────────────────────────────────────
# Load .zbuild/platforms.json (v1 or v2 schema) into caller-scope globals:
#   _CFG_OVERRIDE_PLATFORMS  space-separated platform names to inject
#   _CFG_DISABLE_PATHS       colon-separated path prefixes to exclude
#   _CFG_ALIASES             newline-separated "alias=canonical" pairs
#   _CFG_FALLBACK            fallback_platform (empty → use "generic")
_load_platforms_config() {
    local config_file="$1"
    _CFG_OVERRIDE_PLATFORMS=""
    _CFG_DISABLE_PATHS=""
    _CFG_ALIASES=""
    _CFG_FALLBACK=""

    [[ -f "$config_file" ]] || return 0

    if ! jq empty "$config_file" 2>/dev/null; then
        warn "detect: .zbuild/platforms.json is invalid JSON; ignoring"
        return 0
    fi

    # Detect v2: schema_version:2 or any v2-exclusive key present
    local is_v2=false
    if jq -e '.schema_version == 2 or has("overrides") or has("disable_detection") or has("aliases") or has("fallback_platform")' \
            "$config_file" >/dev/null 2>&1; then
        is_v2=true
    fi

    local p
    if $is_v2; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            if [[ "$p" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
                _CFG_OVERRIDE_PLATFORMS="${_CFG_OVERRIDE_PLATFORMS:+$_CFG_OVERRIDE_PLATFORMS }$p"
            else
                warn "detect: ignoring invalid override platform name: $p"
            fi
        done < <(jq -r '.overrides[]?.platform // empty' "$config_file" 2>/dev/null || true)

        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            _CFG_DISABLE_PATHS="${_CFG_DISABLE_PATHS:+$_CFG_DISABLE_PATHS:}$d"
        done < <(jq -r '.disable_detection[]? // empty' "$config_file" 2>/dev/null || true)

        _CFG_ALIASES="$(jq -r 'if has("aliases") then .aliases | to_entries[] | "\(.key)=\(.value)" else empty end' \
            "$config_file" 2>/dev/null || true)"

        _CFG_FALLBACK="$(jq -r '.fallback_platform // empty' "$config_file" 2>/dev/null || true)"
    else
        # v1 legacy: {"platforms": ["python"]}
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            if [[ "$p" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
                _CFG_OVERRIDE_PLATFORMS="${_CFG_OVERRIDE_PLATFORMS:+$_CFG_OVERRIDE_PLATFORMS }$p"
            else
                warn "detect: ignoring invalid override platform name: $p"
            fi
        done < <(jq -r '.platforms[]? // empty' "$config_file" 2>/dev/null || true)
    fi
}

# ─── _resolve_alias ─────────────────────────────────────────────────────────
# Resolve a platform name through _CFG_ALIASES ("alias=canonical" newline pairs).
_resolve_alias() {
    local platform="$1"
    [[ -z "${_CFG_ALIASES:-}" ]] && { echo "$platform"; return 0; }
    local alias canonical
    while IFS='=' read -r alias canonical; do
        [[ -z "$alias" || -z "$canonical" ]] && continue
        [[ "$alias" == "$platform" ]] && { echo "$canonical"; return 0; }
    done <<< "$_CFG_ALIASES"
    echo "$platform"
}

# ─── detect_platforms ────────────────────────────────────────────────────────
detect_platforms() {
    local repo_root="${1:-$PWD}"
    local state_dir="${2:-${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}}"
    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}"
    local platforms_file="$state_dir/platforms.json"

    mkdir -p "$state_dir"

    # Load .zbuild/platforms.json config (v1 or v2)
    _load_platforms_config "$repo_root/.zbuild/platforms.json"

    # Short-circuit: ZBUILD_PLATFORM_OVERRIDE env var bypasses all detection
    if [[ -n "${ZBUILD_PLATFORM_OVERRIDE:-}" ]]; then
        local override_sha=""
        override_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")"
        jq -n \
            --arg platform "$ZBUILD_PLATFORM_OVERRIDE" \
            --arg sha "$override_sha" \
            --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{
                schema_version: 1,
                repo_head_sha: $sha,
                detected: [$platform],
                overrides: [],
                updated_at: $now
            }' | atomic_write "$platforms_file"
        echo "$ZBUILD_PLATFORM_OVERRIDE"
        return 0
    fi

    # Cache check: if platforms.json SHA matches HEAD, return cached + apply config overrides
    local current_sha=""
    current_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")"

    if [[ -n "$current_sha" && -f "$platforms_file" ]]; then
        local cached_sha
        cached_sha="$(jq -r '.repo_head_sha // empty' "$platforms_file" 2>/dev/null || echo "")"
        if [[ -n "$cached_sha" && "$cached_sha" == "$current_sha" ]]; then
            local cached_platforms=()
            local cp
            while IFS= read -r cp; do
                [[ -n "$cp" ]] && cached_platforms+=("$cp")
            done < <(jq -r '.detected[]' "$platforms_file" 2>/dev/null)
            local ov
            for ov in ${_CFG_OVERRIDE_PLATFORMS:-}; do
                local already=false
                local ep
                for ep in "${cached_platforms[@]+"${cached_platforms[@]}"}"; do
                    [[ "$ep" == "$ov" ]] && { already=true; break; }
                done
                $already || cached_platforms+=("$ov")
            done
            printf '%s\n' "${cached_platforms[@]+"${cached_platforms[@]}"}"
            return 0
        fi
    fi

    # Collect unique platform names declared by plugin manifests
    local unique_platforms=()
    local plugin_dir
    while IFS= read -r plugin_dir; do
        local manifest="$plugin_dir/manifest.yaml"
        local plugin_platform
        plugin_platform="$(yaml_get "$manifest" "platform" 2>/dev/null || true)"
        [[ -z "$plugin_platform" || "$plugin_platform" == "null" ]] && continue
        local already=false
        if [[ ${#unique_platforms[@]} -gt 0 ]]; then
            local p
            for p in "${unique_platforms[@]}"; do
                [[ "$p" == "$plugin_platform" ]] && { already=true; break; }
            done
        fi
        $already || unique_platforms+=("$plugin_platform")
    done < <(discover_plugins "$plugins_root" 2>/dev/null)

    # Score each platform using detect.signals (or legacy hardcoded fallback)
    local detected_platforms=()
    local detected_scores=()

    if [[ ${#unique_platforms[@]} -gt 0 ]]; then
        local platform
        for platform in "${unique_platforms[@]}"; do
            local score
            score="$(_score_platform_signals "$platform" "$repo_root" "$plugins_root" "${_CFG_DISABLE_PATHS:-}")"
            if (( score > 0 )); then
                detected_platforms+=("$platform")
                detected_scores+=("$score")
            fi
        done
    fi

    # Conflict detection: two or more platforms tied at max score
    if [[ ${#detected_platforms[@]} -ge 2 ]]; then
        local max_score=0
        local s
        for s in "${detected_scores[@]}"; do
            (( s > max_score )) && max_score=$s
        done
        local tied_platforms=()
        local i
        for (( i=0; i<${#detected_platforms[@]}; i++ )); do
            (( detected_scores[i] == max_score )) && tied_platforms+=("${detected_platforms[$i]}")
        done

        if [[ ${#tied_platforms[@]} -ge 2 ]]; then
            # Check if a config override can resolve the tie without emitting a conflict event
            local override_winner=""
            local tp
            for tp in "${tied_platforms[@]}"; do
                local ov
                for ov in ${_CFG_OVERRIDE_PLATFORMS:-}; do
                    [[ "$ov" == "$tp" ]] && { override_winner="$tp"; break 2; }
                done
            done

            if [[ -n "$override_winner" ]]; then
                # Override silently resolves tie — no conflict event
                detected_platforms=("$override_winner")
                detected_scores=("$max_score")
            else
                # No override: emit detection.conflict event
                local tied_str
                tied_str="$(printf '%s,' "${tied_platforms[@]}")"
                tied_str="${tied_str%,}"
                emit_event "detection.conflict" \
                    "platforms=$tied_str" \
                    "score=$max_score" 2>/dev/null || true

                # Apply fallback_platform if it's one of the tied candidates
                if [[ -n "${_CFG_FALLBACK:-}" ]]; then
                    local fb_found=false
                    for tp in "${tied_platforms[@]}"; do
                        [[ "$tp" == "$_CFG_FALLBACK" ]] && { fb_found=true; break; }
                    done
                    if $fb_found; then
                        detected_platforms=("$_CFG_FALLBACK")
                        detected_scores=("$max_score")
                    fi
                fi
                # No fallback → keep all tied platforms (ambiguous multi-platform result)
            fi
        fi
    fi

    # Inject config override platforms (v1 legacy list + v2 overrides[].platform)
    local ov
    for ov in ${_CFG_OVERRIDE_PLATFORMS:-}; do
        [[ -z "$ov" ]] && continue
        local already=false
        local dp
        for dp in "${detected_platforms[@]+"${detected_platforms[@]}"}"; do
            [[ "$dp" == "$ov" ]] && { already=true; break; }
        done
        $already || detected_platforms+=("$ov")
    done

    # Resolve aliases and deduplicate
    local resolved_platforms=()
    local rp
    for rp in "${detected_platforms[@]+"${detected_platforms[@]}"}"; do
        local canonical
        canonical="$(_resolve_alias "$rp")"
        local already=false
        local ep
        for ep in "${resolved_platforms[@]+"${resolved_platforms[@]}"}"; do
            [[ "$ep" == "$canonical" ]] && { already=true; break; }
        done
        $already || resolved_platforms+=("$canonical")
    done
    detected_platforms=("${resolved_platforms[@]+"${resolved_platforms[@]}"}")

    # Fallback floor: use fallback_platform or "generic" when nothing detected
    if [[ ${#detected_platforms[@]} -eq 0 ]]; then
        if [[ -n "${_CFG_FALLBACK:-}" ]]; then
            detected_platforms=("$_CFG_FALLBACK")
        else
            detected_platforms=("generic")
        fi
    fi

    # Write platforms.json using jq for safe JSON array construction
    local platforms_json
    platforms_json="$(printf '%s\n' "${detected_platforms[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')"

    jq -n \
        --arg sha "$current_sha" \
        --argjson platforms "$platforms_json" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            schema_version: 1,
            repo_head_sha: $sha,
            detected: $platforms,
            overrides: [],
            updated_at: $now
        }' | atomic_write "$platforms_file"

    printf '%s\n' "${detected_platforms[@]}"
}
