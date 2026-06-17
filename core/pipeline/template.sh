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
# ADR-027 (Wave 17-B #703): template.deprecated_shape event on old-shape load.
# Defensive source — event-bus is a no-op when ZBUILD_EVENTS_JSONL is unset.
if ! declare -F eb_emit_event >/dev/null 2>&1; then
    # shellcheck source=../event-bus/event-bus.sh
    source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
fi

# ADR-013 canonical stage sequence — stability contract, not user-configurable.
# Issue #842: swapped impact after design (design_impact_cycle; ADR-013 amendment).
# Issue #755: compound_quality split into cq-preflight cq-audit-plan cq-cycle cq-backtrack.
# Issue #922: acceptance-gate inserted after test_assessment (ADR-036 / ADR-013 amendment).
# Exactly these 17 ids, in this order:
#   intake plan design impact build test test_assessment acceptance-gate cq-preflight cq-audit-plan cq-cycle cq-backtrack review pr deploy validate monitor
readonly _ZBUILD_CANONICAL_STAGES=(
    intake plan design impact build test test_assessment acceptance-gate cq-preflight cq-audit-plan cq-cycle cq-backtrack review pr deploy validate monitor
)

# Module-level state — populated by load_template
_TPL_DEFAULT_STRATEGY="fanout"
_TPL_STAGES=()
# ADR-021 (#512): list of dispatch units in template order. Each entry is
# "stage:<id>" or "cycle:<id>". Empty `cycles:` block → every unit is "stage:<id>"
# (backwards-compat — runner behavior identical to today).
_TPL_DISPATCH_UNITS=()
# ADR-021: list of cycle ids declared in template (in declaration order).
_TPL_CYCLES=()

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

    # ADR-021 v2 (#585): legacy top-level `cycles:` block is a hard-break.
    # Detect and refuse with a pointer to the migration helper.
    if awk 'BEGIN{rc=1} /^cycles:[[:space:]]*$/ {rc=0; exit} END{exit rc}' "$template_file"; then
        error "load_template: legacy 'cycles:' block detected in $template_file"
        error "  v2 template syntax inlines cycles as stage entries (type: cycle)"
        error "  with per-stage attributes hoisted into a top-level"
        error "  'stage_definitions:' map (see ADR-021 v2 / issue #585)."
        error "  Run: scripts/migrate-template-v2.sh '$template_file' --in-place"
        return 1
    fi

    _TPL_DEFAULT_STRATEGY="$(yaml_get "$template_file" "defaults.strategy")"
    [[ -z "$_TPL_DEFAULT_STRATEGY" ]] && _TPL_DEFAULT_STRATEGY="fanout"

    _TPL_STAGES=()
    _TPL_CYCLES=()

    # ADR-027 (Wave 17-B #703): shape detector. The new shape uses `flow:` at
    # top level + per-stage top-level sections discriminated by `type:`. The
    # old shape (Wave 15-D era) uses `stages:` + `stage_definitions:`. Detect
    # which we're loading; old shape routes through the legacy parsers
    # unchanged AND fires `template.deprecated_shape` so operators can find
    # stragglers before the shim removal (one release window).
    local _tpl_shape="old"
    if _tpl_is_new_shape "$template_file"; then
        _tpl_shape="new"
    else
        # Emit the deprecation event with run_id cleared so it does not enter
        # any C6-style "last-event-for-this-run" precondition chain (template
        # load is a process-level concern, not a pipeline-run event). The
        # event still appears in events.jsonl for ops-dashboard visibility.
        (
            unset ZBUILD_RUN_ID
            eb_emit_event "template.deprecated_shape" \
                "template_file=$template_file" "shape=pre_adr_027" \
                2>/dev/null || true
        )
    fi

    # ADR-021 v2 parser: scan `stages:` block, emitting interleaved S|/IC|/FB|
    # rows. Inline cycle entries (IC|) reference cycle member stages by id;
    # per-stage attrs for those members come from `stage_definitions:` (parsed
    # separately below).
    # ADR-027 (Wave 17-B): new-shape templates are translated by
    # _tpl_translate_new_shape into the same pipe-delimited row format the
    # legacy pipeline downstream code already consumes — single internal
    # representation; the shim is purely upstream.
    local stage_rows defs_rows
    if [[ "$_tpl_shape" == "new" ]]; then
        local _translated; _translated="$(_tpl_translate_new_shape "$template_file")" || return 1
        stage_rows="${_translated%%$'\037'*}"
        defs_rows="${_translated#*$'\037'}"
    else
        stage_rows="$(_tpl_parse_stages_v2 "$template_file")"
        defs_rows="$(_tpl_parse_stage_definitions "$template_file")"
    fi

    # Build map: stage id → "S|<id>|<roles>|<strategy>|<io...>|<router...>"
    # First load defs into the map; then non-cycle stage rows from `stages:`
    # also feed the map (regular stages declare their own attrs inline).
    local -A stage_def_row=()
    local row sid rest
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        sid="${row%%|*}"
        rest="${row#*|}"
        stage_def_row["$sid"]="$rest"
    done <<< "$defs_rows"

    # Phase 1: collect ids in execution order + extract cycle metadata.
    local -a collected_ids=()
    local -a collected_io_dests=()
    local -a collected_io_tail=()
    local -a collected_io_redact=()
    local -a collected_router_timeout=()
    local -a collected_router_max_turns=()
    local -a collected_router_max_iterations=()
    local -a stage_data_rows=()

    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        local tag="${row%%|*}"
        local payload="${row#*|}"
        case "$tag" in
            S)
                # Inline regular stage row from `stages:` — full attr payload.
                # Format: <id>|<roles>|<strategy>|<io_dests>|<io_tail>|<io_redact>|<rt>|<rmt>|<rmi>
                local s_id s_roles s_strat s_iod s_iot s_ior s_rt s_rmt s_rmi
                IFS='|' read -r s_id s_roles s_strat s_iod s_iot s_ior s_rt s_rmt s_rmi <<< "$payload"
                [[ -z "$s_id" ]] && continue
                # Also drop into defs map so cycle members can declare attrs
                # inline if templates choose to (forward-compat).
                stage_def_row["$s_id"]="$s_roles|$s_strat|$s_iod|$s_iot|$s_ior|$s_rt|$s_rmt|$s_rmi"
                collected_ids+=("$s_id")
                collected_io_dests+=("$s_iod")
                collected_io_tail+=("$s_iot")
                collected_io_redact+=("$s_ior")
                collected_router_timeout+=("$s_rt")
                collected_router_max_turns+=("$s_rmt")
                collected_router_max_iterations+=("$s_rmi")
                stage_data_rows+=("$s_id|$s_roles|$s_strat|$s_iod|$s_iot|$s_ior|$s_rt|$s_rmt|$s_rmi")
                ;;
            IC)
                # Inline cycle entry. Format:
                # <cid>|<cstages>|<cmax>|<conmax>|<custage>|<cufield>|<cuop>|<cuvalue>|<cplateau>|<cdiverg>|<cvelopl>|<cdesc>
                # #831: cdesc is the optional operator-facing description.
                # #840: cexpand/cautogrant/cescalate/condeny carry scope_policy
                # (ADR-030); auto_grant is csv (comma never conflicts with the
                # pipe field separator). Absent block ⇒ safe defaults below.
                local cid cstages cmax conmax custage cufield cuop cuvalue cplateau cdiverg cvelopl cdesc
                local cexpand cautogrant cescalate condeny
                IFS='|' read -r cid cstages cmax conmax custage cufield cuop cuvalue cplateau cdiverg cvelopl cdesc cexpand cautogrant cescalate condeny <<< "$payload"
                [[ -z "$cid" ]] && continue
                _TPL_CYCLES+=("$cid")
                local safe="${cid//-/_}"
                printf -v "_TPL_CYCLE_STAGES_${safe}"        '%s' "$cstages"
                printf -v "_TPL_CYCLE_MAX_${safe}"           '%s' "$cmax"
                printf -v "_TPL_CYCLE_ON_MAX_${safe}"        '%s' "${conmax:-continue}"
                printf -v "_TPL_CYCLE_UNTIL_STAGE_${safe}"   '%s' "$custage"
                printf -v "_TPL_CYCLE_UNTIL_FIELD_${safe}"   '%s' "$cufield"
                printf -v "_TPL_CYCLE_UNTIL_OP_${safe}"      '%s' "$cuop"
                printf -v "_TPL_CYCLE_UNTIL_VALUE_${safe}"   '%s' "$cuvalue"
                printf -v "_TPL_CYCLE_PLATEAU_W_${safe}"            '%s' "$cplateau"
                printf -v "_TPL_CYCLE_DIVERGENCE_W_${safe}"         '%s' "$cdiverg"
                printf -v "_TPL_CYCLE_VELOCITY_PLATEAU_W_${safe}"   '%s' "$cvelopl"
                printf -v "_TPL_CYCLE_DESCRIPTION_${safe}"          '%s' "${cdesc:-}"
                # #840 scope_policy with ADR-030 safe defaults (omitted block ⇒
                # not expandable ⇒ governed-deny ⇒ clean abandon).
                printf -v "_TPL_CYCLE_SCOPE_EXPANDABLE_${safe}" '%s' "${cexpand:-false}"
                printf -v "_TPL_CYCLE_SCOPE_AUTO_GRANT_${safe}" '%s' "${cautogrant:-}"
                printf -v "_TPL_CYCLE_SCOPE_ESCALATE_${safe}"   '%s' "${cescalate:-none}"
                printf -v "_TPL_CYCLE_SCOPE_ON_DENY_${safe}"    '%s' "${condeny:-abandon}"
                export "_TPL_CYCLE_STAGES_${safe}" "_TPL_CYCLE_MAX_${safe}" \
                       "_TPL_CYCLE_ON_MAX_${safe}" "_TPL_CYCLE_UNTIL_STAGE_${safe}" \
                       "_TPL_CYCLE_UNTIL_FIELD_${safe}" "_TPL_CYCLE_UNTIL_OP_${safe}" \
                       "_TPL_CYCLE_UNTIL_VALUE_${safe}" "_TPL_CYCLE_PLATEAU_W_${safe}" \
                       "_TPL_CYCLE_DIVERGENCE_W_${safe}" "_TPL_CYCLE_VELOCITY_PLATEAU_W_${safe}" \
                       "_TPL_CYCLE_DESCRIPTION_${safe}" \
                       "_TPL_CYCLE_SCOPE_EXPANDABLE_${safe}" "_TPL_CYCLE_SCOPE_AUTO_GRANT_${safe}" \
                       "_TPL_CYCLE_SCOPE_ESCALATE_${safe}" "_TPL_CYCLE_SCOPE_ON_DENY_${safe}"
                # Expand cycle members in order into the flat stage list.
                local IFS_save="$IFS"; IFS=','
                # shellcheck disable=SC2206
                local -a members=($cstages)
                IFS="$IFS_save"
                local m m_row m_roles m_strat m_iod m_iot m_ior m_rt m_rmt m_rmi
                # Dedupe set: stage ids already added to _TPL_STAGES via a
                # prior IC| row in the same template (nested-cycle case).
                # Without this a parent cycle re-adds its descendant cycle's
                # members and breaks the canonical-order validator.
                for m in "${members[@]}"; do
                    # ADR-027 (Wave 17-B): cycle-as-member. If `m` is itself
                    # a known cycle (registered by an earlier IC| row from
                    # the translator topo pre-pass), recursively expand its
                    # member list into the flat _TPL_STAGES[] view rather
                    # than treating `m` as a leaf stage id (cycle ids are
                    # not canonical and would fail validation).
                    local _m_is_cycle=0 _cyc
                    for _cyc in "${_TPL_CYCLES[@]}"; do
                        [[ "$_cyc" == "$m" ]] && _m_is_cycle=1 && break
                    done
                    if [[ $_m_is_cycle -eq 1 ]]; then
                        local _inner_safe="${m//-/_}"
                        local _inner_stages_var="_TPL_CYCLE_STAGES_${_inner_safe}"
                        local _inner_csv="${!_inner_stages_var:-}"
                        local IFS_save2="$IFS"; IFS=','
                        # shellcheck disable=SC2206
                        local -a _inner_members=($_inner_csv)
                        IFS="$IFS_save2"
                        local _im
                        for _im in "${_inner_members[@]}"; do
                            # Dedupe — already added via descendant IC|.
                            local _already=0 _ex
                            for _ex in "${collected_ids[@]}"; do
                                [[ "$_ex" == "$_im" ]] && _already=1 && break
                            done
                            [[ $_already -eq 1 ]] && continue
                            m_row="${stage_def_row[$_im]:-}"
                            if [[ -z "$m_row" ]]; then
                                error "load_template: nested cycle '$m' references stage '$_im' but no top-level section exists"
                                return 1
                            fi
                            IFS='|' read -r m_roles m_strat m_iod m_iot m_ior m_rt m_rmt m_rmi <<< "$m_row"
                            collected_ids+=("$_im")
                            collected_io_dests+=("$m_iod")
                            collected_io_tail+=("$m_iot")
                            collected_io_redact+=("$m_ior")
                            collected_router_timeout+=("$m_rt")
                            collected_router_max_turns+=("$m_rmt")
                            collected_router_max_iterations+=("$m_rmi")
                            stage_data_rows+=("$_im|$m_roles|$m_strat|$m_iod|$m_iot|$m_ior|$m_rt|$m_rmt|$m_rmi")
                        done
                        continue
                    fi
                    # Dedupe leaf member too (in case a descendant cycle
                    # already added this id).
                    local _already=0 _ex
                    for _ex in "${collected_ids[@]}"; do
                        [[ "$_ex" == "$m" ]] && _already=1 && break
                    done
                    if [[ $_already -eq 1 ]]; then
                        continue
                    fi
                    m_row="${stage_def_row[$m]:-}"
                    if [[ -z "$m_row" ]]; then
                        error "load_template: cycle '$cid' references stage '$m' but no 'stage_definitions.$m' entry exists"
                        return 1
                    fi
                    IFS='|' read -r m_roles m_strat m_iod m_iot m_ior m_rt m_rmt m_rmi <<< "$m_row"
                    collected_ids+=("$m")
                    collected_io_dests+=("$m_iod")
                    collected_io_tail+=("$m_iot")
                    collected_io_redact+=("$m_ior")
                    collected_router_timeout+=("$m_rt")
                    collected_router_max_turns+=("$m_rmt")
                    collected_router_max_iterations+=("$m_rmi")
                    stage_data_rows+=("$m|$m_roles|$m_strat|$m_iod|$m_iot|$m_ior|$m_rt|$m_rmt|$m_rmi")
                done
                ;;
            AW)
                # ADR-027 (Wave 17-B): abort_when predicate for a cycle.
                # Format: <cid>|<stage>|<field>|<op>|<value>
                local aw_cid aw_stage aw_field aw_op aw_value
                IFS='|' read -r aw_cid aw_stage aw_field aw_op aw_value <<< "$payload"
                local aw_safe="${aw_cid//-/_}"
                printf -v "_TPL_CYCLE_ABORT_WHEN_STAGE_${aw_safe}" '%s' "$aw_stage"
                printf -v "_TPL_CYCLE_ABORT_WHEN_FIELD_${aw_safe}" '%s' "$aw_field"
                printf -v "_TPL_CYCLE_ABORT_WHEN_OP_${aw_safe}"    '%s' "$aw_op"
                printf -v "_TPL_CYCLE_ABORT_WHEN_VALUE_${aw_safe}" '%s' "$aw_value"
                export "_TPL_CYCLE_ABORT_WHEN_STAGE_${aw_safe}" \
                       "_TPL_CYCLE_ABORT_WHEN_FIELD_${aw_safe}" \
                       "_TPL_CYCLE_ABORT_WHEN_OP_${aw_safe}" \
                       "_TPL_CYCLE_ABORT_WHEN_VALUE_${aw_safe}"
                ;;
            FB)
                # Feedback row for the most-recent cycle. Format:
                # <cid>|<fbrec>  (fbrec = from_stage:from_output|to_stage:to_field:required)
                local fb_cid fb_rec
                fb_cid="${payload%%|*}"
                fb_rec="${payload#*|}"
                local safe="${fb_cid//-/_}"
                local var="_TPL_CYCLE_FEEDBACK_${safe}"
                local prev="${!var:-}"
                if [[ -z "$prev" ]]; then
                    printf -v "$var" '%s' "$fb_rec"
                else
                    printf -v "$var" '%s\n%s' "$prev" "$fb_rec"
                fi
                # shellcheck disable=SC2163
                export "${var?}"
                ;;
        esac
    done <<< "$stage_rows"

    # Validate ids/order/io/router before mutating per-stage state.
    _tpl_validate_stages "${collected_ids[@]}" || return 1
    _tpl_validate_io_dests collected_ids collected_io_dests || return 1
    _tpl_validate_io_knobs collected_ids collected_io_tail collected_io_redact \
        collected_router_timeout collected_router_max_turns \
        collected_router_max_iterations || return 1

    # Populate per-stage state (flat _TPL_STAGES[] + per-id env vars).
    local stage_id roles strategy io_dests io_tail io_redact router_timeout router_max_turns router_max_iterations
    for row in "${stage_data_rows[@]}"; do
        IFS='|' read -r stage_id roles strategy io_dests io_tail io_redact router_timeout router_max_turns router_max_iterations <<< "$row"
        [[ -z "$stage_id" ]] && continue
        _TPL_STAGES+=("$stage_id")
        local safe_id="${stage_id//-/_}"
        printf -v "_TPL_STAGE_ROLES_${safe_id}" '%s' "$roles"
        printf -v "_TPL_STAGE_STRATEGY_${safe_id}" '%s' "$strategy"
        printf -v "_TPL_STAGE_IO_DESTS_${safe_id}" '%s' "$io_dests"
        printf -v "_TPL_STAGE_IO_TAIL_${safe_id}" '%s' "$io_tail"
        printf -v "_TPL_STAGE_IO_REDACT_${safe_id}" '%s' "$io_redact"
        printf -v "_TPL_STAGE_ROUTER_TIMEOUT_${safe_id}" '%s' "$router_timeout"
        printf -v "_TPL_STAGE_ROUTER_MAX_TURNS_${safe_id}" '%s' "$router_max_turns"
        printf -v "_TPL_STAGE_ROUTER_MAX_ITERATIONS_${safe_id}" '%s' "$router_max_iterations"
        export "_TPL_STAGE_ROLES_${safe_id}" \
               "_TPL_STAGE_STRATEGY_${safe_id}" \
               "_TPL_STAGE_IO_DESTS_${safe_id}" \
               "_TPL_STAGE_IO_TAIL_${safe_id}" \
               "_TPL_STAGE_IO_REDACT_${safe_id}" \
               "_TPL_STAGE_ROUTER_TIMEOUT_${safe_id}" \
               "_TPL_STAGE_ROUTER_MAX_TURNS_${safe_id}" \
               "_TPL_STAGE_ROUTER_MAX_ITERATIONS_${safe_id}"
    done

    _tpl_validate_cycles || return 1
    _tpl_build_dispatch_units || return 1

    # ADR-027 (Wave 17-B #703): stage-type discriminator. Every stage in
    # _TPL_STAGES[] is `leaf` by default; cycle ids get `cycle`. The
    # orchestrator reads `_TPL_STAGE_TYPE_<id>` at dispatch time to decide
    # whether to recurse (cycle-as-member) or invoke the leaf path.
    local _st_id _st_safe
    for _st_id in "${_TPL_STAGES[@]}"; do
        _st_safe="${_st_id//-/_}"
        # Default: leaf. Cycle ids are overwritten below.
        printf -v "_TPL_STAGE_TYPE_${_st_safe}" '%s' "leaf"
        export "_TPL_STAGE_TYPE_${_st_safe}"
    done
    for _st_id in "${_TPL_CYCLES[@]}"; do
        _st_safe="${_st_id//-/_}"
        printf -v "_TPL_STAGE_TYPE_${_st_safe}" '%s' "cycle"
        export "_TPL_STAGE_TYPE_${_st_safe}"
        # ADR-027 lexicon parity: _TPL_CYCLE_FLOW_<id> aliases the existing
        # _TPL_CYCLE_STAGES_<id> so callers using ADR-027 names work.
        local _cf_src="_TPL_CYCLE_STAGES_${_st_safe}"
        printf -v "_TPL_CYCLE_FLOW_${_st_safe}" '%s' "${!_cf_src:-}"
        export "_TPL_CYCLE_FLOW_${_st_safe}"
    done

    # ADR-027 contract validator (Wave 17-B #703): reference-graph acyclicity.
    # If any cycle's flow transitively includes itself, refuse to load.
    _tpl_validate_flow_acyclic || return 1
}

