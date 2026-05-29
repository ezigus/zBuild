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

# ADR-015 v1 (#438): recognized io.destination tokens. Unknown tokens fail at
# template load time with an actionable error listing the valid set.
readonly _ZBUILD_IO_DESTINATIONS_VALID=(file stdout gh_comment)

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
    local -a collected_io_dests=()
    local -a collected_io_tail=()
    local -a collected_io_redact=()
    local -a collected_router_timeout=()
    local -a collected_router_max_turns=()
    while IFS='|' read -r stage_id roles strategy io_dests io_tail io_redact router_timeout router_max_turns; do
        [[ -z "$stage_id" ]] && continue
        collected_ids+=("$stage_id")
        collected_io_dests+=("$io_dests")
        collected_io_tail+=("$io_tail")
        collected_io_redact+=("$io_redact")
        collected_router_timeout+=("$router_timeout")
        collected_router_max_turns+=("$router_max_turns")
    done <<< "$stage_data"

    # Validate all stage ids against the canonical list before mutating state
    _tpl_validate_stages "${collected_ids[@]}" || return 1

    # ADR-015 v1 (#438): validate io.destinations tokens before mutating state
    _tpl_validate_io_dests collected_ids collected_io_dests || return 1

    # ADR-015 v3 (#440) + ADR-017 (#455) + ADR-018 (#466):
    # validate io.tail_lines, io.redact, router.timeout_s, router.max_turns
    _tpl_validate_io_knobs collected_ids collected_io_tail collected_io_redact \
        collected_router_timeout collected_router_max_turns || return 1

    # Populate module state
    while IFS='|' read -r stage_id roles strategy io_dests io_tail io_redact router_timeout router_max_turns; do
        [[ -z "$stage_id" ]] && continue
        _TPL_STAGES+=("$stage_id")
        # Store roles, strategy, io_dests via name-mangled env vars.
        # MUST be exported: plugins run in subshells spawned by the orch local
        # engine (`bash work-unit.sh`) and their capture_stage_io call needs to
        # read template_stage_io_dests, which reads these vars. Without export
        # the plugin sees them as empty and stage-io capture is silently
        # short-circuited as "no destinations configured".
        local safe_id="${stage_id//-/_}"
        printf -v "_TPL_STAGE_ROLES_${safe_id}" '%s' "$roles"
        printf -v "_TPL_STAGE_STRATEGY_${safe_id}" '%s' "$strategy"
        printf -v "_TPL_STAGE_IO_DESTS_${safe_id}" '%s' "$io_dests"
        printf -v "_TPL_STAGE_IO_TAIL_${safe_id}" '%s' "$io_tail"
        printf -v "_TPL_STAGE_IO_REDACT_${safe_id}" '%s' "$io_redact"
        printf -v "_TPL_STAGE_ROUTER_TIMEOUT_${safe_id}" '%s' "$router_timeout"
        printf -v "_TPL_STAGE_ROUTER_MAX_TURNS_${safe_id}" '%s' "$router_max_turns"
        export "_TPL_STAGE_ROLES_${safe_id}" \
               "_TPL_STAGE_STRATEGY_${safe_id}" \
               "_TPL_STAGE_IO_DESTS_${safe_id}" \
               "_TPL_STAGE_IO_TAIL_${safe_id}" \
               "_TPL_STAGE_IO_REDACT_${safe_id}" \
               "_TPL_STAGE_ROUTER_TIMEOUT_${safe_id}" \
               "_TPL_STAGE_ROUTER_MAX_TURNS_${safe_id}"
    done <<< "$stage_data"
}

