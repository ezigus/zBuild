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

# ADR-047 §5 (#1299): stage membership + order are NOT an engine-owned hardcoded
# roster. Membership is enforced by the manifest-derived resolvability preflight
# (_runner_validate_leaf_resolvability, runner.sh — every leaf must resolve to a
# plugin) and order by the upstream-input data-dependency DAG (contract-validator.sh).
# The retired _ZBUILD_CANONICAL_STAGES array + ZBUILD_LEGACY_STAGE_VALIDATION
# kill-switch (the strangler escape hatch) are deleted; the preflight + DAG are the
# sole enforcement.

# Module-level state — populated by load_template
_TPL_DEFAULT_STRATEGY="fanout"
_TPL_MERGE_POLICY="auto_unless_flagged"
_TPL_STAGES=()
# #1831: ordered stage ids that run on EVERY exit path (success, non-zero rc,
# SIGINT, SIGTERM, timeout). Declared by the template's top-level `always_run:`
# list, NOT part of _TPL_STAGES[] — an always-run stage is not in the flow.
_TPL_ALWAYS_RUN=()
# ADR-021 (#512): list of dispatch units in template order. Each entry is
# "stage:<id>" or "cycle:<id>". Empty `cycles:` block → every unit is "stage:<id>"
# (backwards-compat — runner behavior identical to today).
_TPL_DISPATCH_UNITS=()
# ADR-021: list of cycle ids declared in template (in declaration order).
_TPL_CYCLES=()
# #1219 (ADR-045): cycle ids whose route_back was DECLARED by the current parse.
_TPL_ROUTE_BACK_DECLARED=()
# ADR-039 (#1130): list of parallel group ids declared in template (in
# declaration order). Sibling of _TPL_CYCLES — a `type: parallel` group folds
# to one "parallel:<gid>" dispatch unit. Template-layer parse/validate only;
# execution lands in a later issue.
_TPL_PARALLEL_GROUPS=()
# issue #1295 (ADR-047 §2): list of map group ids declared in template (in
# declaration order). A `type: map` group folds to one "map:<gid>" dispatch unit.
_TPL_MAP_GROUPS=()

# ADR-015 v1 (#438): recognized io.destination tokens. Unknown tokens fail at
# template load time with an actionable error listing the valid set.
readonly _ZBUILD_IO_DESTINATIONS_VALID=(file stdout gh_comment)