# ─── _tpl_parse_stages_v2 — parse `stages:` block with inline cycle support ──
# ADR-021 v2 (#585). Single AWK pass over `stages:` emits interleaved rows:
#   S|<id>|<roles>|<strategy>|<io_dests>|<io_tail>|<io_redact>|<rt>|<rmt>|<rmi>
#     for regular `- id:` stage entries (full attr payload, same shape as the
#     legacy _tpl_parse_stage_data output)
#   IC|<cid>|<cstages_csv>|<cmax>|<conmax>|<custage>|<cufield>|<cuop>|<cuvalue>|<cplateau>|<cdiverg>|<cvelopl>|<cdesc>
#     for `- id: …; type: cycle` entries. <cdesc> is the optional operator-
#     facing description (#831); empty when the YAML omits `description:`.
#   FB|<cid>|<from_stage>:<from_output>|<to_stage>:<to_input>:<required>
#     one row per feedback record in the most-recently opened cycle
# Caller distinguishes by leading tag; preserves declaration order.
_tpl_parse_stages_v2() {
    local file="$1"
    awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function strip_inline_list(line,    s) {
        s = line
        sub(/^[^[]*\[/, "", s)
        sub(/\].*$/, "", s)
        gsub(/[[:space:]]/, "", s)
        return s
    }
    function flush_entry(   k) {
        if (current_id == "") return
        if (entry_kind == "cycle") {
            print "IC|" current_id "|" cstages "|" cmax "|" conmax "|" custage "|" cufield "|" cuop "|" cuvalue "|" cplateau "|" cdiverg "|" cvelopl "|" cdesc "|" cexpand "|" cautogrant "|" cescalate "|" condeny
            if (fb_from_stage != "" || fb_to_stage != "") {
                nfb++
                fb[nfb] = fb_from_stage ":" fb_from_output "|" fb_to_stage ":" fb_to_field ":" fb_required
            }
            for (k = 1; k <= nfb; k++) print "FB|" current_id "|" fb[k]
        } else {
            print "S|" current_id "|" current_roles "|" current_strategy "|" current_io_dests "|" current_io_tail "|" current_io_redact "|" current_router_timeout "|" current_router_max_turns "|" current_router_max_iterations
        }
    }
    function reset_entry() {
        current_id = ""; entry_kind = "stage"
        current_roles = ""; current_strategy = ""; current_io_dests = ""
        current_io_tail = ""; current_io_redact = ""; current_router_timeout = ""
        current_router_max_turns = ""; current_router_max_iterations = ""
        cstages = ""; cmax = ""; conmax = ""; custage = ""; cufield = ""
        cuop = ""; cuvalue = ""; cplateau = ""; cdiverg = ""; cvelopl = ""; cdesc = ""
        cexpand = ""; cautogrant = ""; cescalate = ""; condeny = ""
        nfb = 0
        in_roles = 0; in_io_dests = 0; in_io_block = 0; in_router_block = 0
        in_stages_list = 0; in_until = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0
        in_feedback = 0; in_fb_item = 0; in_scope_policy = 0
        fb_from_stage = ""; fb_from_output = ""; fb_to_stage = ""; fb_to_field = ""; fb_required = "false"
    }
    BEGIN { reset_entry() }
    /^stages:[[:space:]]*$/ { in_stages = 1; next }
    in_stages && /^[a-zA-Z_]/ {
        flush_entry()
        reset_entry()
        in_stages = 0
        next
    }
    in_stages && /^[[:space:]]*-[[:space:]]*id:/ {
        flush_entry()
        reset_entry()
        sid = $0
        sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", sid)
        current_id = trim(sid)
        next
    }
    in_stages && current_id != "" && /^[[:space:]]+type:[[:space:]]*cycle[[:space:]]*$/ {
        entry_kind = "cycle"
        next
    }

    # ── cycle-only fields ────────────────────────────────────────────────────
    in_stages && entry_kind == "cycle" && /^[[:space:]]+stages:/ {
        in_until = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0
        if ($0 ~ /\[/) {
            cstages = strip_inline_list($0)
            in_stages_list = 0
        } else {
            in_stages_list = 1
        }
        next
    }
    in_stages && entry_kind == "cycle" && in_stages_list && /^[[:space:]]+-[[:space:]]/ {
        item = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", item); item = trim(item)
        if (item != "") cstages = (cstages == "" ? item : cstages "," item)
        next
    }
    in_stages && entry_kind == "cycle" && in_stages_list && /^[[:space:]]+[a-z_]+:/ { in_stages_list = 0 }
    in_stages && entry_kind == "cycle" && /^[[:space:]]+max_iterations:/ {
        v = $0; sub(/^[[:space:]]+max_iterations:[[:space:]]*/, "", v); cmax = trim(v); next
    }
    in_stages && entry_kind == "cycle" && /^[[:space:]]+on_max:/ {
        v = $0; sub(/^[[:space:]]+on_max:[[:space:]]*/, "", v); conmax = trim(v); next
    }
    # #831: optional operator-facing description. Renderer-only; never used in
    # control flow. Strip a single layer of surrounding "..." or '...' quotes.
    in_stages && entry_kind == "cycle" && /^[[:space:]]+description:[[:space:]]*/ {
        v = $0; sub(/^[[:space:]]+description:[[:space:]]*/, "", v); v = trim(v)
        gsub(/^"|"$/, "", v); gsub(/^'\''|'\''$/, "", v)
        cdesc = v; next
    }
    # #840 scope_policy (ADR-030): nested block, children guarded by
    # in_scope_policy. auto_grant inline list [a, b] → csv a,b.
    in_stages && entry_kind == "cycle" && /^[[:space:]]+scope_policy:[[:space:]]*$/ {
        in_scope_policy = 1; in_until = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; next
    }
    in_stages && entry_kind == "cycle" && in_scope_policy && /^[[:space:]]+expandable:/ {
        v = $0; sub(/^[[:space:]]+expandable:[[:space:]]*/, "", v); cexpand = trim(v); next
    }
    in_stages && entry_kind == "cycle" && in_scope_policy && /^[[:space:]]+auto_grant:/ {
        v = $0; sub(/^[[:space:]]+auto_grant:[[:space:]]*/, "", v); v = trim(v)
        gsub(/^\[|\]$/, "", v); gsub(/[[:space:]]/, "", v)
        cautogrant = v; next
    }
    in_stages && entry_kind == "cycle" && in_scope_policy && /^[[:space:]]+escalate:/ {
        v = $0; sub(/^[[:space:]]+escalate:[[:space:]]*/, "", v); cescalate = trim(v); next
    }
    in_stages && entry_kind == "cycle" && in_scope_policy && /^[[:space:]]+on_deny:/ {
        v = $0; sub(/^[[:space:]]+on_deny:[[:space:]]*/, "", v); condeny = trim(v); next
    }
    in_stages && entry_kind == "cycle" && /^[[:space:]]+until:[[:space:]]*$/ {
        in_until = 1; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; next
    }
    in_stages && entry_kind == "cycle" && in_until && /^[[:space:]]+stage:/ {
        v = $0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v); custage = trim(v); next
    }
    in_stages && entry_kind == "cycle" && in_until && /^[[:space:]]+field:/ {
        v = $0; sub(/^[[:space:]]+field:[[:space:]]*/, "", v); cufield = trim(v); next
    }
    in_stages && entry_kind == "cycle" && in_until && /^[[:space:]]+op:/ {
        v = $0; sub(/^[[:space:]]+op:[[:space:]]*/, "", v); cuop = trim(v); next
    }
    in_stages && entry_kind == "cycle" && in_until && /^[[:space:]]+value:/ {
        v = $0; sub(/^[[:space:]]+value:[[:space:]]*/, "", v); cuvalue = trim(v); next
    }
    in_stages && entry_kind == "cycle" && /^[[:space:]]+plateau:[[:space:]]*$/ { in_plateau = 1; in_until = 0; in_diverg = 0; in_velopl = 0; in_scope_policy = 0; next }
    in_stages && entry_kind == "cycle" && in_plateau && /^[[:space:]]+window:/ {
        v = $0; sub(/^[[:space:]]+window:[[:space:]]*/, "", v); cplateau = trim(v); next
    }
    in_stages && entry_kind == "cycle" && /^[[:space:]]+divergence:[[:space:]]*$/ { in_diverg = 1; in_until = 0; in_plateau = 0; in_velopl = 0; in_scope_policy = 0; next }
    in_stages && entry_kind == "cycle" && in_diverg && /^[[:space:]]+window:/ {
        v = $0; sub(/^[[:space:]]+window:[[:space:]]*/, "", v); cdiverg = trim(v); next
    }
    in_stages && entry_kind == "cycle" && /^[[:space:]]+velocity_plateau:[[:space:]]*$/ { in_velopl = 1; in_until = 0; in_plateau = 0; in_diverg = 0; in_scope_policy = 0; next }
    in_stages && entry_kind == "cycle" && in_velopl && /^[[:space:]]+window:/ {
        v = $0; sub(/^[[:space:]]+window:[[:space:]]*/, "", v); cvelopl = trim(v); next
    }
    in_stages && entry_kind == "cycle" && /^[[:space:]]+feedback:[[:space:]]*$/ {
        in_feedback = 1; in_until = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_scope_policy = 0; next
    }
    in_stages && entry_kind == "cycle" && in_feedback && /^[[:space:]]+-[[:space:]]+from:/ {
        if (fb_from_stage != "" || fb_to_stage != "") {
            nfb++
            fb[nfb] = fb_from_stage ":" fb_from_output "|" fb_to_stage ":" fb_to_field ":" fb_required
        }
        fb_from_stage = ""; fb_from_output = ""; fb_to_stage = ""; fb_to_field = ""; fb_required = "false"
        in_fb_item = 1
        line = $0
        sub(/^[[:space:]]+-[[:space:]]+from:[[:space:]]*\{?/, "", line)
        sub(/\}.*$/, "", line)
        n = split(line, kv, /,[[:space:]]*/)
        for (i = 1; i <= n; i++) {
            split(kv[i], pair, /:[[:space:]]*/)
            key = trim(pair[1]); val = trim(pair[2])
            if (key == "stage")  fb_from_stage = val
            if (key == "output") fb_from_output = val
        }
        next
    }
    in_stages && entry_kind == "cycle" && in_feedback && in_fb_item && /^[[:space:]]+from:/ {
        line = $0; sub(/^[[:space:]]+from:[[:space:]]*\{?/, "", line); sub(/\}.*$/, "", line)
        n = split(line, kv, /,[[:space:]]*/)
        for (i = 1; i <= n; i++) {
            split(kv[i], pair, /:[[:space:]]*/)
            key = trim(pair[1]); val = trim(pair[2])
            if (key == "stage")  fb_from_stage = val
            if (key == "output") fb_from_output = val
        }
        next
    }
    in_stages && entry_kind == "cycle" && in_feedback && in_fb_item && /^[[:space:]]+to:/ {
        line = $0; sub(/^[[:space:]]+to:[[:space:]]*\{?/, "", line); sub(/\}.*$/, "", line)
        n = split(line, kv, /,[[:space:]]*/)
        for (i = 1; i <= n; i++) {
            split(kv[i], pair, /:[[:space:]]*/)
            key = trim(pair[1]); val = trim(pair[2])
            if (key == "stage")    fb_to_stage = val
            if (key == "input")    fb_to_field = val
            if (key == "required") fb_required = val
        }
        next
    }

    # ── regular-stage fields (entry_kind == "stage") ────────────────────────
    in_stages && entry_kind == "stage" && in_roles && /^[[:space:]]*-[[:space:]]/ {
        item = $0; gsub(/^[[:space:]]*-[[:space:]]+/, "", item); gsub(/[[:space:]]*$/, "", item)
        if (item != "") {
            if (current_roles == "") current_roles = item
            else current_roles = current_roles "," item
        }
        next
    }
    in_stages && entry_kind == "stage" && in_roles { in_roles = 0 }
    in_stages && entry_kind == "stage" && in_io_dests && /^[[:space:]]*-[[:space:]]/ {
        item = $0; gsub(/^[[:space:]]*-[[:space:]]+/, "", item); gsub(/[[:space:]]*$/, "", item)
        if (item != "") {
            if (current_io_dests == "") current_io_dests = item
            else current_io_dests = current_io_dests "," item
        }
        next
    }
    in_stages && entry_kind == "stage" && in_io_dests { in_io_dests = 0 }
    in_stages && entry_kind == "stage" && current_id != "" && /roles:/ {
        roles_line = $0
        if (roles_line ~ /\[/) {
            sub(/^[^[]*\[/, "", roles_line)
            sub(/\].*$/, "", roles_line)
            gsub(/[[:space:]]/, "", roles_line)
            current_roles = roles_line
        } else { in_roles = 1 }
        next
    }
    in_stages && entry_kind == "stage" && current_id != "" && /^[[:space:]]+strategy:/ {
        in_io_block = 0; in_io_dests = 0; in_router_block = 0
        current_strategy = $0
        gsub(/^[[:space:]]+strategy:[[:space:]]*/, "", current_strategy)
        gsub(/[[:space:]]*$/, "", current_strategy)
        next
    }
    in_stages && entry_kind == "stage" && current_id != "" && /^[[:space:]]+io:[[:space:]]*$/ {
        in_io_block = 1; in_router_block = 0; next
    }
    in_stages && entry_kind == "stage" && current_id != "" && /^[[:space:]]+router:[[:space:]]*$/ {
        in_io_block = 0; in_io_dests = 0; in_router_block = 1; next
    }
    in_stages && entry_kind == "stage" && in_router_block && /^[[:space:]]+timeout_s:/ {
        rt = $0; gsub(/^[[:space:]]+timeout_s:[[:space:]]*/, "", rt); gsub(/[[:space:]]*$/, "", rt); current_router_timeout = rt; next
    }
    in_stages && entry_kind == "stage" && in_router_block && /^[[:space:]]+max_turns:/ {
        rmt = $0; gsub(/^[[:space:]]+max_turns:[[:space:]]*/, "", rmt); gsub(/[[:space:]]*$/, "", rmt); current_router_max_turns = rmt; next
    }
    in_stages && entry_kind == "stage" && in_router_block && /^[[:space:]]+max_iterations:/ {
        rmi = $0; gsub(/^[[:space:]]+max_iterations:[[:space:]]*/, "", rmi); gsub(/[[:space:]]*$/, "", rmi); current_router_max_iterations = rmi; next
    }
    in_stages && entry_kind == "stage" && in_router_block && /^[[:space:]]+[a-z_]+:/ { next }
    in_stages && entry_kind == "stage" && in_io_block && /^[[:space:]]+destinations:/ {
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
    in_stages && entry_kind == "stage" && in_io_block && /^[[:space:]]+tail_lines:/ {
        tl = $0; gsub(/^[[:space:]]+tail_lines:[[:space:]]*/, "", tl); gsub(/[[:space:]]*$/, "", tl); current_io_tail = tl; in_io_dests = 0; next
    }
    in_stages && entry_kind == "stage" && in_io_block && /^[[:space:]]+redact:/ {
        rd = $0; gsub(/^[[:space:]]+redact:[[:space:]]*/, "", rd); gsub(/[[:space:]]*$/, "", rd); current_io_redact = rd; in_io_dests = 0; next
    }
    END { flush_entry() }
    ' "$file"
}

# ─── _tpl_parse_stage_definitions — parse `stage_definitions:` map (v2) ─────
# Emits one S|<id>|<roles>|<strategy>|<io_dests>|<io_tail>|<io_redact>|<rt>|<rmt>|<rmi>
# row per definition. Same payload shape as _tpl_parse_stage_data so the load
# pipeline can consume both streams uniformly.
_tpl_parse_stage_definitions() {
    local file="$1"
    awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function flush_def() {
        if (cur_id == "")
            return
        print cur_id "|" cur_roles "|" cur_strategy "|" cur_io_dests "|" cur_io_tail "|" cur_io_redact "|" cur_rt "|" cur_rmt "|" cur_rmi
    }
    function reset_def() {
        cur_id = ""; cur_roles = ""; cur_strategy = ""
        cur_io_dests = ""; cur_io_tail = ""; cur_io_redact = ""
        cur_rt = ""; cur_rmt = ""; cur_rmi = ""
        in_roles = 0; in_io_block = 0; in_io_dests = 0; in_router_block = 0
    }
    BEGIN { reset_def() }
    /^stage_definitions:[[:space:]]*$/ { in_defs = 1; next }
    in_defs && /^[a-zA-Z_]/ { flush_def(); reset_def(); in_defs = 0; next }
    # Each top-level def is "  <id>:" (2-space indent).
    in_defs && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*$/ {
        # Distinguish "  <id>:" (indent 2) from deeper "    <field>:" (indent 4+).
        line = $0
        indent = match(line, /[^ ]/) - 1
        if (indent == 2) {
            flush_def(); reset_def()
            cur_id = line; gsub(/^[[:space:]]+/, "", cur_id); gsub(/:[[:space:]]*$/, "", cur_id)
            next
        }
    }
    in_defs && cur_id != "" && in_roles && /^[[:space:]]+-[[:space:]]/ {
        item = $0; gsub(/^[[:space:]]+-[[:space:]]+/, "", item); gsub(/[[:space:]]*$/, "", item)
        if (item != "") {
            if (cur_roles == "") cur_roles = item
            else cur_roles = cur_roles "," item
        }
        next
    }
    in_defs && cur_id != "" && in_roles { in_roles = 0 }
    in_defs && cur_id != "" && in_io_dests && /^[[:space:]]+-[[:space:]]/ {
        item = $0; gsub(/^[[:space:]]+-[[:space:]]+/, "", item); gsub(/[[:space:]]*$/, "", item)
        if (item != "") {
            if (cur_io_dests == "") cur_io_dests = item
            else cur_io_dests = cur_io_dests "," item
        }
        next
    }
    in_defs && cur_id != "" && in_io_dests { in_io_dests = 0 }
    in_defs && cur_id != "" && /^[[:space:]]+roles:/ {
        roles_line = $0
        if (roles_line ~ /\[/) {
            sub(/^[^[]*\[/, "", roles_line)
            sub(/\].*$/, "", roles_line)
            gsub(/[[:space:]]/, "", roles_line)
            cur_roles = roles_line
        } else { in_roles = 1 }
        next
    }
    in_defs && cur_id != "" && /^[[:space:]]+strategy:/ {
        in_io_block = 0; in_io_dests = 0; in_router_block = 0
        cur_strategy = $0; gsub(/^[[:space:]]+strategy:[[:space:]]*/, "", cur_strategy); gsub(/[[:space:]]*$/, "", cur_strategy)
        next
    }
    in_defs && cur_id != "" && /^[[:space:]]+io:[[:space:]]*$/ { in_io_block = 1; in_router_block = 0; next }
    in_defs && cur_id != "" && /^[[:space:]]+router:[[:space:]]*$/ { in_io_block = 0; in_io_dests = 0; in_router_block = 1; next }
    in_defs && in_router_block && /^[[:space:]]+timeout_s:/ {
        v = $0; gsub(/^[[:space:]]+timeout_s:[[:space:]]*/, "", v); gsub(/[[:space:]]*$/, "", v); cur_rt = v; next
    }
    in_defs && in_router_block && /^[[:space:]]+max_turns:/ {
        v = $0; gsub(/^[[:space:]]+max_turns:[[:space:]]*/, "", v); gsub(/[[:space:]]*$/, "", v); cur_rmt = v; next
    }
    in_defs && in_router_block && /^[[:space:]]+max_iterations:/ {
        v = $0; gsub(/^[[:space:]]+max_iterations:[[:space:]]*/, "", v); gsub(/[[:space:]]*$/, "", v); cur_rmi = v; next
    }
    in_defs && in_router_block && /^[[:space:]]+[a-z_]+:/ { next }
    in_defs && in_io_block && /^[[:space:]]+destinations:/ {
        dest_line = $0
        if (dest_line ~ /\[/) {
            sub(/^[^[]*\[/, "", dest_line)
            sub(/\].*$/, "", dest_line)
            gsub(/[[:space:]]/, "", dest_line)
            cur_io_dests = dest_line
            in_io_dests = 0
        } else { in_io_dests = 1 }
        next
    }
    in_defs && in_io_block && /^[[:space:]]+tail_lines:/ {
        v = $0; gsub(/^[[:space:]]+tail_lines:[[:space:]]*/, "", v); gsub(/[[:space:]]*$/, "", v); cur_io_tail = v; in_io_dests = 0; next
    }
    in_defs && in_io_block && /^[[:space:]]+redact:/ {
        v = $0; gsub(/^[[:space:]]+redact:[[:space:]]*/, "", v); gsub(/[[:space:]]*$/, "", v); cur_io_redact = v; in_io_dests = 0; next
    }
    END { flush_def() }
    ' "$file"
}

# ─── _tpl_validate_cycles — enforce ADR-021 invariants ───────────────────────
# - stages[] is contiguous subsequence of canonical (_TPL_STAGES) order
# - max_iterations integer 1..10 (REQUIRED)
# - until.stage MUST be in cycle.stages
# - cycles MUST NOT overlap each other
_tpl_validate_cycles() {
    [[ ${#_TPL_CYCLES[@]} -eq 0 ]] && return 0
    local cid prev_end=-1
    local -A seen_stage=()
    for cid in "${_TPL_CYCLES[@]}"; do
        local safe="${cid//-/_}"
        local stages_var="_TPL_CYCLE_STAGES_${safe}"
        local stages_csv="${!stages_var:-}"
        if [[ -z "$stages_csv" ]]; then
            error "cycle '$cid': no stages declared"
            return 1
        fi
        local IFS_save="$IFS"; IFS=','
        # shellcheck disable=SC2206
        local -a cs=($stages_csv)
        IFS="$IFS_save"

        # Each stage must be a known _TPL_STAGES entry; positions must be
        # contiguous-ascending (no gaps, no out-of-order).
        # ADR-027 (Wave 17-B): a member that is itself a cycle is skipped
        # for canonical-position checks — it isn't in _TPL_STAGES[] by
        # design (only leaf stages are). The cycle's own validator runs
        # separately when its own _TPL_CYCLE_STAGES_<id> is checked.
        local first_pos=-1 last_pos=-1
        local s
        for s in "${cs[@]}"; do
            local _s_type_var="_TPL_STAGE_TYPE_${s//-/_}"
            local _s_type="${!_s_type_var:-leaf}"
            if [[ "$_s_type" == "cycle" ]]; then
                continue
            fi
            # Also skip cycle-id check via _TPL_CYCLES membership (the
            # _TPL_STAGE_TYPE_* var isn't set until later in load_template
            # — defensive when called during the per-cycle pre-pass).
            local _is_cyc=0 _c
            for _c in "${_TPL_CYCLES[@]}"; do
                [[ "$_c" == "$s" ]] && _is_cyc=1 && break
            done
            [[ $_is_cyc -eq 1 ]] && continue
            local pos=-1 i
            for i in "${!_TPL_STAGES[@]}"; do
                if [[ "${_TPL_STAGES[$i]}" == "$s" ]]; then
                    pos=$i
                    break
                fi
            done
            if [[ $pos -eq -1 ]]; then
                error "cycle '$cid': stage '$s' not in template stages[]"
                return 1
            fi
            if [[ -n "${seen_stage[$s]:-}" ]]; then
                error "cycle '$cid': stage '$s' is in another cycle (cycles must not overlap)"
                return 1
            fi
            if [[ $first_pos -eq -1 ]]; then
                first_pos=$pos
            else
                if [[ $pos -ne $((last_pos + 1)) ]]; then
                    error "cycle '$cid': stages must be a contiguous subsequence of template stages[]"
                    return 1
                fi
            fi
            last_pos=$pos
            seen_stage[$s]=1
        done

        if [[ $first_pos -le $prev_end ]]; then
            error "cycle '$cid': overlaps a previously declared cycle"
            return 1
        fi
        prev_end=$last_pos

        # max_iterations required + bounded
        local max_var="_TPL_CYCLE_MAX_${safe}"
        local max="${!max_var:-}"
        if [[ -z "$max" ]] || ! [[ "$max" =~ ^[0-9]+$ ]] || [[ "$max" -lt 1 ]] || [[ "$max" -gt 10 ]]; then
            error "cycle '$cid': max_iterations required integer in 1..10, got: ${max:-<unset>}"
            return 1
        fi

        # #840 scope_policy enum validation (ADR-030). All fields optional;
        # absent ⇒ safe defaults already applied by the consumer. When present,
        # values MUST be from the closed vocabularies — the template names
        # behaviors, it cannot express logic.
        local sx_var="_TPL_CYCLE_SCOPE_EXPANDABLE_${safe}"; local sx="${!sx_var:-false}"
        if [[ "$sx" != "true" && "$sx" != "false" ]]; then
            error "cycle '$cid': scope_policy.expandable must be true|false, got: $sx"
            return 1
        fi
        local sag_var="_TPL_CYCLE_SCOPE_AUTO_GRANT_${safe}"; local sag="${!sag_var:-}"
        if [[ -n "$sag" ]]; then
            local _cls
            local _save_ifs="$IFS"; IFS=','
            # shellcheck disable=SC2206
            local -a _classes=($sag)
            IFS="$_save_ifs"
            for _cls in "${_classes[@]}"; do
                case "$_cls" in
                    collateral_tests|collateral_config|collateral_docs|structural) : ;;
                    *) error "cycle '$cid': scope_policy.auto_grant unknown class '$_cls' (valid: collateral_tests, collateral_config, collateral_docs, structural)"; return 1 ;;
                esac
            done
        fi
        local sesc_var="_TPL_CYCLE_SCOPE_ESCALATE_${safe}"; local sesc="${!sesc_var:-none}"
        case "$sesc" in structural|none) : ;; *) error "cycle '$cid': scope_policy.escalate must be structural|none, got: $sesc"; return 1 ;; esac
        local sod_var="_TPL_CYCLE_SCOPE_ON_DENY_${safe}"; local sod="${!sod_var:-abandon}"
        case "$sod" in abandon) : ;; *) error "cycle '$cid': scope_policy.on_deny must be abandon, got: $sod"; return 1 ;; esac

        # until.stage must be in cs[]
        local us_var="_TPL_CYCLE_UNTIL_STAGE_${safe}"
        local us="${!us_var:-}"
        if [[ -z "$us" ]]; then
            error "cycle '$cid': until.stage required"
            return 1
        fi
        local found=0
        for s in "${cs[@]}"; do
            [[ "$s" == "$us" ]] && found=1 && break
        done
        if [[ $found -ne 1 ]]; then
            error "cycle '$cid': until.stage '$us' is not in cycle stages (${cs[*]})"
            return 1
        fi
    done
    return 0
}

# ─── _tpl_build_dispatch_units — assemble runner dispatch sequence ───────────
# Walks _TPL_STAGES[] in order. Each stage belongs to at most one cycle
# (validated above). On entering a cycle's first stage, emit one "cycle:<id>"
# unit covering the whole cycle. All other stages become "stage:<id>".
#
# ADR-026 / Wave 18-B (#707): when cycles nest (a cycle's `flow:` member is
# itself a cycle), the OUTERMOST enclosing cycle owns dispatch — the runner
# invokes cycle_orchestrator_run on the outermost, which then recurses into
# inner cycles via _TPL_STAGE_TYPE_<id>=cycle (Wave 17-B). The dispatch
# sequence must emit exactly one `cycle:<outermost>` unit covering all leaf
# stages reachable from the outermost cycle, in their _TPL_STAGES order.
# Without this folding, a leaf member of an inner cycle that is also the
# first member of the outer cycle would be absorbed into `cycle:<inner>`
# and the OUTER cycle would never appear in dispatch, silently dropping
# the outer-cycle semantics (exit_when, abort_when, feedback).
_tpl_build_dispatch_units() {
    _TPL_DISPATCH_UNITS=()
    # Map: stage → immediate enclosing cycle id (if any)
    local -A stage_to_cycle=()
    # Map: cycle_id → its parent cycle id (if any). A cycle A is the parent
    # of cycle B when A's CSV-stage list contains B as a member.
    local -A cycle_parent=()
    # Build a quick "is this id a registered cycle" set. We CANNOT rely on
    # _TPL_STAGE_TYPE_<id> here because _tpl_build_dispatch_units runs in
    # load_template BEFORE the type discriminator vars are populated. The
    # _TPL_CYCLES array IS populated by this point (translator topo pre-pass
    # registers cycles before this function fires).
    local -A is_cycle=()
    local _c
    for _c in "${_TPL_CYCLES[@]}"; do is_cycle[$_c]=1; done

    local cid
    for cid in "${_TPL_CYCLES[@]}"; do
        local safe="${cid//-/_}"
        local stages_var="_TPL_CYCLE_STAGES_${safe}"
        local stages_csv="${!stages_var:-}"
        local IFS_save="$IFS"; IFS=','
        # shellcheck disable=SC2206
        local -a cs=($stages_csv)
        IFS="$IFS_save"
        local s
        for s in "${cs[@]}"; do
            if [[ -n "${is_cycle[$s]:-}" ]]; then
                cycle_parent[$s]="$cid"
            else
                # Inner cycle's claim wins over outer when they overlap (which
                # shouldn't happen under acyclicity, but be explicit). Don't
                # overwrite an existing entry.
                [[ -z "${stage_to_cycle[$s]:-}" ]] && stage_to_cycle[$s]="$cid"
            fi
        done
    done

    # Resolve each cycle to its outermost ancestor.
    local -A cycle_outermost=()
    for cid in "${_TPL_CYCLES[@]}"; do
        local cur="$cid" parent
        while :; do
            parent="${cycle_parent[$cur]:-}"
            [[ -z "$parent" ]] && break
            cur="$parent"
        done
        cycle_outermost[$cid]="$cur"
    done

    local s
    local -A emitted_outer=()
    for s in "${_TPL_STAGES[@]}"; do
        local in_cycle="${stage_to_cycle[$s]:-}"
        if [[ -n "$in_cycle" ]]; then
            local outer="${cycle_outermost[$in_cycle]:-$in_cycle}"
            if [[ -z "${emitted_outer[$outer]:-}" ]]; then
                _TPL_DISPATCH_UNITS+=("cycle:$outer")
                emitted_outer[$outer]=1
            fi
            # subsequent stages absorbed under the outermost cycle unit
        else
            _TPL_DISPATCH_UNITS+=("stage:$s")
        fi
    done
    return 0
}

# ADR-015 v3 (#440): validate tail_lines (integer 1..10000) and redact (true|false)
# ADR-017 (#455): also validate router.timeout_s (integer 1..3600)
# ADR-018 (#466): also validate router.max_turns (integer 1..200)
# ADR-018 (#467): also validate router.max_iterations (integer 1..50)
# Uses Bash 5+ namerefs for safer array-by-name passing (no eval indirection).
_tpl_validate_io_knobs() {
    local -n ids_ref="$1"
    local -n tails_ref="$2"
    local -n redacts_ref="$3"
    local -n rtimeouts_ref="$4"
    local -n rmaxturns_ref="$5"
    local -n rmaxiters_ref="$6"
    local i n=${#ids_ref[@]}
    for (( i=0; i<n; i++ )); do
        local stage="${ids_ref[$i]}"
        local tail="${tails_ref[$i]}"
        local redact="${redacts_ref[$i]}"
        local rt="${rtimeouts_ref[$i]}"
        local rmt="${rmaxturns_ref[$i]}"
        local rmi="${rmaxiters_ref[$i]}"
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
            # ADR-018 Amendment N (#762): max_turns=0 is a sentinel meaning
            # "omit --max-turns flag from claude argv". Negatives and >200
            # remain invalid.
            if ! [[ "$rmt" =~ ^[0-9]+$ ]] || [[ "$rmt" -gt 200 ]]; then
                error "template: router.max_turns for stage '$stage' must be integer in 0..200, got: $rmt"
                return 1
            fi
        fi
        if [[ -n "$rmi" ]]; then
            if ! [[ "$rmi" =~ ^[0-9]+$ ]] || [[ "$rmi" -lt 1 ]] || [[ "$rmi" -gt 50 ]]; then
                error "template: router.max_iterations for stage '$stage' must be integer in 1..50, got: $rmi"
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

# ─── ADR-027 helpers (Wave 17-B #703) ─────────────────────────────────────────
#
# _tpl_is_new_shape — heuristic: top-level `flow:` key AND NO top-level
# `stages:` key indicates ADR-027 shape. The two never coexist; if both
# appear we treat as old shape (safer default — old-shape parser is mature).
_tpl_is_new_shape() {
    local file="$1"
    local has_flow=0 has_stages=0
    # Copilot P2: accept both block form `flow:\n  - x` AND inline list form
    # `flow: [a, b]`. Either matches.
    if awk 'BEGIN{rc=1} /^flow:[[:space:]]*$/ {rc=0; exit} /^flow:[[:space:]]*\[/ {rc=0; exit} END{exit rc}' "$file"; then
        has_flow=1
    fi
    if awk 'BEGIN{rc=1} /^stages:[[:space:]]*$/ {rc=0; exit} END{exit rc}' "$file"; then
        has_stages=1
    fi
    [[ $has_flow -eq 1 && $has_stages -eq 0 ]]
}

# _tpl_translate_new_shape — read an ADR-027 template and emit the same
# pipe-delimited row stream that _tpl_parse_stages_v2 + _tpl_parse_stage_definitions
# emit for the old shape. Output is two streams separated by an ASCII Unit
# Separator (\037): <stage_rows>\037<defs_rows>.
#
# Strategy: a single AWK pass walks the file in two phases:
#   1. Read top-level `flow:` block → ordered list of stage IDs.
#   2. Read every top-level stage section (key at column 0, not in the
#      reserved set {id, name, extends, defaults, flow, _comment}). For each
#      section emit either:
#        - a defs-style row (always — gives downstream the attr payload), AND
#        - a stage row in flow-order:
#            * leaf  → S| row in the position determined by the top-level
#                      flow index
#            * cycle → IC| row at that position + FB| rows for feedback
# Keeping the existing pipe schema means downstream consumers (validators,
# orchestrator, runner) need zero changes.
_tpl_translate_new_shape() {
    local file="$1"
    awk -v US=$'\037' '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function strip_inline_list(line,    s) {
        s = line; sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s)
        gsub(/[[:space:]]/, "", s); return s
    }
    function is_reserved(k) {
        return (k == "id" || k == "name" || k == "extends" || k == "defaults" \
                || k == "flow" || k == "_comment")
    }
    BEGIN {
        in_flow = 0
        flow_n = 0
        cur_key = ""
        cur_indent_unit = 2
        # per-section accumulators
        sec_type = "leaf"
        sec_roles = ""; sec_strategy = ""; sec_io_dests = ""; sec_io_tail = ""
        sec_io_redact = ""; sec_rt = ""; sec_rmt = ""; sec_rmi = ""
        # cycle accumulators
        cyc_flow = ""; cyc_max = ""; cyc_on_max = "continue"
        cyc_us = ""; cyc_uf = ""; cyc_uo = ""; cyc_uv = ""
        cyc_as = ""; cyc_af = ""; cyc_ao = ""; cyc_av = ""
        cyc_plateau = ""; cyc_diverg = ""; cyc_velopl = ""
        cyc_desc = ""
        cyc_expand = ""; cyc_autogrant = ""; cyc_escalate = ""; cyc_ondeny = ""
        nfb = 0
        in_roles = 0; in_io_block = 0; in_io_dests = 0; in_router_block = 0
        in_cflow = 0; in_exit_when = 0; in_abort_when = 0
        in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_fb_item = 0; in_scope_policy = 0
        fb_from_stage = ""; fb_from_output = ""; fb_to_stage = ""; fb_to_field = ""; fb_required = "false"
    }
    function reset_section() {
        sec_type = "leaf"
        sec_roles = ""; sec_strategy = ""; sec_io_dests = ""; sec_io_tail = ""
        sec_io_redact = ""; sec_rt = ""; sec_rmt = ""; sec_rmi = ""
        cyc_flow = ""; cyc_max = ""; cyc_on_max = "continue"
        cyc_us = ""; cyc_uf = ""; cyc_uo = ""; cyc_uv = ""
        cyc_as = ""; cyc_af = ""; cyc_ao = ""; cyc_av = ""
        cyc_plateau = ""; cyc_diverg = ""; cyc_velopl = ""
        cyc_desc = ""
        cyc_expand = ""; cyc_autogrant = ""; cyc_escalate = ""; cyc_ondeny = ""
        nfb = 0
        in_roles = 0; in_io_block = 0; in_io_dests = 0; in_router_block = 0
        in_cflow = 0; in_exit_when = 0; in_abort_when = 0
        in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_fb_item = 0; in_scope_policy = 0
        fb_from_stage = ""; fb_from_output = ""; fb_to_stage = ""; fb_to_field = ""; fb_required = "false"
        # Copilot P2: fb_kind must reset per-section so a prior "to" cannot
        # leak into the next section feedback parsing.
        fb_kind = ""
    }
    function finalize_pending_fb() {
        # Copilot P1: flush an in-flight feedback item before the section
        # closes. Without this, the LAST feedback edge in every cycle is
        # silently dropped because we previously only flushed on the NEXT
        # `- from:` opener.
        if (in_fb_item && (fb_from_stage != "" || fb_to_stage != "")) {
            nfb++
            fb[nfb] = fb_from_stage ":" fb_from_output "|" fb_to_stage ":" fb_to_field ":" fb_required
            in_fb_item = 0
            fb_from_stage = ""; fb_from_output = ""; fb_to_stage = ""; fb_to_field = ""; fb_required = "false"
            fb_kind = ""
        }
    }
    function flush_section(   k) {
        if (cur_key == "" || is_reserved(cur_key)) return
        # Finalize any in-flight feedback item now (Copilot P1).
        finalize_pending_fb()
        # Always emit a defs-style row carrying the attr payload — downstream
        # code already merges this into stage_def_row[].
        defs_out = defs_out cur_key "|" sec_roles "|" sec_strategy "|" \
                   sec_io_dests "|" sec_io_tail "|" sec_io_redact "|" \
                   sec_rt "|" sec_rmt "|" sec_rmi "\n"
        # Stash per-key so we can also emit per-stage rows in flow order.
        sec_kind[cur_key] = sec_type
        sec_payload[cur_key] = sec_roles "|" sec_strategy "|" sec_io_dests "|" \
                               sec_io_tail "|" sec_io_redact "|" sec_rt "|" sec_rmt "|" sec_rmi
        if (sec_type == "cycle") {
            cyc_data[cur_key] = cyc_flow "|" cyc_max "|" cyc_on_max "|" \
                                cyc_us "|" cyc_uf "|" cyc_uo "|" cyc_uv "|" \
                                cyc_plateau "|" cyc_diverg "|" cyc_velopl "|" cyc_desc "|" \
                                cyc_expand "|" cyc_autogrant "|" cyc_escalate "|" cyc_ondeny
            cyc_abort[cur_key] = cyc_as "|" cyc_af "|" cyc_ao "|" cyc_av
            cyc_fb_count[cur_key] = nfb
            for (k = 1; k <= nfb; k++) {
                cyc_fb[cur_key, k] = fb[k]
            }
        }
    }

    # ── Top-level flow: list ──────────────────────────────────────────────────
    # Block form: `flow:` then `- a` / `- b` items.
    /^flow:[[:space:]]*$/ {
        flush_section(); reset_section(); cur_key = ""
        in_flow = 1; next
    }
    # Copilot P2: inline-list form: `flow: [a, b, c]` on a single line.
    /^flow:[[:space:]]*\[/ {
        flush_section(); reset_section(); cur_key = ""
        line = $0
        sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
        gsub(/[[:space:]]/, "", line)
        n = split(line, items, /,/)
        for (i = 1; i <= n; i++) {
            if (items[i] != "") { flow_n++; flow[flow_n] = items[i] }
        }
        in_flow = 0
        next
    }
    in_flow && /^[[:space:]]+-[[:space:]]/ {
        item = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", item); item = trim(item)
        if (item != "") { flow_n++; flow[flow_n] = item }
        next
    }
    # Top-level non-indented line — end any current scope.
    /^[a-zA-Z_]/ {
        in_flow = 0
        flush_section(); reset_section()
        line = $0
        cur_key = line; sub(/:.*$/, "", cur_key); cur_key = trim(cur_key)
        next
    }

    # ── Within a stage section ────────────────────────────────────────────────
    cur_key != "" && !is_reserved(cur_key) {
        # type:
        if ($0 ~ /^[[:space:]]+type:[[:space:]]*cycle[[:space:]]*$/) {
            sec_type = "cycle"; next
        }
        # roles:
        if ($0 ~ /^[[:space:]]+roles:/) {
            in_roles = 0
            line = $0
            if (line ~ /\[/) {
                sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
                gsub(/[[:space:]]/, "", line); sec_roles = line
            } else { in_roles = 1 }
            next
        }
        if (in_roles && $0 ~ /^[[:space:]]+-[[:space:]]/) {
            item = $0; gsub(/^[[:space:]]+-[[:space:]]+/, "", item); gsub(/[[:space:]]*$/, "", item)
            if (item != "") sec_roles = (sec_roles == "" ? item : sec_roles "," item)
            next
        }
        if (in_roles) { in_roles = 0 }
        # strategy:
        if ($0 ~ /^[[:space:]]+strategy:/) {
            v = $0; sub(/^[[:space:]]+strategy:[[:space:]]*/, "", v); sec_strategy = trim(v); next
        }
        # io block
        if ($0 ~ /^[[:space:]]+io:[[:space:]]*$/) {
            in_io_block = 1; in_router_block = 0; next
        }
        if ($0 ~ /^[[:space:]]+router:[[:space:]]*$/) {
            in_io_block = 0; in_router_block = 1; next
        }
        if (in_io_block && $0 ~ /^[[:space:]]+destinations:/) {
            line = $0
            if (line ~ /\[/) {
                sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
                gsub(/[[:space:]]/, "", line); sec_io_dests = line; in_io_dests = 0
            } else { in_io_dests = 1 }
            next
        }
        if (in_io_dests && $0 ~ /^[[:space:]]+-[[:space:]]/) {
            item = $0; gsub(/^[[:space:]]+-[[:space:]]+/, "", item); gsub(/[[:space:]]*$/, "", item)
            if (item != "") sec_io_dests = (sec_io_dests == "" ? item : sec_io_dests "," item)
            next
        }
        if (in_io_block && $0 ~ /^[[:space:]]+tail_lines:/) {
            v = $0; sub(/^[[:space:]]+tail_lines:[[:space:]]*/, "", v); sec_io_tail = trim(v); next
        }
        if (in_io_block && $0 ~ /^[[:space:]]+redact:/) {
            v = $0; sub(/^[[:space:]]+redact:[[:space:]]*/, "", v); sec_io_redact = trim(v); next
        }
        if (in_router_block && $0 ~ /^[[:space:]]+timeout_s:/) {
            v = $0; sub(/^[[:space:]]+timeout_s:[[:space:]]*/, "", v); sec_rt = trim(v); next
        }
        if (in_router_block && $0 ~ /^[[:space:]]+max_turns:/) {
            v = $0; sub(/^[[:space:]]+max_turns:[[:space:]]*/, "", v); sec_rmt = trim(v); next
        }
        if (in_router_block && $0 ~ /^[[:space:]]+max_iterations:/) {
            # router.max_iterations vs cycle.max_iterations distinguished by context.
            if (sec_type == "cycle") {
                v = $0; sub(/^[[:space:]]+max_iterations:[[:space:]]*/, "", v); cyc_max = trim(v)
            } else {
                v = $0; sub(/^[[:space:]]+max_iterations:[[:space:]]*/, "", v); sec_rmi = trim(v)
            }
            next
        }

        # ── cycle-only ─────────────────────────────────────────────────────────
        if (sec_type == "cycle") {
            if ($0 ~ /^[[:space:]]+flow:/) {
                in_cflow = 0
                if ($0 ~ /\[/) {
                    cyc_flow = strip_inline_list($0); in_cflow = 0
                } else { in_cflow = 1 }
                in_exit_when = 0; in_abort_when = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0
                next
            }
            if (in_cflow && $0 ~ /^[[:space:]]+-[[:space:]]/) {
                item = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", item); item = trim(item)
                if (item != "") cyc_flow = (cyc_flow == "" ? item : cyc_flow "," item)
                next
            }
            if (in_cflow && $0 ~ /^[[:space:]]+[a-z_]+:/) { in_cflow = 0 }
            if ($0 ~ /^[[:space:]]+max_iterations:/) {
                v = $0; sub(/^[[:space:]]+max_iterations:[[:space:]]*/, "", v); cyc_max = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+on_max:/) {
                v = $0; sub(/^[[:space:]]+on_max:[[:space:]]*/, "", v); cyc_on_max = trim(v); next
            }
            # #831: optional operator-facing description. Strip a single
            # layer of surrounding "..." or single-quotes; never used in
            # control flow.
            if ($0 ~ /^[[:space:]]+description:[[:space:]]*/) {
                v = $0; sub(/^[[:space:]]+description:[[:space:]]*/, "", v); v = trim(v)
                gsub(/^"|"$/, "", v); gsub(/^'\''|'\''$/, "", v)
                cyc_desc = v; next
            }
            # #840 scope_policy (ADR-030): nested block; children guarded by
            # in_scope_policy. auto_grant inline list [a, b] → csv a,b.
            if ($0 ~ /^[[:space:]]+scope_policy:[[:space:]]*$/) {
                in_scope_policy = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_feedback = 0; next
            }
            if (in_scope_policy && $0 ~ /^[[:space:]]+expandable:/) {
                v = $0; sub(/^[[:space:]]+expandable:[[:space:]]*/, "", v); cyc_expand = trim(v); next
            }
            if (in_scope_policy && $0 ~ /^[[:space:]]+auto_grant:/) {
                v = $0; sub(/^[[:space:]]+auto_grant:[[:space:]]*/, "", v); v = trim(v)
                gsub(/^\[|\]$/, "", v); gsub(/[[:space:]]/, "", v); cyc_autogrant = v; next
            }
            if (in_scope_policy && $0 ~ /^[[:space:]]+escalate:/) {
                v = $0; sub(/^[[:space:]]+escalate:[[:space:]]*/, "", v); cyc_escalate = trim(v); next
            }
            if (in_scope_policy && $0 ~ /^[[:space:]]+on_deny:/) {
                v = $0; sub(/^[[:space:]]+on_deny:[[:space:]]*/, "", v); cyc_ondeny = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+plateau:[[:space:]]*$/) {
                in_plateau = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; next
            }
            if (in_plateau && $0 ~ /^[[:space:]]+window:/) {
                v = $0; sub(/^[[:space:]]+window:[[:space:]]*/, "", v); cyc_plateau = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+divergence:[[:space:]]*$/) {
                in_diverg = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_plateau = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; next
            }
            if (in_diverg && $0 ~ /^[[:space:]]+window:/) {
                v = $0; sub(/^[[:space:]]+window:[[:space:]]*/, "", v); cyc_diverg = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+velocity_plateau:[[:space:]]*$/) {
                in_velopl = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_plateau = 0; in_diverg = 0; in_feedback = 0; in_scope_policy = 0; next
            }
            if (in_velopl && $0 ~ /^[[:space:]]+window:/) {
                v = $0; sub(/^[[:space:]]+window:[[:space:]]*/, "", v); cyc_velopl = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+exit_when:[[:space:]]*$/) {
                in_exit_when = 1; in_abort_when = 0; in_cflow = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; next
            }
            if ($0 ~ /^[[:space:]]+abort_when:[[:space:]]*$/) {
                in_abort_when = 1; in_exit_when = 0; in_cflow = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; next
            }
            if (in_exit_when && $0 ~ /^[[:space:]]+stage:/) {
                v = $0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v); cyc_us = trim(v); next
            }
            if (in_exit_when && $0 ~ /^[[:space:]]+field:/) {
                v = $0; sub(/^[[:space:]]+field:[[:space:]]*/, "", v); cyc_uf = trim(v); next
            }
            if (in_exit_when && $0 ~ /^[[:space:]]+op:/) {
                v = $0; sub(/^[[:space:]]+op:[[:space:]]*/, "", v); cyc_uo = trim(v); next
            }
            if (in_exit_when && $0 ~ /^[[:space:]]+value:/) {
                v = $0; sub(/^[[:space:]]+value:[[:space:]]*/, "", v); cyc_uv = trim(v); next
            }
            if (in_abort_when && $0 ~ /^[[:space:]]+stage:/) {
                v = $0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v); cyc_as = trim(v); next
            }
            if (in_abort_when && $0 ~ /^[[:space:]]+field:/) {
                v = $0; sub(/^[[:space:]]+field:[[:space:]]*/, "", v); cyc_af = trim(v); next
            }
            if (in_abort_when && $0 ~ /^[[:space:]]+op:/) {
                v = $0; sub(/^[[:space:]]+op:[[:space:]]*/, "", v); cyc_ao = trim(v); next
            }
            if (in_abort_when && $0 ~ /^[[:space:]]+value:/) {
                v = $0; sub(/^[[:space:]]+value:[[:space:]]*/, "", v); cyc_av = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+feedback:[[:space:]]*$/) {
                in_feedback = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; next
            }
            if (in_feedback && $0 ~ /^[[:space:]]+-[[:space:]]+from:/) {
                # Close previous in-flight item.
                if (fb_from_stage != "" || fb_to_stage != "") {
                    nfb++
                    fb[nfb] = fb_from_stage ":" fb_from_output "|" fb_to_stage ":" fb_to_field ":" fb_required
                }
                fb_from_stage = ""; fb_from_output = ""; fb_to_stage = ""; fb_to_field = ""; fb_required = "false"
                in_fb_item = 1
                # Copilot P1: default fb_kind to "from" so subsequent
                # indented `stage:`/`output:` lines belonging to a multi-
                # line `- from:` opener attribute correctly. Inline form
                # (- from: { stage: X, output: Y }) overrides below.
                fb_kind = "from"
                line = $0
                sub(/^[[:space:]]+-[[:space:]]+from:[[:space:]]*\{?/, "", line)
                sub(/\}.*$/, "", line)
                # Inline form is detected via presence of a `{` or non-empty
                # stripped payload. If empty, we are in multi-line form.
                gsub(/[[:space:]]/, "", line)
                if (line != "") {
                    n = split(line, kv, /,[[:space:]]*/)
                    for (i = 1; i <= n; i++) {
                        split(kv[i], pair, /:[[:space:]]*/)
                        key = trim(pair[1]); val = trim(pair[2])
                        if (key == "stage")  fb_from_stage = val
                        if (key == "output") fb_from_output = val
                    }
                }
                next
            }
            if (in_feedback && in_fb_item) {
                if ($0 ~ /^[[:space:]]+from:[[:space:]]*$/) { fb_kind = "from"; next }
                if ($0 ~ /^[[:space:]]+to:[[:space:]]*$/)   { fb_kind = "to"; next }
                if ($0 ~ /^[[:space:]]+stage:/) {
                    v = $0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v); v = trim(v)
                    if (fb_kind == "from") fb_from_stage = v
                    else if (fb_kind == "to") fb_to_stage = v
                    next
                }
                if ($0 ~ /^[[:space:]]+output:/) {
                    v = $0; sub(/^[[:space:]]+output:[[:space:]]*/, "", v); fb_from_output = trim(v); next
                }
                if ($0 ~ /^[[:space:]]+input:/) {
                    v = $0; sub(/^[[:space:]]+input:[[:space:]]*/, "", v); fb_to_field = trim(v); next
                }
                if ($0 ~ /^[[:space:]]+required:/) {
                    v = $0; sub(/^[[:space:]]+required:[[:space:]]*/, "", v); fb_required = trim(v); next
                }
            }
        }
        next
    }

    END {
        flush_section()

        # ADR-027 (Wave 17-B): emit rows in top-level flow order. For each
        # cycle in the flow, first DFS-emit descendant cycles (innermost
        # first) so the loader registers nested cycles before their parents.
        # The loader IC handler then sees a parent cycle whose members may
        # include already-registered cycle ids, and expands them into the
        # flat _TPL_STAGES[] view recursively.
        for (i = 1; i <= flow_n; i++) {
            k = flow[i]
            kind = sec_kind[k]
            if (kind == "") kind = "leaf"
            if (kind == "cycle") {
                emit_cycle_dfs(k)
            } else {
                p = sec_payload[k]
                print "S|" k "|" p
            }
        }
        # Now defs stream (separator US, second half)
        printf "%s", US
        for (k in sec_payload) {
            print k "|" sec_payload[k]
        }
    }

    function emit_cycle_dfs(k,    j, mems, m, n) {
        if (emitted[k]) return
        emitted[k] = 1
        # Recurse into descendant cycles first.
        n = split(cyc_flow_per[k] ? cyc_flow_per[k] : extract_cyc_flow(k), mems, /,/)
        for (j = 1; j <= n; j++) {
            m = mems[j]
            if (sec_kind[m] == "cycle") emit_cycle_dfs(m)
        }
        d = cyc_data[k]
        print "IC|" k "|" d
        cnt = cyc_fb_count[k] + 0
        for (j = 1; j <= cnt; j++) print "FB|" k "|" cyc_fb[k, j]
        aw = cyc_abort[k]
        if (aw != "" && aw != "|||") print "AW|" k "|" aw
    }
    function extract_cyc_flow(k,    d) {
        # cyc_data[k] = cyc_flow|cmax|conmax|cus|cuf|cuo|cuv|cplateau|cdiverg|cyc_velopl
        d = cyc_data[k]
        sub(/\|.*$/, "", d)
        return d
    }
    ' "$file"
}

# _tpl_validate_flow_acyclic — ADR-027 reference-graph acyclicity.
# Detects when a cycle id appears in any of its descendants flows. For each
# cycle, walks the transitive _TPL_CYCLE_FLOW_* graph and refuses to load if
# the cycle's own id is reachable from itself. Uses a module-level visited
# map (_TPL_FLOW_VISITED) so the recursive helper does not need a nameref
# (avoids Bash circular-nameref warnings on common names like `_vis`).
declare -gA _TPL_FLOW_VISITED=()
_tpl_validate_flow_acyclic() {
    [[ ${#_TPL_CYCLES[@]} -eq 0 ]] && return 0
    local cid
    for cid in "${_TPL_CYCLES[@]}"; do
        _TPL_FLOW_VISITED=()
        if _tpl_flow_reaches "$cid" "$cid"; then
            error "load_template: cycle '$cid' transitively includes itself in a descendant flow (reference cycle, ADR-027 forbids)"
            return 1
        fi
    done
    return 0
}

# _tpl_flow_reaches <start_cycle> <target_id>
# DFS through nested cycle flows. Returns 0 if target reachable from start,
# 1 otherwise. Uses module-level _TPL_FLOW_VISITED for the visited set.
_tpl_flow_reaches() {
    local start="$1" target="$2"
    local safe="${start//-/_}"
    local flow_var="_TPL_CYCLE_FLOW_${safe}"
    local flow="${!flow_var:-}"
    if [[ -z "$flow" ]]; then
        # Fall back to _TPL_CYCLE_STAGES_<id> (the legacy alias).
        flow_var="_TPL_CYCLE_STAGES_${safe}"
        flow="${!flow_var:-}"
    fi
    [[ -z "$flow" ]] && return 1
    local IFS_save="$IFS"; IFS=','
    # shellcheck disable=SC2206
    local -a members=($flow)
    IFS="$IFS_save"
    local m
    for m in "${members[@]}"; do
        [[ "$m" == "$target" ]] && return 0
        [[ -n "${_TPL_FLOW_VISITED[$m]:-}" ]] && continue
        _TPL_FLOW_VISITED[$m]=1
        local type_var="_TPL_STAGE_TYPE_${m//-/_}"
        if [[ "${!type_var:-}" == "cycle" ]]; then
            if _tpl_flow_reaches "$m" "$target"; then
                return 0
            fi
        fi
    done
    return 1
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

# ADR-018 (#467): per-stage router.max_iterations (empty when unset → caller default 10).
# Consumer chokepoint: _route_resolve_max_iterations in core/router/route.sh applies
# the precedence rule (per-stage > env > compile-time default).
template_stage_router_max_iterations() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_ROUTER_MAX_ITERATIONS_${safe_id}"
    echo "${!var:-}"
}
