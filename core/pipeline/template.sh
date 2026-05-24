#!/usr/bin/env bash
# core/pipeline/template.sh — Template loading and stage resolution (issue #208)
# ADR-009 (platform-aware modularity)

[[ -n "${_ZBUILD_TEMPLATE_LOADED:-}" ]] && return 0
_ZBUILD_TEMPLATE_LOADED=1

_ZBUILD_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ZBUILD_TEMPLATE_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../plugin-registry/registry.sh
source "$_ZBUILD_ROOT/core/plugin-registry/registry.sh"

# Module-level state — populated by load_template
_TPL_DEFAULT_STRATEGY="fanout"
_TPL_STAGES=()

load_template() {
    local template_file="$1"
    if [[ ! -f "$template_file" ]]; then
        error "load_template: file not found: $template_file"
        return 1
    fi

    _TPL_DEFAULT_STRATEGY="$(yaml_get "$template_file" "defaults.strategy")"
    [[ -z "$_TPL_DEFAULT_STRATEGY" ]] && _TPL_DEFAULT_STRATEGY="fanout"

    _TPL_STAGES=()

    local stage_data
    stage_data="$(_tpl_parse_stage_data "$template_file")"
    while IFS='|' read -r stage_id roles strategy; do
        [[ -z "$stage_id" ]] && continue
        _TPL_STAGES+=("$stage_id")
        # Store roles and strategy via name-mangled env vars (bash 3.2 compat)
        local safe_id="${stage_id//-/_}"
        printf -v "_TPL_STAGE_ROLES_${safe_id}" '%s' "$roles"
        printf -v "_TPL_STAGE_STRATEGY_${safe_id}" '%s' "$strategy"
    done <<< "$stage_data"
}

_tpl_parse_stage_data() {
    local file="$1"
    awk '
    /^stages:/ { in_stages = 1; next }
    in_stages && /^[a-zA-Z_]/ { in_stages = 0 }
    in_stages && /^[[:space:]]*-[[:space:]]*id:/ {
        if (current_id != "") {
            print current_id "|" current_roles "|" current_strategy
        }
        current_id = $0
        gsub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", current_id)
        gsub(/[[:space:]]*$/, "", current_id)
        current_roles = ""
        current_strategy = ""
    }
    in_stages && current_id != "" && /roles:/ {
        roles_line = $0
        if (roles_line ~ /\[/) {
            sub(/^[^[]*\[/, "", roles_line)
            sub(/\].*$/, "", roles_line)
            gsub(/[[:space:]]/, "", roles_line)
            current_roles = roles_line
        }
    }
    in_stages && current_id != "" && /^[[:space:]]+strategy:/ {
        current_strategy = $0
        gsub(/^[[:space:]]+strategy:[[:space:]]*/, "", current_strategy)
        gsub(/[[:space:]]*$/, "", current_strategy)
    }
    END {
        if (current_id != "") {
            print current_id "|" current_roles "|" current_strategy
        }
    }
    ' "$file"
}

template_stage_roles() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_ROLES_${safe_id}"
    local roles="${!var:-}"
    [[ -z "$roles" ]] && return 0
    tr ',' '\n' <<< "$roles"
}

template_stage_strategy() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_STRATEGY_${safe_id}"
    local stage_strat="${!var:-}"
    if [[ -n "$stage_strat" ]]; then
        echo "$stage_strat"
    else
        echo "${_TPL_DEFAULT_STRATEGY:-fanout}"
    fi
}