# ADR-015 v3 (#440): validate tail_lines (integer 1..10000) and redact (true|false)
# ADR-017 (#455): also validate router.timeout_s (integer 1..3600)
# ADR-018 (#466): also validate router.max_turns (integer 1..200)
# Uses Bash 5+ namerefs for safer array-by-name passing (no eval indirection).
_tpl_validate_io_knobs() {
    local -n ids_ref="$1"
    local -n tails_ref="$2"
    local -n redacts_ref="$3"
    local -n rtimeouts_ref="$4"
    local -n rmaxturns_ref="$5"
    local i n=${#ids_ref[@]}
    for (( i=0; i<n; i++ )); do
        local stage="${ids_ref[$i]}"
        local tail="${tails_ref[$i]}"
        local redact="${redacts_ref[$i]}"
        local rt="${rtimeouts_ref[$i]}"
        local rmt="${rmaxturns_ref[$i]}"
        if [[ -n "$tail" ]]; then
            if ! [[ "$tail" =~ ^[0-9]+$ ]] || [[ "$tail" -lt 1 ]] || [[ "$tail" -gt 10000 ]]; then
                error "template: io.tail_lines for stage '$stage' must be integer in 1..10000, got: $tail"
                return 1
            fi
        fi
        if [[ -n "$redact" ]]; then
            if [[ "$redact" != "true" && "$redact" != "false" ]]; then
                error "template: io.redact for stage '$stage' must be 'true' or 'false', got: $redact"
                return 1
            fi
        fi
        if [[ -n "$rt" ]]; then
            if ! [[ "$rt" =~ ^[0-9]+$ ]] || [[ "$rt" -lt 1 ]] || [[ "$rt" -gt 3600 ]]; then
                error "template: router.timeout_s for stage '$stage' must be integer in 1..3600, got: $rt"
                return 1
            fi
        fi
        if [[ -n "$rmt" ]]; then
            if ! [[ "$rmt" =~ ^[0-9]+$ ]] || [[ "$rmt" -lt 1 ]] || [[ "$rmt" -gt 200 ]]; then
                error "template: router.max_turns for stage '$stage' must be integer in 1..200, got: $rmt"
                return 1
            fi
        fi
    done
    return 0
}

# _tpl_validate_io_dests <ids_arr_name> <dests_arr_name>
# Validates io.destinations tokens (v1 set: file, stdout, gh_comment).
# Bash 3.2 compat: pass array names; iterate via eval-style indirection.
_tpl_validate_io_dests() {
    local ids_var="$1" dests_var="$2"
    local valid_list="${_ZBUILD_IO_DESTINATIONS_VALID[*]}"
    # shellcheck disable=SC1087,SC2154
    # _n / _stage / _dests are assigned via the eval lines below; shellcheck
    # can't see through eval so it warns SC2154 ("referenced but not assigned").
    # Pre-declare them as locals so the disable comments don't need to repeat.
    local _n="" _stage="" _dests=""
    eval "_n=\${#${ids_var}[@]}"
    local i
    for (( i=0; i<_n; i++ )); do
        eval "_stage=\${${ids_var}[$i]}"
        eval "_dests=\${${dests_var}[$i]}"
        [[ -z "$_dests" ]] && continue
        local token
        local IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2086
        set -- $_dests
        IFS="$IFS_save"
        for token in "$@"; do
            [[ -z "$token" ]] && continue
            local found=0
            local v
            for v in "${_ZBUILD_IO_DESTINATIONS_VALID[@]}"; do
                [[ "$v" == "$token" ]] && { found=1; break; }
            done
            if [[ $found -eq 0 ]]; then
                error "template: unknown io.destination '$token' for stage '$_stage' (valid: $valid_list)"
                return 1
            fi
        done
    done
    return 0
}

_tpl_parse_stage_data() {
    local file="$1"
    awk '
    /^stages:/ { in_stages = 1; next }
    in_stages && /^[a-zA-Z_]/ { in_stages = 0; in_roles = 0; in_io_dests = 0; in_io_block = 0; in_router_block = 0; next }
    in_stages && /^[[:space:]]*-[[:space:]]*id:/ {
        if (current_id != "") { print current_id "|" current_roles "|" current_strategy "|" current_io_dests "|" current_io_tail "|" current_io_redact "|" current_router_timeout "|" current_router_max_turns }
        in_roles = 0; in_io_dests = 0; in_io_block = 0; in_router_block = 0
        current_id = $0
        gsub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", current_id)
        gsub(/[[:space:]]*$/, "", current_id)
        current_roles = ""; current_strategy = ""; current_io_dests = ""
        current_io_tail = ""; current_io_redact = ""; current_router_timeout = ""
        current_router_max_turns = ""
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
    in_stages && in_io_dests && /^[[:space:]]*-[[:space:]]/ {
        item = $0
        gsub(/^[[:space:]]*-[[:space:]]+/, "", item)
        gsub(/[[:space:]]*$/, "", item)
        if (item != "") {
            if (current_io_dests == "") current_io_dests = item
            else current_io_dests = current_io_dests "," item
        }
        next
    }
    in_stages && in_io_dests { in_io_dests = 0 }
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
        # Defensive: if io: or router: appeared before strategy: in this stage,
        # clear the block flags so subsequent list items are not mis-attributed.
        in_io_block = 0
        in_io_dests = 0
        in_router_block = 0
        current_strategy = $0
        gsub(/^[[:space:]]+strategy:[[:space:]]*/, "", current_strategy)
        gsub(/[[:space:]]*$/, "", current_strategy)
        next
    }
    in_stages && current_id != "" && /^[[:space:]]+io:[[:space:]]*$/ {
        in_io_block = 1
        in_router_block = 0
        next
    }
    in_stages && current_id != "" && /^[[:space:]]+router:[[:space:]]*$/ {
        in_io_block = 0
        in_io_dests = 0
        in_router_block = 1
        next
    }
    in_router_block && /^[[:space:]]+timeout_s:/ {
        rt = $0
        gsub(/^[[:space:]]+timeout_s:[[:space:]]*/, "", rt)
        gsub(/[[:space:]]*$/, "", rt)
        current_router_timeout = rt
        next
    }
    in_router_block && /^[[:space:]]+max_turns:/ {
        rmt = $0
        gsub(/^[[:space:]]+max_turns:[[:space:]]*/, "", rmt)
        gsub(/[[:space:]]*$/, "", rmt)
        current_router_max_turns = rmt
        next
    }
    # ADR-017 §8: ignore future router siblings silently (tier_default, budget_usd, model_override).
    in_router_block && /^[[:space:]]+[a-z_]+:/ { next }
    in_io_block && /^[[:space:]]+destinations:/ {
        dest_line = $0
        if (dest_line ~ /\[/) {
            sub(/^[^[]*\[/, "", dest_line)
            sub(/\].*$/, "", dest_line)
            gsub(/[[:space:]]/, "", dest_line)
            current_io_dests = dest_line
            in_io_dests = 0
        } else { in_io_dests = 1 }
        next
    }
    in_io_block && /^[[:space:]]+tail_lines:/ {
        tl = $0
        gsub(/^[[:space:]]+tail_lines:[[:space:]]*/, "", tl)
        gsub(/[[:space:]]*$/, "", tl)
        current_io_tail = tl
        in_io_dests = 0
        next
    }
    in_io_block && /^[[:space:]]+redact:/ {
        rd = $0
        gsub(/^[[:space:]]+redact:[[:space:]]*/, "", rd)
        gsub(/[[:space:]]*$/, "", rd)
        current_io_redact = rd
        in_io_dests = 0
        next
    }
    END {
        if (current_id != "") { print current_id "|" current_roles "|" current_strategy "|" current_io_dests "|" current_io_tail "|" current_io_redact "|" current_router_timeout "|" current_router_max_turns }
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

# ADR-015 v1 (#438): newline-delimited list of io.destinations for the stage
# (empty when stage has no io.destinations configured — caller treats empty as
# "capture disabled" and no-ops without I/O).
template_stage_io_dests() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_IO_DESTS_${safe_id}"
    local dests="${!var:-}"
    [[ -z "$dests" ]] && return 0
    tr ',' '\n' <<< "$dests"
}

# ADR-015 v3 (#440): per-stage io.tail_lines (empty when unset → caller default 40)
template_stage_io_tail_lines() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_IO_TAIL_${safe_id}"
    echo "${!var:-}"
}

# ADR-015 v3 (#440): per-stage io.redact (empty/true/false; empty = default true).
# LLM kind ignores "false" (always redacts).
template_stage_io_redact() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_IO_REDACT_${safe_id}"
    echo "${!var:-}"
}

# ADR-017 (#455): per-stage router.timeout_s (empty when unset → caller default 300).
# Consumer chokepoint: _route_resolve_timeout in core/router/route.sh applies
# the precedence rule (per-stage > env > compile-time default).
template_stage_router_timeout() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_ROUTER_TIMEOUT_${safe_id}"
    echo "${!var:-}"
}

# ADR-018 (#466): per-stage router.max_turns (empty when unset → caller default 25).
# Consumer chokepoint: _route_resolve_max_turns in core/router/route.sh applies
# the precedence rule (per-stage > env > compile-time default).
template_stage_router_max_turns() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_ROUTER_MAX_TURNS_${safe_id}"
    echo "${!var:-}"
}