load_template() {
    local template_file="$1"
    if [[ ! -f "$template_file" ]]; then
        error "load_template: file not found: $template_file"
        return 1
    fi
    # ADR-036 #1188: remember the source path so lightweight per-stage getters
    # (e.g. template_stage_negctl_timeout) can read additive scalar knobs without
    # threading them through the pipe-delimited row shape.
    _TPL_SOURCE_FILE="$template_file"; export _TPL_SOURCE_FILE

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

    local _raw_merge_policy
    _raw_merge_policy="$(yaml_get "$template_file" "merge_policy")"
    if [[ -z "$_raw_merge_policy" ]]; then
        _TPL_MERGE_POLICY="auto_unless_flagged"
    elif [[ "$_raw_merge_policy" == "auto_unless_flagged" || "$_raw_merge_policy" == "auto" || "$_raw_merge_policy" == "manual" ]]; then
        _TPL_MERGE_POLICY="$_raw_merge_policy"
    else
        error "load_template: invalid merge_policy '${_raw_merge_policy}' (valid: auto_unless_flagged | auto | manual)"
        return 1
    fi
    export _TPL_MERGE_POLICY

    local _raw_pr_draft
    _raw_pr_draft="$(yaml_get "$template_file" "pr_draft")"
    if [[ -z "$_raw_pr_draft" ]]; then
        _TPL_PR_DRAFT="false"
    elif [[ "$_raw_pr_draft" == "true" || "$_raw_pr_draft" == "false" ]]; then
        _TPL_PR_DRAFT="$_raw_pr_draft"
    else
        error "load_template: invalid pr_draft '${_raw_pr_draft}' (valid: true | false)"
        return 1
    fi
    export _TPL_PR_DRAFT

    # Scrub ALL _TPL_STAGE_BLOCKING_<id> exports at load-entry, unconditionally.
    # BL| rows are emitted only for blocking:true stages, so any stale export —
    # left by a prior load_template call, by a stage that is absent from this
    # template's flow entirely, OR inherited from the process environment on a
    # cold-start first load — would otherwise survive and mis-mark a non-blocking
    # stage as blocking (ADR-013, issue #952 follow-up to #863). Iterating over
    # the prior _TPL_STAGES was a no-op on the first load; prefix expansion over
    # the live environment closes that cold-start gap.
    local _stale_bl
    for _stale_bl in "${!_TPL_STAGE_BLOCKING_@}"; do
        # Defensive: only unset well-formed identifier names ([A-Za-z0-9_]+),
        # never a name assembled from unvalidated input.
        [[ "$_stale_bl" =~ ^_TPL_STAGE_BLOCKING_[A-Za-z0-9_]+$ ]] || continue
        unset "$_stale_bl"
    done

    _TPL_STAGES=()
    _TPL_ALWAYS_RUN=()
    _TPL_CYCLES=()
    _TPL_PARALLEL_GROUPS=()
    _TPL_MAP_GROUPS=()
    # #1219 (ADR-045): cycles whose route_back is DECLARED by THIS parse (an RB|
    # row). Distinguishes a live declaration from a route_back var left over by a
    # prior in-process load_template, so the stale-scrub below is surgical.
    _TPL_ROUTE_BACK_DECLARED=()

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
    local -a collected_router_retries=()
    local -a stage_data_rows=()

    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        local tag="${row%%|*}"
        local payload="${row#*|}"
        case "$tag" in
            S)
                # Inline regular stage row from `stages:` — full attr payload.
                # Format: <id>|<roles>|<strategy>|<io_dests>|<io_tail>|<io_redact>|<rt>|<rmt>|<rmi>|<rretries>
                local s_id s_roles s_strat s_iod s_iot s_ior s_rt s_rmt s_rmi s_rre
                IFS='|' read -r s_id s_roles s_strat s_iod s_iot s_ior s_rt s_rmt s_rmi s_rre <<< "$payload"
                [[ -z "$s_id" ]] && continue
                # Also drop into defs map so cycle members can declare attrs
                # inline if templates choose to (forward-compat).
                stage_def_row["$s_id"]="$s_roles|$s_strat|$s_iod|$s_iot|$s_ior|$s_rt|$s_rmt|$s_rmi|$s_rre"
                collected_ids+=("$s_id")
                collected_io_dests+=("$s_iod")
                collected_io_tail+=("$s_iot")
                collected_io_redact+=("$s_ior")
                collected_router_timeout+=("$s_rt")
                collected_router_max_turns+=("$s_rmt")
                collected_router_max_iterations+=("$s_rmi")
                collected_router_retries+=("$s_rre")
                stage_data_rows+=("$s_id|$s_roles|$s_strat|$s_iod|$s_iot|$s_ior|$s_rt|$s_rmt|$s_rmi|$s_rre")
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
                local m m_row m_roles m_strat m_iod m_iot m_ior m_rt m_rmt m_rmi m_rre
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
                            IFS='|' read -r m_roles m_strat m_iod m_iot m_ior m_rt m_rmt m_rmi m_rre <<< "$m_row"
                            collected_ids+=("$_im")
                            collected_io_dests+=("$m_iod")
                            collected_io_tail+=("$m_iot")
                            collected_io_redact+=("$m_ior")
                            collected_router_timeout+=("$m_rt")
                            collected_router_max_turns+=("$m_rmt")
                            collected_router_max_iterations+=("$m_rmi")
                            collected_router_retries+=("$m_rre")
                            stage_data_rows+=("$_im|$m_roles|$m_strat|$m_iod|$m_iot|$m_ior|$m_rt|$m_rmt|$m_rmi|$m_rre")
                        done
                        continue
                    fi
                    # ADR-039 (#1132): parallel-group cycle member. If `m` is a
                    # known parallel group (registered by the IP| row the
                    # translator emits BEFORE this IC| row), its leaf members are
                    # already in the flat list (the IP| handler expanded them).
                    # Skip re-adding `m` itself — the group id is not a leaf and
                    # would fail the stage_def lookup below. Any not-yet-collected
                    # member is expanded dedupe-safely (mirrors the cycle branch).
                    local _m_is_parallel=0 _pg
                    for _pg in "${_TPL_PARALLEL_GROUPS[@]}"; do
                        [[ "$_pg" == "$m" ]] && _m_is_parallel=1 && break
                    done
                    if [[ $_m_is_parallel -eq 1 ]]; then
                        local _pg_safe="${m//-/_}"
                        local _pg_flow_var="_TPL_PARALLEL_FLOW_${_pg_safe}"
                        local _pg_csv="${!_pg_flow_var:-}"
                        local IFS_save3="$IFS"; IFS=','
                        # shellcheck disable=SC2206
                        local -a _pg_members=($_pg_csv)
                        IFS="$IFS_save3"
                        local _pm
                        for _pm in "${_pg_members[@]}"; do
                            [[ -z "$_pm" ]] && continue
                            local _palready=0 _pex
                            for _pex in "${collected_ids[@]}"; do
                                [[ "$_pex" == "$_pm" ]] && _palready=1 && break
                            done
                            [[ $_palready -eq 1 ]] && continue
                            m_row="${stage_def_row[$_pm]:-}"
                            if [[ -z "$m_row" ]]; then
                                error "load_template: parallel group '$m' references stage '$_pm' but no top-level section exists"
                                return 1
                            fi
                            IFS='|' read -r m_roles m_strat m_iod m_iot m_ior m_rt m_rmt m_rmi m_rre <<< "$m_row"
                            collected_ids+=("$_pm")
                            collected_io_dests+=("$m_iod")
                            collected_io_tail+=("$m_iot")
                            collected_io_redact+=("$m_ior")
                            collected_router_timeout+=("$m_rt")
                            collected_router_max_turns+=("$m_rmt")
                            collected_router_max_iterations+=("$m_rmi")
                            collected_router_retries+=("$m_rre")
                            stage_data_rows+=("$_pm|$m_roles|$m_strat|$m_iod|$m_iot|$m_ior|$m_rt|$m_rmt|$m_rmi|$m_rre")
                            local _pm_safe="${_pm//-/_}"
                            printf -v "_TPL_PARALLEL_MEMBER_OF_${_pm_safe}" '%s' "$m"
                            export "_TPL_PARALLEL_MEMBER_OF_${_pm_safe}"
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
                    IFS='|' read -r m_roles m_strat m_iod m_iot m_ior m_rt m_rmt m_rmi m_rre <<< "$m_row"
                    collected_ids+=("$m")
                    collected_io_dests+=("$m_iod")
                    collected_io_tail+=("$m_iot")
                    collected_io_redact+=("$m_ior")
                    collected_router_timeout+=("$m_rt")
                    collected_router_max_turns+=("$m_rmt")
                    collected_router_max_iterations+=("$m_rmi")
                    collected_router_retries+=("$m_rre")
                    stage_data_rows+=("$m|$m_roles|$m_strat|$m_iod|$m_iot|$m_ior|$m_rt|$m_rmt|$m_rmi|$m_rre")
                done
                ;;
            IP)
                # ADR-039 (#1130): inline parallel group entry. Format:
                # <gid>|<members_csv>|<max_parallel>|<on_member_error>|<aggregate>
                # Mirrors IC| (cycle). Members are leaf stages expanded into the
                # flat _TPL_STAGES[] with per-stage attr vars (from the defs map),
                # exactly like cycle members. Phase 1 (ADR-040 §3): the 5th field is
                # the `aggregate:` declaration — exported as _TPL_PARALLEL_AGGREGATE_<id>
                # so the preflight contract validator can bind the group to its typed
                # aggregator (empty when the group declares no aggregate).
                local pid pmembers pmax ponerr pagg
                IFS='|' read -r pid pmembers pmax ponerr pagg <<< "$payload"
                [[ -z "$pid" ]] && continue
                _TPL_PARALLEL_GROUPS+=("$pid")
                local psafe="${pid//-/_}"
                printf -v "_TPL_PARALLEL_FLOW_${psafe}"   '%s' "$pmembers"
                printf -v "_TPL_PARALLEL_MAX_${psafe}"    '%s' "$pmax"
                printf -v "_TPL_PARALLEL_ON_ERR_${psafe}" '%s' "${ponerr:-continue}"
                printf -v "_TPL_PARALLEL_AGGREGATE_${psafe}" '%s' "$pagg"
                export "_TPL_PARALLEL_FLOW_${psafe}" "_TPL_PARALLEL_MAX_${psafe}" \
                       "_TPL_PARALLEL_ON_ERR_${psafe}" "_TPL_PARALLEL_AGGREGATE_${psafe}"
                # Expand parallel members in declaration order into the flat
                # stage list (per-stage attrs come from stage_def_row, like
                # cycle members).
                local p_IFS_save="$IFS"; IFS=','
                # shellcheck disable=SC2206
                local -a pmembers_arr=($pmembers)
                IFS="$p_IFS_save"
                local pm pm_row pm_roles pm_strat pm_iod pm_iot pm_ior pm_rt pm_rmt pm_rmi pm_rre
                for pm in "${pmembers_arr[@]}"; do
                    [[ -z "$pm" ]] && continue
                    # Dedupe — a member already added (defensive; validator
                    # rejects cross-group overlap separately).
                    local _p_already=0 _p_ex
                    for _p_ex in "${collected_ids[@]}"; do
                        [[ "$_p_ex" == "$pm" ]] && _p_already=1 && break
                    done
                    [[ $_p_already -eq 1 ]] && continue
                    pm_row="${stage_def_row[$pm]:-}"
                    if [[ -z "$pm_row" ]]; then
                        error "load_template: parallel group '$pid' references stage '$pm' but no top-level section / 'stage_definitions.$pm' entry exists"
                        return 1
                    fi
                    IFS='|' read -r pm_roles pm_strat pm_iod pm_iot pm_ior pm_rt pm_rmt pm_rmi pm_rre <<< "$pm_row"
                    collected_ids+=("$pm")
                    collected_io_dests+=("$pm_iod")
                    collected_io_tail+=("$pm_iot")
                    collected_io_redact+=("$pm_ior")
                    collected_router_timeout+=("$pm_rt")
                    collected_router_max_turns+=("$pm_rmt")
                    collected_router_max_iterations+=("$pm_rmi")
                    collected_router_retries+=("$pm_rre")
                    stage_data_rows+=("$pm|$pm_roles|$pm_strat|$pm_iod|$pm_iot|$pm_ior|$pm_rt|$pm_rmt|$pm_rmi|$pm_rre")
                    local pm_safe="${pm//-/_}"
                    printf -v "_TPL_PARALLEL_MEMBER_OF_${pm_safe}" '%s' "$pid"
                    export "_TPL_PARALLEL_MEMBER_OF_${pm_safe}"
                done
                ;;
            IM)
                # issue #1295 (ADR-047 §2): inline map group entry.
                # Row: <gid>|<over>|<elements_csv>|<max>|<onerr>|<agg>|<as>|<roles>|<strategy>|<io_dests>|<io_tail>|<io_redact>|<rt>|<rmt>|<rmi>|<rre>
                # sec_payload contributes roles|strategy|io_dests|io_tail|io_redact|rt|rmt|rmi|rre
                # (strategy is unused for map groups but must be consumed to keep field offsets correct).
                # <as> names an env var to populate with each element (generic
                # dimension→env mapping; empty when omitted).
                # Unlike parallel groups, map groups add the GROUP ID itself (not
                # individual elements) to _TPL_STAGES so _tpl_build_dispatch_units
                # can detect it and emit a "map:<gid>" dispatch unit.
                local im_gid im_over im_elements im_max im_onerr im_agg im_as im_roles im_strat im_iod im_iot im_ior im_rt im_rmt im_rmi im_rre
                IFS='|' read -r im_gid im_over im_elements im_max im_onerr im_agg im_as im_roles im_strat im_iod im_iot im_ior im_rt im_rmt im_rmi im_rre <<< "$payload"
                [[ -z "$im_gid" ]] && continue
                _TPL_MAP_GROUPS+=("$im_gid")
                local im_safe="${im_gid//-/_}"
                printf -v "_TPL_MAP_OVER_${im_safe}"      '%s' "$im_over"
                printf -v "_TPL_MAP_ELEMENTS_${im_safe}"  '%s' "$im_elements"
                printf -v "_TPL_MAP_MAX_${im_safe}"        '%s' "$im_max"
                printf -v "_TPL_MAP_ON_ERR_${im_safe}"    '%s' "${im_onerr:-continue}"
                printf -v "_TPL_MAP_AGGREGATE_${im_safe}" '%s' "$im_agg"
                printf -v "_TPL_MAP_AS_${im_safe}"        '%s' "$im_as"
                printf -v "_TPL_MAP_ROLES_${im_safe}"     '%s' "$im_roles"
                printf -v "_TPL_STAGE_TYPE_${im_safe}"    '%s' "map"
                export "_TPL_MAP_OVER_${im_safe}" "_TPL_MAP_ELEMENTS_${im_safe}" \
                       "_TPL_MAP_MAX_${im_safe}" "_TPL_MAP_ON_ERR_${im_safe}" \
                       "_TPL_MAP_AGGREGATE_${im_safe}" "_TPL_MAP_AS_${im_safe}" \
                       "_TPL_MAP_ROLES_${im_safe}" \
                       "_TPL_STAGE_TYPE_${im_safe}"
                # The map group registers per-group io/router vars so the runner
                # can resolve them via _TPL_STAGE_IO_DESTS_<safe> (same path as
                # leaf stages); roles var drives plugin resolution at dispatch.
                printf -v "_TPL_STAGE_ROLES_${im_safe}"      '%s' "$im_roles"
                printf -v "_TPL_STAGE_IO_DESTS_${im_safe}"   '%s' "$im_iod"
                printf -v "_TPL_STAGE_IO_TAIL_${im_safe}"    '%s' "$im_iot"
                printf -v "_TPL_STAGE_ROUTER_TIMEOUT_${im_safe}"   '%s' "$im_rt"
                printf -v "_TPL_STAGE_ROUTER_MAX_TURNS_${im_safe}" '%s' "$im_rmt"
                export "_TPL_STAGE_ROLES_${im_safe}" "_TPL_STAGE_IO_DESTS_${im_safe}" \
                       "_TPL_STAGE_IO_TAIL_${im_safe}" \
                       "_TPL_STAGE_ROUTER_TIMEOUT_${im_safe}" "_TPL_STAGE_ROUTER_MAX_TURNS_${im_safe}"
                # Add the group id to _TPL_STAGES. stage_data_rows drives the
                # _TPL_STAGES[] population loop; collected_* parallel arrays feed
                # the validators — all must stay in lockstep.
                stage_data_rows+=("$im_gid|$im_roles|$im_strat|$im_iod|$im_iot|$im_ior|$im_rt|$im_rmt|$im_rmi|$im_rre")
                collected_ids+=("$im_gid")
                collected_io_dests+=("$im_iod")
                collected_io_tail+=("$im_iot")
                collected_io_redact+=("$im_ior")
                collected_router_timeout+=("$im_rt")
                collected_router_max_turns+=("$im_rmt")
                collected_router_max_iterations+=("$im_rmi")
                collected_router_retries+=("$im_rre")
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
            RB)
                # #1217 (ADR-045): bounded typed backward-route for a cycle.
                # Format: <cid>|<to>|<stage>|<field>|<op>|<value>|<max>
                local rb_cid rb_to rb_stage rb_field rb_op rb_value rb_max
                IFS='|' read -r rb_cid rb_to rb_stage rb_field rb_op rb_value rb_max <<< "$payload"
                local rb_safe="${rb_cid//-/_}"
                printf -v "_TPL_CYCLE_ROUTE_BACK_TO_${rb_safe}"    '%s' "$rb_to"
                printf -v "_TPL_CYCLE_ROUTE_BACK_STAGE_${rb_safe}" '%s' "$rb_stage"
                printf -v "_TPL_CYCLE_ROUTE_BACK_FIELD_${rb_safe}" '%s' "$rb_field"
                printf -v "_TPL_CYCLE_ROUTE_BACK_OP_${rb_safe}"    '%s' "$rb_op"
                printf -v "_TPL_CYCLE_ROUTE_BACK_VALUE_${rb_safe}" '%s' "$rb_value"
                printf -v "_TPL_CYCLE_ROUTE_BACK_MAX_${rb_safe}"   '%s' "$rb_max"
                export "_TPL_CYCLE_ROUTE_BACK_TO_${rb_safe}" \
                       "_TPL_CYCLE_ROUTE_BACK_STAGE_${rb_safe}" \
                       "_TPL_CYCLE_ROUTE_BACK_FIELD_${rb_safe}" \
                       "_TPL_CYCLE_ROUTE_BACK_OP_${rb_safe}" \
                       "_TPL_CYCLE_ROUTE_BACK_VALUE_${rb_safe}" \
                       "_TPL_CYCLE_ROUTE_BACK_MAX_${rb_safe}"
                # #1219: record that THIS parse declared route_back on this cycle,
                # so the stale-scrub below (which clears route_back inherited from a
                # prior in-process load_template) never clears a live declaration —
                # and _tpl_validate_route_back still REJECTS a route_back genuinely
                # declared on a nested cycle.
                _TPL_ROUTE_BACK_DECLARED+=("$rb_cid")
                ;;
            EW)
                # #1284 (ADR-047): multi-condition exit_when for cycles.
                # Format: <cid>|<combinator>|<n>|s1|f1|o1|v1|...|sN|fN|oN|vN
                # combinator = all|any; n = number of conditions.
                # Single-condition form is unchanged (no EW row emitted).
                local ew_cid ew_comb ew_n ew_rest
                ew_cid="${payload%%|*}"; ew_rest="${payload#*|}"
                ew_comb="${ew_rest%%|*}"; ew_rest="${ew_rest#*|}"
                ew_n="${ew_rest%%|*}";   ew_rest="${ew_rest#*|}"
                if ! [[ "$ew_n" =~ ^[0-9]+$ ]] || [[ "$ew_n" -lt 1 ]]; then
                    error "load_template: EW row for cycle '${ew_cid}': invalid condition count '${ew_n}'"
                    return 1
                fi
                local ew_safe="${ew_cid//-/_}"
                printf -v "_TPL_CYCLE_EXIT_COMBINATOR_${ew_safe}" '%s' "$ew_comb"
                printf -v "_TPL_CYCLE_EXIT_COUNT_${ew_safe}"       '%s' "$ew_n"
                export "_TPL_CYCLE_EXIT_COMBINATOR_${ew_safe}" "_TPL_CYCLE_EXIT_COUNT_${ew_safe}"
                # Consume exactly n conditions of 4 pipe-delimited fields each.
                # Values never contain '|' in this grammar, so the final field is
                # read with the same %%|* semantics and any leftover payload (a
                # stray trailing '|' or a value containing '|') is a malformed row
                # — fail loudly rather than silently absorb it into the last value.
                local ew_i ew_more
                for (( ew_i=1; ew_i<=ew_n; ew_i++ )); do
                    local ew_s ew_f ew_o ew_v
                    if [[ "$ew_rest" != *"|"* ]] && [[ "$ew_i" -lt "$ew_n" ]]; then
                        error "load_template: EW row for cycle '${ew_cid}': truncated at condition ${ew_i} of ${ew_n}"
                        return 1
                    fi
                    ew_s="${ew_rest%%|*}"; ew_rest="${ew_rest#*|}"
                    ew_f="${ew_rest%%|*}"; ew_rest="${ew_rest#*|}"
                    ew_o="${ew_rest%%|*}"; ew_rest="${ew_rest#*|}"
                    if [[ "$ew_i" -eq "$ew_n" ]]; then
                        # Final field: no more separators expected after the value.
                        ew_v="${ew_rest%%|*}"
                        ew_more="${ew_rest#"$ew_v"}"
                        if [[ -n "$ew_more" ]]; then
                            error "load_template: EW row for cycle '${ew_cid}': trailing data after ${ew_n} condition(s) — malformed row (extra '|' or value contains '|')"
                            return 1
                        fi
                    else
                        ew_v="${ew_rest%%|*}"; ew_rest="${ew_rest#*|}"
                    fi
                    if [[ -z "$ew_s" || -z "$ew_f" || -z "$ew_o" || -z "$ew_v" ]]; then
                        error "load_template: EW row for cycle '${ew_cid}': condition ${ew_i} has an empty field (stage/field/op/value all required)"
                        return 1
                    fi
                    printf -v "_TPL_CYCLE_EXIT_${ew_i}_STAGE_${ew_safe}" '%s' "$ew_s"
                    printf -v "_TPL_CYCLE_EXIT_${ew_i}_FIELD_${ew_safe}" '%s' "$ew_f"
                    printf -v "_TPL_CYCLE_EXIT_${ew_i}_OP_${ew_safe}"    '%s' "$ew_o"
                    printf -v "_TPL_CYCLE_EXIT_${ew_i}_VALUE_${ew_safe}" '%s' "$ew_v"
                    export "_TPL_CYCLE_EXIT_${ew_i}_STAGE_${ew_safe}" \
                           "_TPL_CYCLE_EXIT_${ew_i}_FIELD_${ew_safe}" \
                           "_TPL_CYCLE_EXIT_${ew_i}_OP_${ew_safe}"    \
                           "_TPL_CYCLE_EXIT_${ew_i}_VALUE_${ew_safe}"
                done
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
            AR)
                # #1831: the ordered always-run list. Payload is the CSV itself
                # (no stage-id field — the row IS the list), so it is read whole
                # rather than split on the leading `|` like every other row.
                local _ar_ifs="$IFS"; IFS=','
                # shellcheck disable=SC2206
                _TPL_ALWAYS_RUN=($payload)
                IFS="$_ar_ifs"
                ;;
            BL)
                # ADR-013 blocking attribute (CQ-3 / issue #863).
                # Format: <stage_id>|true
                local bl_id bl_val
                IFS='|' read -r bl_id bl_val <<< "$payload"
                [[ "$bl_val" == "true" ]] || continue
                local bl_safe="${bl_id//-/_}"
                printf -v "_TPL_STAGE_BLOCKING_${bl_safe}" '%s' "true"
                export "_TPL_STAGE_BLOCKING_${bl_safe}"
                ;;
        esac
    done <<< "$stage_rows"

    # Validate io/router before mutating per-stage state. Stage membership + order
    # are enforced downstream: the manifest-derived resolvability preflight
    # (runner.sh) + the data-dependency DAG (contract-validator.sh) — not here.
    _tpl_validate_io_dests collected_ids collected_io_dests || return 1
    _tpl_validate_io_knobs collected_ids collected_io_tail collected_io_redact \
        collected_router_timeout collected_router_max_turns \
        collected_router_max_iterations collected_router_retries || return 1

    # Populate per-stage state (flat _TPL_STAGES[] + per-id env vars).
    local stage_id roles strategy io_dests io_tail io_redact router_timeout router_max_turns router_max_iterations router_retries
    for row in "${stage_data_rows[@]}"; do
        IFS='|' read -r stage_id roles strategy io_dests io_tail io_redact router_timeout router_max_turns router_max_iterations router_retries <<< "$row"
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
        printf -v "_TPL_STAGE_ROUTER_RETRIES_${safe_id}" '%s' "$router_retries"
        export "_TPL_STAGE_ROLES_${safe_id}" \
               "_TPL_STAGE_STRATEGY_${safe_id}" \
               "_TPL_STAGE_IO_DESTS_${safe_id}" \
               "_TPL_STAGE_IO_TAIL_${safe_id}" \
               "_TPL_STAGE_IO_REDACT_${safe_id}" \
               "_TPL_STAGE_ROUTER_TIMEOUT_${safe_id}" \
               "_TPL_STAGE_ROUTER_MAX_TURNS_${safe_id}" \
               "_TPL_STAGE_ROUTER_MAX_ITERATIONS_${safe_id}" \
               "_TPL_STAGE_ROUTER_RETRIES_${safe_id}"
    done

    # ── #1831: always-run stage attributes ────────────────────────────────────
    # These stages are NOT in _TPL_STAGES[], so the loop above never saw them.
    # They still need their roles and router.timeout_s exported, because the
    # runner resolves and bounds them from the EXIT trap exactly like any other
    # dispatch. Fail CLOSED on a member with no section: an always-run stage
    # that silently does not exist is the failure this attribute was built to
    # remove (#1878 — "the snapshot was never called"), so a typo in the list
    # must refuse the template, not degrade to running nothing.
    local _ar_id _ar_row _ar_safe
    local _ar_roles _ar_strat _ar_iod _ar_iot _ar_ior _ar_rt _ar_rmt _ar_rmi _ar_rre
    for _ar_id in "${_TPL_ALWAYS_RUN[@]}"; do
        _ar_row="${stage_def_row[$_ar_id]:-}"
        if [[ -z "$_ar_row" ]]; then
            error "load_template: always_run names '$_ar_id' but no top-level section defines it"
            return 1
        fi
        IFS='|' read -r _ar_roles _ar_strat _ar_iod _ar_iot _ar_ior _ar_rt _ar_rmt _ar_rmi _ar_rre <<< "$_ar_row"
        if [[ -z "$_ar_roles" ]]; then
            error "load_template: always_run stage '$_ar_id' declares no roles: — the runner resolves it by role"
            return 1
        fi
        _ar_safe="${_ar_id//-/_}"
        printf -v "_TPL_STAGE_ROLES_${_ar_safe}"          '%s' "$_ar_roles"
        printf -v "_TPL_STAGE_IO_DESTS_${_ar_safe}"       '%s' "$_ar_iod"
        printf -v "_TPL_STAGE_IO_TAIL_${_ar_safe}"        '%s' "$_ar_iot"
        printf -v "_TPL_STAGE_IO_REDACT_${_ar_safe}"      '%s' "$_ar_ior"
        printf -v "_TPL_STAGE_ROUTER_TIMEOUT_${_ar_safe}" '%s' "$_ar_rt"
        export "_TPL_STAGE_ROLES_${_ar_safe}" \
               "_TPL_STAGE_IO_DESTS_${_ar_safe}" \
               "_TPL_STAGE_IO_TAIL_${_ar_safe}" \
               "_TPL_STAGE_IO_REDACT_${_ar_safe}" \
               "_TPL_STAGE_ROUTER_TIMEOUT_${_ar_safe}"
    done

    _tpl_validate_cycles || return 1
    _tpl_validate_parallel || return 1
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
    # ADR-039 (#1130): parallel group ids get _TPL_STAGE_TYPE_<gid>=parallel
    # (sibling of the cycle discriminator). Members remain leaf (set above).
    for _st_id in "${_TPL_PARALLEL_GROUPS[@]}"; do
        _st_safe="${_st_id//-/_}"
        printf -v "_TPL_STAGE_TYPE_${_st_safe}" '%s' "parallel"
        export "_TPL_STAGE_TYPE_${_st_safe}"
    done
    # issue #1295 (ADR-047 §2): map group ids get _TPL_STAGE_TYPE_<gid>=map.
    # The group id itself is in _TPL_STAGES (set above to leaf); overwrite here.
    for _st_id in "${_TPL_MAP_GROUPS[@]}"; do
        _st_safe="${_st_id//-/_}"
        printf -v "_TPL_STAGE_TYPE_${_st_safe}" '%s' "map"
        export "_TPL_STAGE_TYPE_${_st_safe}"
    done

    # ADR-027 contract validator (Wave 17-B #703): reference-graph acyclicity.
    # If any cycle's flow transitively includes itself, refuse to load.
    _tpl_validate_flow_acyclic || return 1
    # #1219 (ADR-045): scrub STALE route_back exports left over from a PRIOR
    # load_template in the same process (route_back vars are exported and never
    # reset per-cycle). A route_back var on a cycle that is NOT a dispatch unit of
    # THIS template AND was NOT declared by THIS parse can only be such a leftover.
    # #1225 (ADR-045): route_back is now valid on a NESTED cycle too (its rc=11
    # propagates to the runner), so the scrub does NOT key on top-level-ness — it
    # keeps every route_back DECLARED by this parse (top-level OR nested) and only
    # clears UNDECLARED inheritance. Without this, loading a template WHOSE cycle
    # declares route_back (simple.yaml's top-level build_test_cycle) and THEN one
    # that reuses the id for a NESTED cycle (standard.yaml nests build_test_cycle)
    # would leave the stale route_back on the nested cycle. This stays surgical —
    # it clears only stale inheritance, never a live edge declared this parse.
    local _rb_cid _rb_safe _rb_u _rb_top _rb_declared
    for _rb_cid in ${_TPL_CYCLES[@]+"${_TPL_CYCLES[@]}"}; do
        # Keep a route_back DECLARED by this parse (top-level OR nested — #1225
        # supports nested route_back; the validator below enforces strictly-earlier
        # target regardless of nesting).
        _rb_declared=0
        for _rb_u in ${_TPL_ROUTE_BACK_DECLARED[@]+"${_TPL_ROUTE_BACK_DECLARED[@]}"}; do
            [[ "$_rb_u" == "$_rb_cid" ]] && { _rb_declared=1; break; }
        done
        [[ $_rb_declared -eq 1 ]] && continue
        # Keep a top-level cycle's route_back var (a test may inject an edge `max`
        # for one, #1217); only a NON-top-level cycle's UNDECLARED route_back is
        # stale inheritance from a prior in-process load.
        _rb_top=0
        for _rb_u in ${_TPL_DISPATCH_UNITS[@]+"${_TPL_DISPATCH_UNITS[@]}"}; do
            [[ "$_rb_u" == "cycle:$_rb_cid" ]] && { _rb_top=1; break; }
        done
        [[ $_rb_top -eq 1 ]] && continue
        _rb_safe="${_rb_cid//-/_}"
        unset "_TPL_CYCLE_ROUTE_BACK_TO_${_rb_safe}" \
              "_TPL_CYCLE_ROUTE_BACK_STAGE_${_rb_safe}" \
              "_TPL_CYCLE_ROUTE_BACK_FIELD_${_rb_safe}" \
              "_TPL_CYCLE_ROUTE_BACK_OP_${_rb_safe}" \
              "_TPL_CYCLE_ROUTE_BACK_VALUE_${_rb_safe}" \
              "_TPL_CYCLE_ROUTE_BACK_MAX_${_rb_safe}" 2>/dev/null || true
    done
    # #1217 (ADR-045): the bounded route_back edge carve-out. Permitted iff the
    # target is a strictly-earlier dispatch unit and `max` is a finite positive
    # int (rejects forward/self/unbounded). Runs AFTER _tpl_build_dispatch_units
    # (line above) so _TPL_DISPATCH_UNITS[] ordering is available.
    _tpl_validate_route_back || return 1
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
            print "S|" current_id "|" current_roles "|" current_strategy "|" current_io_dests "|" current_io_tail "|" current_io_redact "|" current_router_timeout "|" current_router_max_turns "|" current_router_max_iterations "|" current_router_retries
        }
    }
    function reset_entry() {
        current_id = ""; entry_kind = "stage"
        current_roles = ""; current_strategy = ""; current_io_dests = ""
        current_io_tail = ""; current_io_redact = ""; current_router_timeout = ""
        current_router_max_turns = ""; current_router_max_iterations = ""; current_router_retries = ""
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
    in_stages && entry_kind == "stage" && in_router_block && /^[[:space:]]+retries:/ {
        rre = $0; gsub(/^[[:space:]]+retries:[[:space:]]*/, "", rre); gsub(/[[:space:]]*$/, "", rre); current_router_retries = rre; next
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
        print cur_id "|" cur_roles "|" cur_strategy "|" cur_io_dests "|" cur_io_tail "|" cur_io_redact "|" cur_rt "|" cur_rmt "|" cur_rmi "|" cur_rre
    }
    function reset_def() {
        cur_id = ""; cur_roles = ""; cur_strategy = ""
        cur_io_dests = ""; cur_io_tail = ""; cur_io_redact = ""
        cur_rt = ""; cur_rmt = ""; cur_rmi = ""; cur_rre = ""
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
    in_defs && in_router_block && /^[[:space:]]+retries:/ {
        v = $0; gsub(/^[[:space:]]+retries:[[:space:]]*/, "", v); gsub(/[[:space:]]*$/, "", v); cur_rre = v; next
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
            # ADR-039 (#1132): a member that is a parallel group is likewise not
            # in _TPL_STAGES[] (only its leaf members are). Skip it here — the
            # group structure is validated by _tpl_validate_parallel.
            local _is_par=0 _pg
            for _pg in "${_TPL_PARALLEL_GROUPS[@]}"; do
                [[ "$_pg" == "$s" ]] && _is_par=1 && break
            done
            [[ $_is_par -eq 1 ]] && continue
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

        # A cycle whose members are ALL nested cycles / parallel groups has no
        # canonical leaf position of its own (first_pos stays -1) — there is
        # nothing to overlap-check or advance prev_end with. (#1132)
        if [[ $first_pos -ne -1 ]]; then
            if [[ $first_pos -le $prev_end ]]; then
                error "cycle '$cid': overlaps a previously declared cycle"
                return 1
            fi
            prev_end=$last_pos
        fi

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

        # #1284 (ADR-047): multi-condition exit_when replaces the single-condition
        # UNTIL vars. When a combinator is present, validate the N conditions at
        # this preflight layer (mirroring the runtime check in cycle-orchestrator.sh
        # _cycle_load_template); otherwise validate the single-condition until.stage.
        local ew_comb_check_var="_TPL_CYCLE_EXIT_COMBINATOR_${safe}"
        local ew_comb="${!ew_comb_check_var:-}"
        if [[ -n "$ew_comb" ]]; then
            case "$ew_comb" in
                all|any) : ;;
                *) error "cycle '$cid': exit_when combinator must be all|any, got: $ew_comb"; return 1 ;;
            esac
            local ew_count_var="_TPL_CYCLE_EXIT_COUNT_${safe}"
            local ew_count="${!ew_count_var:-}"
            if [[ -z "$ew_count" ]] || ! [[ "$ew_count" =~ ^[0-9]+$ ]] || [[ "$ew_count" -lt 1 ]]; then
                error "cycle '$cid': exit_when multi-condition count must be integer >=1, got: ${ew_count:-<unset>}"
                return 1
            fi
            local ew_i
            for (( ew_i=1; ew_i<=ew_count; ew_i++ )); do
                local _sv="_TPL_CYCLE_EXIT_${ew_i}_STAGE_${safe}"
                local _fv="_TPL_CYCLE_EXIT_${ew_i}_FIELD_${safe}"
                local _ov="_TPL_CYCLE_EXIT_${ew_i}_OP_${safe}"
                local _vv="_TPL_CYCLE_EXIT_${ew_i}_VALUE_${safe}"
                local ew_s="${!_sv:-}" ew_f="${!_fv:-}" ew_o="${!_ov:-}" ew_v="${!_vv:-}"
                if [[ -z "$ew_s" || -z "$ew_f" || -z "$ew_o" || -z "$ew_v" ]]; then
                    error "cycle '$cid': exit_when condition $ew_i: {stage,field,op,value} all required"
                    return 1
                fi
                case "$ew_f" in
                    verdict|status) : ;;
                    *) error "cycle '$cid': exit_when condition $ew_i: field must be verdict|status, got: $ew_f"; return 1 ;;
                esac
                case "$ew_o" in
                    eq|ne) : ;;
                    *) error "cycle '$cid': exit_when condition $ew_i: op must be eq|ne, got: $ew_o"; return 1 ;;
                esac
                local found=0
                for s in "${cs[@]}"; do
                    [[ "$s" == "$ew_s" ]] && found=1 && break
                done
                if [[ $found -ne 1 ]]; then
                    error "cycle '$cid': exit_when condition $ew_i: stage '$ew_s' is not in cycle stages (${cs[*]})"
                    return 1
                fi
            done
        else
            # Single-condition: until.stage must be set and in cs[].
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
        fi
    done
    return 0
}

