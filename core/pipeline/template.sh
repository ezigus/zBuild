#!/usr/bin/env bash
# core/pipeline/template.sh — Template loading and stage resolution (issue #208)
# ADR-009 (platform-aware modularity), ADR-013 (canonical stage sequence)
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_TEMPLATE_LOADED:-}" ]] && return 0
_ZBUILD_TEMPLATE_LOADED=1

_ZBUILD_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ZBUILD_TEMPLATE_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../plugin-registry/registry.sh
source "$_ZBUILD_ROOT/core/plugin-registry/registry.sh"

# ADR-013 canonical stage sequence — stability contract, not user-configurable.
# Exactly these 11 ids, in this order:
#   intake plan design build test review compound_quality pr deploy validate monitor
readonly _ZBUILD_CANONICAL_STAGES=(
    intake plan design build test review compound_quality pr deploy validate monitor
)

# Module-level state — populated by load_template
_TPL_DEFAULT_STRATEGY="fanout"
_TPL_STAGES=()

# _tpl_validate_stages <stage_ids...>
# Validates that every stage id is in the canonical list and that the ids
# appear in the same relative order as the canonical sequence.
# Prints a structured error and returns 1 on the first violation.
_tpl_validate_stages() {
    local -a ids=("$@")
    [[ ${#ids[@]} -eq 0 ]] && return 0

    # Build a lookup: canonical stage → its ordinal position
    local -a canonical=("${_ZBUILD_CANONICAL_STAGES[@]}")
    local canonical_list="${canonical[*]}"

    local prev_pos=-1
    local stage_id
    for stage_id in "${ids[@]}"; do
        # Check membership
        local pos=-1
        local i
        for i in "${!canonical[@]}"; do
            if [[ "${canonical[$i]}" == "$stage_id" ]]; then
                pos=$i
                break
            fi
        done

        if [[ $pos -eq -1 ]]; then
            error "load_template: unknown stage id '${stage_id}' (valid: ${canonical_list})"
            return 1
        fi

        # Check order preservation
        if [[ $pos -le $prev_pos ]]; then
            error "load_template: stage '${stage_id}' violates canonical order (valid order: ${canonical_list})"
            return 1
        fi

        prev_pos=$pos
    done

    return 0
}

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

    # Collect stage ids first for validation
    local -a collected_ids=()
    while IFS='|' read -r stage_id roles strategy; do
        [[ -z "$stage_id" ]] && continue
        collected_ids+=("$stage_id")
    done <<< "$stage_data"

    # Validate all stage ids against the canonical list before mutating state
    _tpl_validate_stages "${collected_ids[@]}" || return 1

    # Populate module state
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
    in_stages && /^[a-zA-Z_]/ { in_stages = 0; in_roles = 0; next }
    in_stages && /^[[:space:]]*-[[:space:]]*id:/ {
        if (current_id != "") { print current_id "|" current_roles "|" current_strategy }
        in_roles = 0
        current_id = $0
        gsub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", current_id)
        gsub(/[[:space:]]*$/, "", current_id)
        current_roles = ""; current_strategy = ""
        next
    }
    in_stages && in_roles && /^[[:space:]]*-[[:space:]]/ {
        item = $0
        gsub(/^[[:space:]]*-[[:space:]]+/, "", item)
        gsub(/[[:space:]]*$/, "", item)
        if (item != "") {
            if (current_roles == "") current_roles = item
            else current_roles = current_roles "," item
        }
        next
    }
    in_stages && in_roles { in_roles = 0 }
    in_stages && current_id != "" && /roles:/ {
        roles_line = $0
        if (roles_line ~ /\[/) {
            sub(/^[^[]*\[/, "", roles_line)
            sub(/\].*$/, "", roles_line)
            gsub(/[[:space:]]/, "", roles_line)
            current_roles = roles_line
        } else { in_roles = 1 }
        next
    }
    in_stages && current_id != "" && /^[[:space:]]+strategy:/ {
        current_strategy = $0
        gsub(/^[[:space:]]+strategy:[[:space:]]*/, "", current_strategy)
        gsub(/[[:space:]]*$/, "", current_strategy)
    }
    END {
        if (current_id != "") { print current_id "|" current_roles "|" current_strategy }
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
