#!/usr/bin/env bash
# core/detect/platforms.sh — Platform detection engine (issue #208, #194)
# ADR-009 (platform-aware modularity)
# NOTE: detect.signals manifest parsing deferred to Phase 1.
# v1 uses hardcoded platform indicator patterns.

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

# Hardcoded indicator patterns per platform (Phase 1: read from manifest detect.signals)
_PLATFORM_INDICATORS_ios="Package.swift:*.xcodeproj:*.xcworkspace:Podfile"
_PLATFORM_INDICATORS_node="package.json"
_PLATFORM_INDICATORS_python="requirements.txt:setup.py:pyproject.toml"
_PLATFORM_INDICATORS_go="go.mod"

# Returns 0 if platform is detectable in repo_root
_platform_detected_in_repo() {
    local platform="$1"
    local repo_root="$2"
    local indicator_var="_PLATFORM_INDICATORS_${platform}"
    local indicators="${!indicator_var:-}"

    if [[ -z "$indicators" ]]; then
        # Unknown platform — conservative: report as detected
        return 0
    fi

    local IFS=':'
    for pattern in $indicators; do
        if find "$repo_root" -maxdepth 3 -name "$pattern" 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

detect_platforms() {
    local repo_root="${1:-$PWD}"
    local state_dir="${2:-${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}}"
    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}"
    local platforms_file="$state_dir/platforms.json"

    mkdir -p "$state_dir"

    # Cache check: if platforms.json exists and SHA matches current HEAD, return cached
    local current_sha=""
    current_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")"

    if [[ -n "$current_sha" && -f "$platforms_file" ]]; then
        local cached_sha
        cached_sha="$(jq -r '.repo_head_sha // empty' "$platforms_file" 2>/dev/null || echo "")"
        if [[ -n "$cached_sha" && "$cached_sha" == "$current_sha" ]]; then
            local cached_platforms=()
            while IFS= read -r p; do
                [[ -n "$p" ]] && cached_platforms+=("$p")
            done < <(jq -r '.detected[]' "$platforms_file" 2>/dev/null)
            # Apply overrides even on cache hit so config changes take effect immediately
            local overrides_file="$repo_root/.zbuild/platforms.json"
            if [[ -f "$overrides_file" ]]; then
                while IFS= read -r p; do
                    [[ -z "$p" ]] && continue
                    local already=false
                    for cp in "${cached_platforms[@]+"${cached_platforms[@]}"}"; do
                        [[ "$cp" == "$p" ]] && { already=true; break; }
                    done
                    $already || cached_platforms+=("$p")
                done < <(jq -r '.platforms[]? // empty' "$overrides_file" 2>/dev/null)
            fi
            printf '%s\n' "${cached_platforms[@]+"${cached_platforms[@]}"}"
            return 0
        fi
    fi

    # Collect unique platforms declared by plugins
    local unique_platforms=()
    while IFS= read -r plugin_dir; do
        local manifest="$plugin_dir/manifest.yaml"
        local plugin_platform
        plugin_platform="$(yaml_get "$manifest" "platform")"
        [[ -z "$plugin_platform" || "$plugin_platform" == "null" ]] && continue
        local already=false
        if [[ ${#unique_platforms[@]} -gt 0 ]]; then
            for p in "${unique_platforms[@]}"; do
                [[ "$p" == "$plugin_platform" ]] && { already=true; break; }
            done
        fi
        $already || unique_platforms+=("$plugin_platform")
    done < <(discover_plugins "$plugins_root" 2>/dev/null)

    # Read manual overrides from .zbuild/platforms.json if present
    local overrides_file="$repo_root/.zbuild/platforms.json"
    local override_platforms=()
    if [[ -f "$overrides_file" ]]; then
        while IFS= read -r p; do
            [[ -n "$p" ]] && override_platforms+=("$p")
        done < <(jq -r '.platforms[]? // empty' "$overrides_file" 2>/dev/null)
    fi

    # Detect which platforms have indicator files in repo
    local detected_platforms=()
    if [[ ${#unique_platforms[@]} -gt 0 ]]; then
        for platform in "${unique_platforms[@]}"; do
            if _platform_detected_in_repo "$platform" "$repo_root"; then
                detected_platforms+=("$platform")
            fi
        done
    fi

    # Apply overrides (add any not already detected)
    if [[ ${#override_platforms[@]} -gt 0 ]]; then
        for o in "${override_platforms[@]}"; do
            local already=false
            if [[ ${#detected_platforms[@]} -gt 0 ]]; then
                for p in "${detected_platforms[@]}"; do
                    [[ "$p" == "$o" ]] && { already=true; break; }
                done
            fi
            $already || detected_platforms+=("$o")
        done
    fi

    # Default floor: generic
    if [[ ${#detected_platforms[@]} -eq 0 ]]; then
        detected_platforms=("generic")
    fi

    # Build JSON platforms array
    local platforms_json_items=""
    for p in "${detected_platforms[@]}"; do
        platforms_json_items+="\"$p\","
    done
    platforms_json_items="${platforms_json_items%,}"

    jq -n \
        --arg sha "$current_sha" \
        --argjson platforms "[${platforms_json_items}]" \
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