# ─── _tpl_validate_parallel — enforce ADR-039 invariants ─────────────────────
# - each group has >=1 member
# - members disjoint from cycle members and from other parallel groups
# - max_parallel is empty or a positive integer
# - on_member_error ∈ {continue, collect}
_tpl_validate_parallel() {
    [[ ${#_TPL_PARALLEL_GROUPS[@]} -eq 0 ]] && return 0

    # Build the set of all cycle members for disjointness checks.
    local -A cycle_member=()
    local cid
    for cid in "${_TPL_CYCLES[@]}"; do
        local c_safe="${cid//-/_}"
        local c_var="_TPL_CYCLE_STAGES_${c_safe}"
        local c_csv="${!c_var:-}"
        local c_IFS_save="$IFS"; IFS=','
        # shellcheck disable=SC2206
        local -a cms=($c_csv)
        IFS="$c_IFS_save"
        local cm
        for cm in "${cms[@]}"; do
            [[ -n "$cm" ]] && cycle_member[$cm]=1
        done
    done

    local gid
    local -A seen_member=()
    for gid in "${_TPL_PARALLEL_GROUPS[@]}"; do
        local safe="${gid//-/_}"
        local flow_var="_TPL_PARALLEL_FLOW_${safe}"
        local flow_csv="${!flow_var:-}"
        local g_IFS_save="$IFS"; IFS=','
        # shellcheck disable=SC2206
        local -a ms=($flow_csv)
        IFS="$g_IFS_save"

        # >=1 member
        local member_count=0 m
        for m in "${ms[@]}"; do
            [[ -n "$m" ]] && member_count=$((member_count + 1))
        done
        if [[ $member_count -eq 0 ]]; then
            error "parallel group '$gid': no members declared (>=1 required)"
            return 1
        fi

        for m in "${ms[@]}"; do
            [[ -z "$m" ]] && continue
            if [[ -n "${cycle_member[$m]:-}" ]]; then
                error "parallel group '$gid': member '$m' is also a cycle member (parallel members must be disjoint from cycles)"
                return 1
            fi
            if [[ -n "${seen_member[$m]:-}" ]]; then
                error "parallel group '$gid': member '$m' is in another parallel group (parallel groups must not overlap)"
                return 1
            fi
            seen_member[$m]=1
        done

        # max_parallel: empty (unbounded) or a positive integer.
        local max_var="_TPL_PARALLEL_MAX_${safe}"
        local max="${!max_var:-}"
        if [[ -n "$max" ]]; then
            if ! [[ "$max" =~ ^[0-9]+$ ]] || [[ "$max" -lt 1 ]]; then
                error "parallel group '$gid': max_parallel must be empty or a positive integer, got: $max"
                return 1
            fi
        fi

        # on_member_error: closed vocabulary (the template names behavior).
        local onerr_var="_TPL_PARALLEL_ON_ERR_${safe}"
        local onerr="${!onerr_var:-continue}"
        case "$onerr" in
            continue|collect) : ;;
            *) error "parallel group '$gid': on_member_error must be continue|collect, got: $onerr"; return 1 ;;
        esac
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
    # ADR-039 (#1132): set of registered parallel group ids — a cycle's flow
    # member may name one; its LEAF members must fold under the enclosing
    # cycle unit (not a separate top-level "parallel:<gid>").
    local -A is_parallel=()
    local _pgid
    for _pgid in "${_TPL_PARALLEL_GROUPS[@]}"; do is_parallel[$_pgid]=1; done

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
            elif [[ -n "${is_parallel[$s]:-}" ]]; then
                # ADR-039 (#1132): map the group's leaf members to the enclosing
                # cycle so they absorb under "cycle:<id>". Without this the leaves
                # would map only to stage_to_parallel and emit a stray top-level
                # "parallel:<gid>" unit, double-dispatching the group.
                local _pg_safe="${s//-/_}"
                local _pg_flow_var="_TPL_PARALLEL_FLOW_${_pg_safe}"
                local _pg_csv="${!_pg_flow_var:-}"
                local _pg_ifs="$IFS"; IFS=','
                # shellcheck disable=SC2206
                local -a _pg_ms=($_pg_csv)
                IFS="$_pg_ifs"
                local _pgm
                for _pgm in "${_pg_ms[@]}"; do
                    [[ -z "$_pgm" ]] && continue
                    [[ -z "${stage_to_cycle[$_pgm]:-}" ]] && stage_to_cycle[$_pgm]="$cid"
                done
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

    # ADR-039 (#1130): map each leaf stage → its enclosing parallel group (if
    # any). A parallel group folds to one "parallel:<gid>" unit, symmetric to
    # "cycle:<id>". Validation guarantees members are disjoint from cycles, so a
    # stage is in at most one of {cycle, parallel}.
    local -A stage_to_parallel=()
    local pg
    for pg in "${_TPL_PARALLEL_GROUPS[@]}"; do
        local psafe="${pg//-/_}"
        local pflow_var="_TPL_PARALLEL_FLOW_${psafe}"
        local pflow_csv="${!pflow_var:-}"
        local p_IFS_save="$IFS"; IFS=','
        # shellcheck disable=SC2206
        local -a pms=($pflow_csv)
        IFS="$p_IFS_save"
        local pm
        for pm in "${pms[@]}"; do
            [[ -z "$pm" ]] && continue
            [[ -z "${stage_to_parallel[$pm]:-}" ]] && stage_to_parallel[$pm]="$pg"
        done
    done

    # issue #1295 (ADR-047 §2): build a set of map group ids for O(1) lookup.
    # Map groups appear IN _TPL_STAGES (as the group id itself, not as members)
    # and emit a "map:<gid>" dispatch unit rather than "stage:<gid>".
    local -A is_map_group=()
    local _mg
    for _mg in "${_TPL_MAP_GROUPS[@]}"; do is_map_group[$_mg]=1; done

    local s
    local -A emitted_outer=()
    local -A emitted_parallel=()
    for s in "${_TPL_STAGES[@]}"; do
        local in_cycle="${stage_to_cycle[$s]:-}"
        local in_parallel="${stage_to_parallel[$s]:-}"
        if [[ -n "$in_cycle" ]]; then
            local outer="${cycle_outermost[$in_cycle]:-$in_cycle}"
            if [[ -z "${emitted_outer[$outer]:-}" ]]; then
                _TPL_DISPATCH_UNITS+=("cycle:$outer")
                emitted_outer[$outer]=1
            fi
            # subsequent stages absorbed under the outermost cycle unit
        elif [[ -n "$in_parallel" ]]; then
            if [[ -z "${emitted_parallel[$in_parallel]:-}" ]]; then
                _TPL_DISPATCH_UNITS+=("parallel:$in_parallel")
                emitted_parallel[$in_parallel]=1
            fi
            # subsequent members absorbed under the same parallel unit
        elif [[ -n "${is_map_group[$s]:-}" ]]; then
            # issue #1295: map group id is itself in _TPL_STAGES; emit one map unit.
            _TPL_DISPATCH_UNITS+=("map:$s")
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
# ADR-029 (#1230): also validate router.retries (integer 0..10; 0 = opt-out).
# Uses Bash 5+ namerefs for safer array-by-name passing (no eval indirection).
_tpl_validate_io_knobs() {
    local -n ids_ref="$1"
    local -n tails_ref="$2"
    local -n redacts_ref="$3"
    local -n rtimeouts_ref="$4"
    local -n rmaxturns_ref="$5"
    local -n rmaxiters_ref="$6"
    local -n rretries_ref="$7"
    local i n=${#ids_ref[@]}
    for (( i=0; i<n; i++ )); do
        local stage="${ids_ref[$i]}"
        local tail="${tails_ref[$i]}"
        local redact="${redacts_ref[$i]}"
        local rt="${rtimeouts_ref[$i]}"
        local rmt="${rmaxturns_ref[$i]}"
        local rmi="${rmaxiters_ref[$i]}"
        local rre="${rretries_ref[$i]}"
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
        if [[ -n "$rre" ]]; then
            # ADR-029 (#1230): retries=0 is the explicit opt-out and valid.
            if ! [[ "$rre" =~ ^[0-9]+$ ]] || [[ "$rre" -gt 10 ]]; then
                error "template: router.retries for stage '$stage' must be integer in 0..10, got: $rre"
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
        # Template-level metadata keys (not stage sections). merge_policy is an
        # ADR-037 §4 per-template knob; reserving it stops the new-shape
        # translator from emitting it as a phantom stage definition (#968 review).
        return (k == "id" || k == "name" || k == "extends" || k == "defaults" \
                || k == "flow" || k == "_comment" || k == "merge_policy" \
                || k == "always_run")
    }
    BEGIN {
        in_flow = 0
        flow_n = 0
        # #1831: top-level `always_run:` — an ORDERED list of stage ids that run
        # on every exit path. Parsed exactly like `flow:`, and deliberately kept
        # out of it: an always-run stage is not part of the flow, so it must not
        # reach _TPL_STAGES[] (which drives dispatch units, canonical-order
        # validation and every test that pins a stage count).
        in_always_run = 0
        ar_n = 0
        cur_key = ""
        cur_indent_unit = 2
        # per-section accumulators
        sec_type = "leaf"
        sec_roles = ""; sec_strategy = ""; sec_io_dests = ""; sec_io_tail = ""
        sec_io_redact = ""; sec_rt = ""; sec_rmt = ""; sec_rmi = ""; sec_rre = ""; sec_blocking = ""
        # cycle accumulators
        cyc_flow = ""; cyc_max = ""; cyc_on_max = "continue"
        cyc_us = ""; cyc_uf = ""; cyc_uo = ""; cyc_uv = ""
        cyc_as = ""; cyc_af = ""; cyc_ao = ""; cyc_av = ""
        # #1217 (ADR-045): route_back predicate + target + per-edge cap.
        cyc_rb_to = ""; cyc_rb_stage = ""; cyc_rb_field = ""; cyc_rb_op = ""; cyc_rb_value = ""; cyc_rb_max = ""
        cyc_plateau = ""; cyc_diverg = ""; cyc_velopl = ""
        cyc_desc = ""
        cyc_expand = ""; cyc_autogrant = ""; cyc_escalate = ""; cyc_ondeny = ""
        # #1284 (ADR-047): multi-condition exit_when accumulators.
        cyc_ew_comb = ""; cyc_ew_n = 0; cyc_ew_cur_s = ""; cyc_ew_cur_f = ""; cyc_ew_cur_o = ""; cyc_ew_cur_v = ""
        delete cyc_ew_cond_s; delete cyc_ew_cond_f; delete cyc_ew_cond_o; delete cyc_ew_cond_v
        in_ew_cond = 0
        # ADR-039 (#1130): parallel-group accumulators.
        par_flow = ""; par_max = ""; par_onerr = "continue"; par_agg = ""; in_pflow = 0
        # issue #1295 (ADR-047 §2): map-group accumulators.
        map_over = ""; map_elements = ""; map_max = ""; map_onerr = "continue"; map_agg = ""; map_as = ""; in_map_elems = 0
        nfb = 0
        in_roles = 0; in_io_block = 0; in_io_dests = 0; in_router_block = 0
        in_cflow = 0; in_exit_when = 0; in_abort_when = 0; in_route_back = 0; in_rb_when = 0
        in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_fb_item = 0; in_scope_policy = 0
        fb_from_stage = ""; fb_from_output = ""; fb_to_stage = ""; fb_to_field = ""; fb_required = "false"
    }
    function reset_section(    i) {
        sec_type = "leaf"
        sec_roles = ""; sec_strategy = ""; sec_io_dests = ""; sec_io_tail = ""
        sec_io_redact = ""; sec_rt = ""; sec_rmt = ""; sec_rmi = ""; sec_rre = ""; sec_blocking = ""
        cyc_flow = ""; cyc_max = ""; cyc_on_max = "continue"
        cyc_us = ""; cyc_uf = ""; cyc_uo = ""; cyc_uv = ""
        cyc_as = ""; cyc_af = ""; cyc_ao = ""; cyc_av = ""
        # #1217 (ADR-045): route_back predicate + target + per-edge cap.
        cyc_rb_to = ""; cyc_rb_stage = ""; cyc_rb_field = ""; cyc_rb_op = ""; cyc_rb_value = ""; cyc_rb_max = ""
        cyc_plateau = ""; cyc_diverg = ""; cyc_velopl = ""
        cyc_desc = ""
        cyc_expand = ""; cyc_autogrant = ""; cyc_escalate = ""; cyc_ondeny = ""
        # #1284 (ADR-047): multi-condition exit_when accumulators.
        cyc_ew_comb = ""; cyc_ew_n = 0; cyc_ew_cur_s = ""; cyc_ew_cur_f = ""; cyc_ew_cur_o = ""; cyc_ew_cur_v = ""
        delete cyc_ew_cond_s; delete cyc_ew_cond_f; delete cyc_ew_cond_o; delete cyc_ew_cond_v
        in_ew_cond = 0
        # ADR-039 (#1130): parallel-group accumulators.
        par_flow = ""; par_max = ""; par_onerr = "continue"; par_agg = ""; in_pflow = 0
        # issue #1295 (ADR-047 §2): map-group accumulators.
        map_over = ""; map_elements = ""; map_max = ""; map_onerr = "continue"; map_agg = ""; map_as = ""; in_map_elems = 0
        nfb = 0
        in_roles = 0; in_io_block = 0; in_io_dests = 0; in_router_block = 0
        in_cflow = 0; in_exit_when = 0; in_abort_when = 0; in_route_back = 0; in_rb_when = 0
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
    # #1284 (ADR-047): flush in-flight multi-condition exit_when item.
    function flush_ew_cond() {
        if (in_ew_cond && cyc_ew_cur_s != "") {
            cyc_ew_n++
            cyc_ew_cond_s[cyc_ew_n] = cyc_ew_cur_s
            cyc_ew_cond_f[cyc_ew_n] = cyc_ew_cur_f
            cyc_ew_cond_o[cyc_ew_n] = cyc_ew_cur_o
            cyc_ew_cond_v[cyc_ew_n] = cyc_ew_cur_v
            cyc_ew_cur_s = ""; cyc_ew_cur_f = ""; cyc_ew_cur_o = ""; cyc_ew_cur_v = ""
            in_ew_cond = 0
        }
    }
    function flush_section(   k) {
        if (cur_key == "" || is_reserved(cur_key)) return
        # Finalize any in-flight feedback item now (Copilot P1).
        finalize_pending_fb()
        # #1284 (ADR-047): finalize in-flight multi-condition exit_when item.
        flush_ew_cond()
        # Always emit a defs-style row carrying the attr payload — downstream
        # code already merges this into stage_def_row[].
        defs_out = defs_out cur_key "|" sec_roles "|" sec_strategy "|" \
                   sec_io_dests "|" sec_io_tail "|" sec_io_redact "|" \
                   sec_rt "|" sec_rmt "|" sec_rmi "|" sec_rre "\n"
        # Stash per-key so we can also emit per-stage rows in flow order.
        sec_kind[cur_key] = sec_type
        sec_payload[cur_key] = sec_roles "|" sec_strategy "|" sec_io_dests "|" \
                               sec_io_tail "|" sec_io_redact "|" sec_rt "|" sec_rmt "|" sec_rmi "|" sec_rre
        # ADR-013 (CQ-3 / issue #863): stash blocking attribute for BL| row emission.
        sec_blocking_val[cur_key] = sec_blocking
        if (sec_type == "cycle") {
            cyc_data[cur_key] = cyc_flow "|" cyc_max "|" cyc_on_max "|" \
                                cyc_us "|" cyc_uf "|" cyc_uo "|" cyc_uv "|" \
                                cyc_plateau "|" cyc_diverg "|" cyc_velopl "|" cyc_desc "|" \
                                cyc_expand "|" cyc_autogrant "|" cyc_escalate "|" cyc_ondeny
            cyc_abort[cur_key] = cyc_as "|" cyc_af "|" cyc_ao "|" cyc_av
            # #1217 (ADR-045): only stash route_back when a target is declared,
            # so emit_cycle_dfs can guard the RB| row on presence (empty ⇒ inert).
            if (cyc_rb_to != "") {
                cyc_route_back[cur_key] = cyc_rb_to "|" cyc_rb_stage "|" cyc_rb_field "|" cyc_rb_op "|" cyc_rb_value "|" cyc_rb_max
            }
            cyc_fb_count[cur_key] = nfb
            for (k = 1; k <= nfb; k++) {
                cyc_fb[cur_key, k] = fb[k]
            }
            # #1284 (ADR-047): stash multi-condition exit_when data.
            if (cyc_ew_comb != "" && cyc_ew_n > 0) {
                cyc_ew_combinator[cur_key] = cyc_ew_comb
                cyc_ew_count[cur_key] = cyc_ew_n
                for (k = 1; k <= cyc_ew_n; k++) {
                    cyc_ew_s[cur_key, k] = cyc_ew_cond_s[k]
                    cyc_ew_f[cur_key, k] = cyc_ew_cond_f[k]
                    cyc_ew_o[cur_key, k] = cyc_ew_cond_o[k]
                    cyc_ew_v[cur_key, k] = cyc_ew_cond_v[k]
                }
            }
        }
        # ADR-039 (#1130): stash parallel-group data for IP| emission.
        # Phase 1 (ADR-040 §3): par_agg carries the `aggregate:` declaration so the
        # loader can export _TPL_PARALLEL_AGGREGATE_<id> (preflight reads it to bind
        # the group to its typed aggregator). Always 4 fields; empty when omitted.
        if (sec_type == "parallel") {
            par_data[cur_key] = par_flow "|" par_max "|" par_onerr "|" par_agg
        }
        # issue #1295 (ADR-047 §2): stash map-group data for IM| emission.
        # map_data carries: over|elements_csv|max|onerr|agg|as — the loader wires
        # these into _TPL_MAP_* vars and the runner dispatches via _strategy_run_map.
        # (The full IM| row prepends <gid> and appends the shared sec_payload —
        # roles|io_dests|io_tail|router…; see the IM| print site for the schema.)
        if (sec_type == "map") {
            map_data[cur_key] = map_over "|" map_elements "|" map_max "|" map_onerr "|" map_agg "|" map_as
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

    # ── Top-level always_run: list (#1831) ────────────────────────────────────
    # Same two forms `flow:` accepts, for the same reason: a template author
    # should not have to remember which top-level list takes which syntax.
    /^always_run:[[:space:]]*$/ {
        flush_section(); reset_section(); cur_key = ""
        in_flow = 0; in_always_run = 1; next
    }
    /^always_run:[[:space:]]*\[/ {
        flush_section(); reset_section(); cur_key = ""
        line = $0
        sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
        gsub(/[[:space:]]/, "", line)
        n = split(line, items, /,/)
        for (i = 1; i <= n; i++) {
            if (items[i] != "") { ar_n++; ar[ar_n] = items[i] }
        }
        in_always_run = 0
        next
    }
    in_always_run && /^[[:space:]]+-[[:space:]]/ {
        item = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", item); item = trim(item)
        if (item != "") { ar_n++; ar[ar_n] = item }
        next
    }
    # Top-level non-indented line — end any current scope.
    /^[a-zA-Z_]/ {
        in_flow = 0
        in_always_run = 0
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
        # ADR-039 (#1130): parallel group discriminator (sibling of cycle).
        if ($0 ~ /^[[:space:]]+type:[[:space:]]*parallel[[:space:]]*$/) {
            sec_type = "parallel"; next
        }
        # issue #1295 (ADR-047 §2): map group discriminator.
        if ($0 ~ /^[[:space:]]+type:[[:space:]]*map[[:space:]]*$/) {
            sec_type = "map"; next
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
        if (in_router_block && $0 ~ /^[[:space:]]+retries:/) {
            v = $0; sub(/^[[:space:]]+retries:[[:space:]]*/, "", v); sec_rre = trim(v); next
        }
        # blocking: (ADR-013 / CQ-3 #863) — leaf stage attribute; ignored for cycles.
        if ($0 ~ /^[[:space:]]+blocking:/) {
            v = $0; sub(/^[[:space:]]+blocking:[[:space:]]*/, "", v); sec_blocking = trim(v); next
        }

        # ── cycle-only ─────────────────────────────────────────────────────────
        if (sec_type == "cycle") {
            if ($0 ~ /^[[:space:]]+flow:/) {
                in_cflow = 0
                if ($0 ~ /\[/) {
                    cyc_flow = strip_inline_list($0); in_cflow = 0
                } else { in_cflow = 1 }
                in_exit_when = 0; in_abort_when = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_route_back = 0; in_rb_when = 0
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
                in_scope_policy = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_feedback = 0; in_route_back = 0; in_rb_when = 0; next
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
                in_plateau = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; in_route_back = 0; in_rb_when = 0; next
            }
            if (in_plateau && $0 ~ /^[[:space:]]+window:/) {
                v = $0; sub(/^[[:space:]]+window:[[:space:]]*/, "", v); cyc_plateau = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+divergence:[[:space:]]*$/) {
                in_diverg = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_plateau = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; in_route_back = 0; in_rb_when = 0; next
            }
            if (in_diverg && $0 ~ /^[[:space:]]+window:/) {
                v = $0; sub(/^[[:space:]]+window:[[:space:]]*/, "", v); cyc_diverg = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+velocity_plateau:[[:space:]]*$/) {
                in_velopl = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_plateau = 0; in_diverg = 0; in_feedback = 0; in_scope_policy = 0; in_route_back = 0; in_rb_when = 0; next
            }
            if (in_velopl && $0 ~ /^[[:space:]]+window:/) {
                v = $0; sub(/^[[:space:]]+window:[[:space:]]*/, "", v); cyc_velopl = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+exit_when:[[:space:]]*$/) {
                in_exit_when = 1; in_abort_when = 0; in_cflow = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; in_route_back = 0; in_rb_when = 0; next
            }
            if ($0 ~ /^[[:space:]]+abort_when:[[:space:]]*$/) {
                in_abort_when = 1; in_exit_when = 0; in_cflow = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; in_route_back = 0; in_rb_when = 0; next
            }
            # #1217 (ADR-045): route_back — sibling of exit_when/abort_when.
            # Cycle-level backward-route target + predicate + per-edge cap. The
            # predicate lives under a nested `when:` block (in_rb_when).
            if ($0 ~ /^[[:space:]]+route_back:[[:space:]]*$/) {
                in_route_back = 1; in_rb_when = 0
                in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_feedback = 0; in_scope_policy = 0; next
            }
            if (in_route_back && $0 ~ /^[[:space:]]+to:/) {
                v = $0; sub(/^[[:space:]]+to:[[:space:]]*/, "", v); cyc_rb_to = trim(v); next
            }
            if (in_route_back && $0 ~ /^[[:space:]]+when:[[:space:]]*$/) {
                in_rb_when = 1; next
            }
            if (in_route_back && $0 ~ /^[[:space:]]+max:[[:space:]]*/) {
                v = $0; sub(/^[[:space:]]+max:[[:space:]]*/, "", v); cyc_rb_max = trim(v); in_rb_when = 0; next
            }
            if (in_rb_when && $0 ~ /^[[:space:]]+stage:/) {
                v = $0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v); cyc_rb_stage = trim(v); next
            }
            if (in_rb_when && $0 ~ /^[[:space:]]+field:/) {
                v = $0; sub(/^[[:space:]]+field:[[:space:]]*/, "", v); cyc_rb_field = trim(v); next
            }
            if (in_rb_when && $0 ~ /^[[:space:]]+op:/) {
                v = $0; sub(/^[[:space:]]+op:[[:space:]]*/, "", v); cyc_rb_op = trim(v); next
            }
            if (in_rb_when && $0 ~ /^[[:space:]]+value:/) {
                v = $0; sub(/^[[:space:]]+value:[[:space:]]*/, "", v); cyc_rb_value = trim(v); next
            }
            # #1284 (ADR-047): single-condition handlers must NOT fire once an
            # all:/any: combinator has been seen (cyc_ew_comb != ""), otherwise a
            # a block-form condition field:/op:/value: continuation line would be
            # consumed here — corrupting cyc_uf/cyc_uo/cyc_uv and losing the row.
            if (in_exit_when && cyc_ew_comb == "" && $0 ~ /^[[:space:]]+stage:/) {
                v = $0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v); cyc_us = trim(v); next
            }
            if (in_exit_when && cyc_ew_comb == "" && $0 ~ /^[[:space:]]+field:/) {
                v = $0; sub(/^[[:space:]]+field:[[:space:]]*/, "", v); cyc_uf = trim(v); next
            }
            if (in_exit_when && cyc_ew_comb == "" && $0 ~ /^[[:space:]]+op:/) {
                v = $0; sub(/^[[:space:]]+op:[[:space:]]*/, "", v); cyc_uo = trim(v); next
            }
            if (in_exit_when && cyc_ew_comb == "" && $0 ~ /^[[:space:]]+value:/) {
                v = $0; sub(/^[[:space:]]+value:[[:space:]]*/, "", v); cyc_uv = trim(v); next
            }
            # #1284 (ADR-047): multi-condition exit_when — combinator line.
            if (in_exit_when && $0 ~ /^[[:space:]]+(all|any):[[:space:]]*$/) {
                v = $0; sub(/^[[:space:]]+/, "", v); sub(/:[[:space:]]*$/, "", v)
                cyc_ew_comb = v; in_ew_cond = 0; next
            }
            # Inline list item: - { stage: X, field: Y, op: Z, value: W }
            if (in_exit_when && cyc_ew_comb != "" && $0 ~ /^[[:space:]]+-[[:space:]]*\{/) {
                flush_ew_cond()
                line = $0; sub(/^[[:space:]]+-[[:space:]]*\{?/, "", line); sub(/\}.*$/, "", line)
                n = split(line, kv, /,[[:space:]]*/)
                for (i = 1; i <= n; i++) {
                    split(kv[i], pair, /:[[:space:]]*/); key = trim(pair[1]); val = trim(pair[2])
                    if (key == "stage") cyc_ew_cur_s = val
                    if (key == "field") cyc_ew_cur_f = val
                    if (key == "op")    cyc_ew_cur_o = val
                    if (key == "value") cyc_ew_cur_v = val
                }
                in_ew_cond = 1; next
            }
            # Block-form list item: `- stage: X` (next line after `- `)
            if (in_exit_when && cyc_ew_comb != "" && $0 ~ /^[[:space:]]+-[[:space:]]+stage:/) {
                flush_ew_cond()
                v = $0; sub(/^[[:space:]]+-[[:space:]]+stage:[[:space:]]*/, "", v); cyc_ew_cur_s = trim(v)
                in_ew_cond = 1; next
            }
            # Continuation fields within a block-form condition item.
            if (in_exit_when && in_ew_cond && $0 ~ /^[[:space:]]+stage:/) {
                v = $0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v); cyc_ew_cur_s = trim(v); next
            }
            if (in_exit_when && in_ew_cond && $0 ~ /^[[:space:]]+field:/) {
                v = $0; sub(/^[[:space:]]+field:[[:space:]]*/, "", v); cyc_ew_cur_f = trim(v); next
            }
            if (in_exit_when && in_ew_cond && $0 ~ /^[[:space:]]+op:/) {
                v = $0; sub(/^[[:space:]]+op:[[:space:]]*/, "", v); cyc_ew_cur_o = trim(v); next
            }
            if (in_exit_when && in_ew_cond && $0 ~ /^[[:space:]]+value:/) {
                v = $0; sub(/^[[:space:]]+value:[[:space:]]*/, "", v); cyc_ew_cur_v = trim(v); next
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
                in_feedback = 1; in_exit_when = 0; in_abort_when = 0; in_cflow = 0; in_plateau = 0; in_diverg = 0; in_velopl = 0; in_route_back = 0; in_rb_when = 0; next
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

        # ── parallel-only (ADR-039 #1130) ────────────────────────────────────
        # Generalizes the cycle nested-`flow:` parser to the parallel group:
        # members come from a nested `flow:` list; max_parallel / on_member_error
        # are the only other knobs.
        if (sec_type == "parallel") {
            if ($0 ~ /^[[:space:]]+flow:/) {
                in_pflow = 0
                if ($0 ~ /\[/) {
                    par_flow = strip_inline_list($0); in_pflow = 0
                } else { in_pflow = 1 }
                next
            }
            if (in_pflow && $0 ~ /^[[:space:]]+-[[:space:]]/) {
                item = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", item); item = trim(item)
                if (item != "") par_flow = (par_flow == "" ? item : par_flow "," item)
                next
            }
            if (in_pflow && $0 ~ /^[[:space:]]+[a-z_]+:/) { in_pflow = 0 }
            if ($0 ~ /^[[:space:]]+max_parallel:/) {
                v = $0; sub(/^[[:space:]]+max_parallel:[[:space:]]*/, "", v); par_max = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+on_member_error:/) {
                v = $0; sub(/^[[:space:]]+on_member_error:[[:space:]]*/, "", v); par_onerr = trim(v); next
            }
            # Phase 1 (ADR-040 §3 / ADR-039): the group typed-aggregator binding.
            if ($0 ~ /^[[:space:]]+aggregate:/) {
                v = $0; sub(/^[[:space:]]+aggregate:[[:space:]]*/, "", v); par_agg = trim(v); next
            }
        }

        # ── map-only (issue #1295, ADR-047 §2) ───────────────────────────────
        # `type: map` group: over: <dim>, elements: [e1, e2, ...], roles:, io:,
        # router:, max_parallel:, on_member_error:, aggregate:. The roles/io/router
        # knobs are shared by all elements and live in the standard sec_* fields.
        if (sec_type == "map") {
            if ($0 ~ /^[[:space:]]+over:/) {
                v = $0; sub(/^[[:space:]]+over:[[:space:]]*/, "", v); map_over = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+elements:/) {
                in_map_elems = 0
                if ($0 ~ /\[/) {
                    map_elements = strip_inline_list($0); in_map_elems = 0
                } else { in_map_elems = 1 }
                next
            }
            if (in_map_elems && $0 ~ /^[[:space:]]+-[[:space:]]/) {
                item = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", item); item = trim(item)
                if (item != "") map_elements = (map_elements == "" ? item : map_elements "," item)
                next
            }
            if (in_map_elems && $0 ~ /^[[:space:]]+[a-z_]+:/) { in_map_elems = 0 }
            if ($0 ~ /^[[:space:]]+max_parallel:/) {
                v = $0; sub(/^[[:space:]]+max_parallel:[[:space:]]*/, "", v); map_max = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+on_member_error:/) {
                v = $0; sub(/^[[:space:]]+on_member_error:[[:space:]]*/, "", v); map_onerr = trim(v); next
            }
            if ($0 ~ /^[[:space:]]+aggregate:/) {
                v = $0; sub(/^[[:space:]]+aggregate:[[:space:]]*/, "", v); map_agg = trim(v); next
            }
            # issue #1295 (ADR-047 §2): `as:` names an env var to receive the
            # current element per work unit — a generic dimension→env mapping.
            # The strategy stays element-name-agnostic; the template names the var.
            if ($0 ~ /^[[:space:]]+as:/) {
                v = $0; sub(/^[[:space:]]+as:[[:space:]]*/, "", v); map_as = trim(v); next
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
            } else if (kind == "parallel") {
                # ADR-039 (#1130): one IP| row at the group flow position.
                # Members are leaves declared as their own top-level sections;
                # the loader expands them from the defs stream (like cycles).
                print "IP|" k "|" par_data[k]
            } else if (kind == "map") {
                # issue #1295 (ADR-047 §2): one IM| row at the group flow position.
                # Format: <gid>|<over>|<elements_csv>|<max>|<onerr>|<agg>|<as>|<roles>|<strategy>|<io_dests>|<io_tail>|<io_redact>|<rt>|<rmt>|<rmi>|<rre>
                # roles/strategy/io/router come from sec_payload (shared across all elements).
                # #1312: added strategy, io_redact, router_max_iterations (rmi), router_retries (rre).
                print "IM|" k "|" map_data[k] "|" sec_payload[k]
            } else {
                p = sec_payload[k]
                print "S|" k "|" p
            }
        }
        # ADR-013 (CQ-3 / issue #863): BL| rows for blocking leaf stages.
        for (k in sec_blocking_val) {
            if (sec_blocking_val[k] == "true") print "BL|" k "|true"
        }
        # #1831: one AR| row carrying the ordered always-run list as CSV. Emitted
        # even when empty is pointless, so it is emitted only when non-empty —
        # a template with no always-run stages produces no row, and the loader
        # leaves _TPL_ALWAYS_RUN[] empty.
        if (ar_n > 0) {
            ar_csv = ar[1]
            for (i = 2; i <= ar_n; i++) ar_csv = ar_csv "," ar[i]
            print "AR|" ar_csv
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
            if (sec_kind[m] == "cycle") {
                emit_cycle_dfs(m)
            } else if (sec_kind[m] == "parallel" && !emitted[m]) {
                # ADR-039 (#1132): a parallel-group cycle member must be
                # registered (IP| row) BEFORE the enclosing cycle IC| row so the
                # loader cycle expander sees _TPL_PARALLEL_GROUPS populated and
                # recurses into the group members. Guarded by emitted[] (same as
                # cycles) so a group never double-emits.
                emitted[m] = 1
                print "IP|" m "|" par_data[m]
            }
        }
        d = cyc_data[k]
        print "IC|" k "|" d
        cnt = cyc_fb_count[k] + 0
        for (j = 1; j <= cnt; j++) print "FB|" k "|" cyc_fb[k, j]
        aw = cyc_abort[k]
        if (aw != "" && aw != "|||") print "AW|" k "|" aw
        # #1217 (ADR-045): route_back row (guarded on target presence).
        rb = cyc_route_back[k]
        if (rb != "") print "RB|" k "|" rb
        # #1284 (ADR-047): multi-condition exit_when row.
        if (cyc_ew_combinator[k] != "" && cyc_ew_count[k] + 0 > 0) {
            ew_row = k "|" cyc_ew_combinator[k] "|" cyc_ew_count[k]
            for (j = 1; j <= cyc_ew_count[k]; j++) {
                ew_row = ew_row "|" cyc_ew_s[k, j] "|" cyc_ew_f[k, j] "|" cyc_ew_o[k, j] "|" cyc_ew_v[k, j]
            }
            print "EW|" ew_row
        }
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

# _tpl_resolve_unit_index <to> — echo the index of <to> in _TPL_DISPATCH_UNITS,
# by direct unit id (stripping stage:/cycle:/parallel:) first, then by cycle/
# parallel MEMBERSHIP. Echo -1 if unresolved. Mirrors the runner's
# _runner_resolve_unit_index so load-time validation and run-time rewind agree.
_tpl_resolve_unit_index() {
    local _to="$1" _i _u _uid
    for (( _i = 0; _i < ${#_TPL_DISPATCH_UNITS[@]}; _i++ )); do
        _u="${_TPL_DISPATCH_UNITS[_i]}"; _uid="${_u#*:}"
        [[ "$_uid" == "$_to" ]] && { echo "$_i"; return 0; }
    done
    for (( _i = 0; _i < ${#_TPL_DISPATCH_UNITS[@]}; _i++ )); do
        _u="${_TPL_DISPATCH_UNITS[_i]}"; _uid="${_u#*:}"
        local _safe="${_uid//-/_}"
        case "$_u" in
            cycle:*)
                local _mv="_TPL_CYCLE_STAGES_${_safe}"
                [[ ",${!_mv:-}," == *",$_to,"* ]] && { echo "$_i"; return 0; } ;;
            parallel:*)
                local _pv="_TPL_PARALLEL_FLOW_${_safe}"
                [[ ",${!_pv:-}," == *",$_to,"* ]] && { echo "$_i"; return 0; } ;;
        esac
    done
    echo "-1"
    return 0
}

# _tpl_validate_route_back — #1217 (ADR-045) acyclicity carve-out. For every
# cycle declaring a route_back target: (a) `to` MUST resolve to a dispatch unit
# STRICTLY earlier than the cycle (reject forward/self — an unbounded loop);
# (b) `max` MUST be a finite positive int (reject empty/0/non-numeric). The
# backward edge is PERMITTED precisely because it is budget-bounded — it lives
# in a separate var, never in membership flow, so _tpl_validate_flow_acyclic is
# unchanged.
_tpl_validate_route_back() {
    [[ ${#_TPL_CYCLES[@]} -eq 0 ]] && return 0
    local cid safe to op max cyc_idx to_idx
    for cid in "${_TPL_CYCLES[@]}"; do
        safe="${cid//-/_}"
        local to_var="_TPL_CYCLE_ROUTE_BACK_TO_${safe}"
        to="${!to_var:-}"
        [[ -z "$to" ]] && continue
        # #1225 (ADR-045): route_back is supported on a NESTED cycle too — its
        # rc=11 now bubbles outward through every enclosing cycle's main loop to
        # the runner (#1225 cycle-orchestrator fix), so the load-time
        # top-level-only rejection from #1217 is lifted. The strictly-earlier
        # check below is the sole guard: _tpl_resolve_unit_index resolves BOTH a
        # nested cid and its `to` target by MEMBERSHIP to their enclosing
        # TOP-LEVEL dispatch-unit index, so `to_idx < cyc_idx` constrains a nested
        # route_back's target to a top-level unit strictly BEFORE the enclosing
        # top-level cycle (the only thing the runner can rewind) and auto-rejects
        # a sibling-member / self target (both resolve to the SAME enclosing
        # top-level index → not strictly-earlier).
        # #1217 review fix (NIT): reject an unsupported predicate op at load —
        # the orchestrator's route_back evaluator only implements eq/ne (mirrors
        # exit_when/abort_when); any other op would silently never match.
        local op_var="_TPL_CYCLE_ROUTE_BACK_OP_${safe}"
        op="${!op_var:-}"
        case "$op" in
            eq|ne) ;;
            *) error "load_template: cycle '$cid' route_back.when.op='${op:-<empty>}' is unsupported (only 'eq' and 'ne' are implemented, ADR-045)"
               return 1 ;;
        esac
        local max_var="_TPL_CYCLE_ROUTE_BACK_MAX_${safe}"
        max="${!max_var:-}"
        if ! [[ "$max" =~ ^[1-9][0-9]*$ ]]; then
            error "load_template: cycle '$cid' route_back.max must be a finite positive integer (got '${max:-<empty>}') — an unbounded backward-route is forbidden (ADR-045)"
            return 1
        fi
        cyc_idx="$(_tpl_resolve_unit_index "$cid")"
        to_idx="$(_tpl_resolve_unit_index "$to")"
        if [[ "$to_idx" -lt 0 ]]; then
            error "load_template: cycle '$cid' route_back.to='$to' does not resolve to any declared dispatch unit / stage"
            return 1
        fi
        if [[ "$to_idx" -ge "$cyc_idx" ]]; then
            error "load_template: cycle '$cid' route_back.to='$to' must be a STRICTLY EARLIER unit (forward/self route_back forbidden — would be an unbounded loop, ADR-045)"
            return 1
        fi
    done
    return 0
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

# ADR-029 (#1230): per-stage router.retries (empty when unset → caller default 0).
# Consumer chokepoint: _route_resolve_retries in core/router/route.sh applies the
# precedence rule (per-stage > env > compile-time default 0). Honored by BOTH the
# single-shot (_route_call_claude) and the agentic-loop (route_to_model_loop) leaf
# paths, so every leaf node respects it wherever it sits.
template_stage_router_retries() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_ROUTER_RETRIES_${safe_id}"
    echo "${!var:-}"
}

# ADR-013 (CQ-3 / issue #863): per-stage blocking attribute (true/empty).
# Returns "true" when stage is a blocking cycle member; empty otherwise.
template_stage_blocking() {
    local stage_id="$1"
    local safe_id="${stage_id//-/_}"
    local var="_TPL_STAGE_BLOCKING_${safe_id}"
    echo "${!var:-}"
}

# ADR-037 §4: resolved merge_policy for the loaded template.
# Returns one of: auto_unless_flagged | auto | manual
template_merge_policy() {
    echo "${_TPL_MERGE_POLICY:-auto_unless_flagged}"
}

# ADR-036 #1188: per-stage `negctl_timeout_s:` knob (mechanical acceptance-gate).
# Read lazily from the loaded template source so it needs no row-shape change.
# Empty when unset → the acceptance-gate plugin applies its 60s default. Matches
# a scalar `negctl_timeout_s:` line directly under the `<stage_id>:` section of a
# new-shape template (top-level per-stage sections).
template_stage_negctl_timeout() {
    local stage_id="$1"
    [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]] || return 0
    awk -v stage="$stage_id" '
        function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
        $0 ~ "^"stage":[[:space:]]*$" { in_block = 1; block_ind = 0; in_defs = 0; next }
        /^stage_definitions:[[:space:]]*$/ { in_defs = 1; next }
        in_defs && /^[a-zA-Z_]/ { in_defs = 0 }
        in_defs && !in_block && $0 ~ "^  "stage":[[:space:]]*$" { in_block = 1; block_ind = 2; next }
        in_block {
            ind = indent($0)
            if ($0 ~ /[^[:space:]]/ && ind <= block_ind) { in_block = 0 }
        }
        in_block && $0 ~ "^[[:space:]]+negctl_timeout_s:" {
            sub(/^[[:space:]]+negctl_timeout_s:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, ""); gsub(/[[:space:]]/, "")
            print; exit
        }
    ' "${_TPL_SOURCE_FILE}" 2>/dev/null
}

# ADR-017 §8 (#1252): per-stage `router.tier` OVERRIDE — pins a tier ORDINAL
# (T0-T4, ADR-003; never a model name) for one stage. Read LAZILY from the loaded
# template source (like template_stage_negctl_timeout), so it needs NO row-shape /
# parser-array change. Feeds resolve_tier BETWEEN the env override and the
# manifest config.tier_default:
#   env ZBUILD_<ID>_TIER  >  template router.tier  >  manifest config.tier_default.
# Matches the stage in BOTH template shapes — a top-level `<stage>:` section and
# an inline `- id: <stage>` list item — then descends into that stage's `router:`
# sub-block to read `tier:`. Validates ^T[0-4]$ at READ time (fail-loud on a bad
# value, e.g. T9 or a model name); prints nothing when unset.
template_stage_router_tier() {
    local stage_id="$1"
    [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]] || return 0
    local tier
    tier="$(awk -v stage="$stage_id" '
        function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
        # Shape 1: top-level `<stage>:` section (new-shape).
        $0 ~ "^"stage":[[:space:]]*$" { in_stage = 1; stage_ind = 0; in_router = 0; in_defs = 0; next }
        # Shape 2: inline `- id: <stage>` list item.
        $0 ~ "^[[:space:]]*-[[:space:]]+id:[[:space:]]*"stage"[[:space:]]*$" {
            in_stage = 1; stage_ind = indent($0); in_router = 0; in_defs = 0; next
        }
        # Shape 3: stage_definitions sub-entry (old-shape templates).
        /^stage_definitions:[[:space:]]*$/ { in_defs = 1; next }
        in_defs && /^[a-zA-Z_]/ { in_defs = 0 }
        in_defs && !in_stage && $0 ~ "^  "stage":[[:space:]]*$" {
            in_stage = 1; stage_ind = 2; in_router = 0; next
        }
        in_stage {
            ind = indent($0)
            # A line at or below the stage-key indent (that is not blank) ends the block.
            if ($0 ~ /[^[:space:]]/ && ind <= stage_ind && $0 !~ "^"stage":") {
                # For the list-item shape the next `- id:` or a shallower key closes it.
                if (ind <= stage_ind) { in_stage = 0; in_router = 0 }
            }
        }
        in_stage && $0 ~ "^[[:space:]]+router:[[:space:]]*$" { in_router = 1; router_ind = indent($0); next }
        in_router {
            ind = indent($0)
            if ($0 ~ /[^[:space:]]/ && ind <= router_ind) { in_router = 0 }
        }
        in_router && $0 ~ "^[[:space:]]+tier:" {
            sub(/^[[:space:]]+tier:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, ""); gsub(/[[:space:]]/, "")
            print; exit
        }
    ' "${_TPL_SOURCE_FILE}" 2>/dev/null)"
    [[ -z "$tier" ]] && return 0
    if [[ ! "$tier" =~ ^T[0-4]$ ]]; then
        error "template_stage_router_tier: invalid router.tier '$tier' for stage '$stage_id' — must be a tier ordinal T0-T4 (ADR-003: not a model name)"
        return 1
    fi
    printf '%s\n' "$tier"
    return 0
}

# ADR-051 §4 (#1305): per-stage `persona:` binding — read LAZILY from
# _TPL_SOURCE_FILE. Mirrors template_stage_router_tier but reads the `persona:`
# scalar directly under the stage block (not nested under `router:`). Supports
# all three template shapes (top-level section, inline list item, stage_definitions
# sub-entry). Returns empty when unset; no validation (persona id is opaque).
template_stage_router_persona() {
    local stage_id="$1"
    [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]] || return 0
    awk -v stage="$stage_id" '
        function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
        $0 ~ "^"stage":[[:space:]]*$" { in_block = 1; block_ind = 0; in_defs = 0; next }
        $0 ~ "^[[:space:]]*-[[:space:]]+id:[[:space:]]*"stage"[[:space:]]*$" {
            in_block = 1; block_ind = indent($0); in_defs = 0; next
        }
        /^stage_definitions:[[:space:]]*$/ { in_defs = 1; next }
        in_defs && /^[a-zA-Z_]/ { in_defs = 0 }
        in_defs && !in_block && $0 ~ "^  "stage":[[:space:]]*$" {
            in_block = 1; block_ind = 2; in_defs = 0; next
        }
        in_block {
            ind = indent($0)
            if ($0 ~ /[^[:space:]]/ && ind <= block_ind && $0 !~ "^"stage":") {
                in_block = 0
            }
        }
        in_block && $0 ~ "^[[:space:]]+persona:[[:space:]]" {
            sub(/^[[:space:]]+persona:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, ""); gsub(/[[:space:]]/, "")
            print; exit
        }
    ' "${_TPL_SOURCE_FILE}" 2>/dev/null
}

# ADR-051 §4 (#1305): top-level `config.persona` — global template default
# persona id. Read LAZILY from _TPL_SOURCE_FILE. Returns empty when unset.
# ADR-023 / #888: top-level `config.worktree_root` — where per-run worktrees live.
# Same shape as template_config_persona; env ZBUILD_WORKTREE_ROOT overrides it.
template_config_worktree_root() {
    [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]] || return 0
    awk '
        /^config:[[:space:]]*$/ { in_config = 1; next }
        in_config && /^[a-zA-Z_]/ { in_config = 0 }
        in_config && /^[[:space:]]+worktree_root:[[:space:]]/ {
            sub(/^[[:space:]]+worktree_root:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, ""); gsub(/^["'"'"']|["'"'"']$/, "")
            print; exit
        }
    ' "${_TPL_SOURCE_FILE}" 2>/dev/null
}

template_config_persona() {
    [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]] || return 0
    awk '
        /^config:[[:space:]]*$/ { in_config = 1; next }
        in_config && /^[a-zA-Z_]/ { in_config = 0 }
        in_config && /^[[:space:]]+persona:[[:space:]]/ {
            sub(/^[[:space:]]+persona:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, ""); gsub(/[[:space:]]/, "")
            print; exit
        }
    ' "${_TPL_SOURCE_FILE}" 2>/dev/null
}
