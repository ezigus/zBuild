#!/usr/bin/env bash
# core/pipeline/strategies/map-summary.sh — a map group summed up after it ran
# (#2368, #1753, #2611, ADR-040): each element's outcome, the elements that did
# not pass or halt the run, and the group's verdict. Moved from map.sh (#2611).
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_MAP_SUMMARY_LOADED:-}" ]] && return 0
_ZBUILD_MAP_SUMMARY_LOADED=1

# _map_write_summary <stage> <state_file> <env_target> <dimension> <n> <plugin_dir…> <element…>
# #2368: the engine sums up a map group — every element, its outcome and its
# one-line reason, read from the element's own primary result — into
# artifacts/<stage>-summary.md, and tells later stages whether any element
# failed or did not finish (_ZB_MAP_NOT_PASSED). Fail-open: a diagnostic never fails the group.
# Its first line says whether every element finished — a pass or a fail is a
# finish; anything else (timed_out, an error, no result) is not — and
# _ZB_MAP_UNFINISHED keeps that line for the runner when one did not, and
# _ZB_MAP_NOT_PASSED names every member that did not pass, for the run's stop
# message (#1753), and _ZB_MAP_HALTED each whose result halts the run (#2611,
# ADR-054 §6: rate_limited, unavailable, misconfigured, broken), with its reason.
# A member the group's wait stopped (_ZB_MAP_WAIT_TIMED_OUT), or the stage's own
# limit (its marker), and that recorded only a signal or nothing, is timed_out.
# Each member's row on the status comment is closed with its own outcome and
# what it reported (parallel.member.dispatch.complete under its seq).
_map_write_summary() {
    local stage="$1" state_file="$2" env_target="$3" dimension="$4" n="$5"; shift 5
    local -a plugins=("${@:1:$n}") elems=("${@:$((n + 1)):$n}")
    local state_dir art i raw res line body="" outcome reason sum
    local -a unfinished=() notpassed=() halted=()
    local _resp _tl_hit=0
    _ZB_MAP_UNFINISHED=""; _ZB_MAP_NOT_PASSED=""; _ZB_MAP_HALTED=""
    declare -F disposition_response_v >/dev/null 2>&1 \
        || source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd ".." && pwd)/disposition.sh" 2>/dev/null || true
    state_dir="$(dirname "$state_file")"; art="${ZBUILD_ARTIFACT_DIR:-$state_dir/artifacts}"
    # #2611 (ADR-063): stopped by the group's wait, or by the element's own limit.
    [[ -n "${_ZB_MAP_WAIT_TIMED_OUT:-}" ]] && _tl_hit=1
    declare -F stage_time_limit_marker_path_v >/dev/null 2>&1 \
        || source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../../../scripts/lib" && pwd)/stage-time-limit.sh" 2>/dev/null || true
    local _el_tl _el_mk
    declare -F _registry_output_path_rows >/dev/null 2>&1 \
        || source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../../plugin-registry" && pwd)/output-paths.sh" 2>/dev/null || true
    declare -F manifest_graph_get_outputs >/dev/null 2>&1 \
        || source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../../../scripts/lib" && pwd)/manifest-graph.sh" 2>/dev/null || true
    for (( i = 0; i < n; i++ )); do
        # Captured whole, then read here (no early-exiting reader on a pipe: CLAUDE.md).
        local _rows _rp _rpr; _rows="$(_registry_output_path_rows "${plugins[$i]}/manifest.yaml" 2>/dev/null)" || true
        raw=""
        while IFS=$'\t' read -r _rp _rpr _; do [[ "$_rpr" == true ]] && { raw="$_rp"; break; }; done <<< "$_rows"
        res="$(_map_member_path "$raw" "$env_target" "${elems[$i]}" "$state_dir" "$art")"
        outcome="missing"; reason=""
        if [[ -n "$res" && -s "$res" ]]; then
            outcome="$(jq -r '.outcome // "missing"' "$res" 2>/dev/null || echo missing)"
            reason="$(jq -r '(.reason // "") | gsub("[\r\n]+"; " ")' "$res" 2>/dev/null || true)"
        fi
        _el_tl=0
        stage_time_limit_marker_path_v _el_mk "$state_file" "$stage" "${elems[$i]}"
        [[ -f "$_el_mk" ]] && _el_tl=1
        if (( _tl_hit || _el_tl )) && [[ "$outcome" == interrupted || "$outcome" == missing ]]; then
            if (( _el_tl )); then reason="its stage time limit stopped it${reason:+ ($reason)}"
            else reason="the group's wait for its members ran out${reason:+ ($reason)}"; fi
            outcome=timed_out
        fi
        [[ "$outcome" != pass ]] && notpassed+=("${elems[$i]} (${outcome})")
        disposition_response_v _resp "$outcome" 2>/dev/null || _resp=""
        [[ "$_resp" == halt_* ]] && halted+=("${elems[$i]} (${outcome})${reason:+: $reason}")
        [[ "$outcome" == pass || "$outcome" == fail ]] || unfinished+=("${elems[$i]} (${outcome})")
        line="- ${elems[$i]}: $outcome${reason:+ — $reason}"
        body+="$line"$'\n'
        if [[ -n "${ZBUILD_SEQ_PREFIX:-}" ]]; then
            sum="$(_map_member_path "$(_map_summary_raw "${plugins[$i]}/manifest.yaml")" \
                "$env_target" "${elems[$i]}" "$state_dir" "$art")"
            ZBUILD_STAGE_IO_SEQ_LABEL="${ZBUILD_SEQ_PREFIX}.$(( i + 1 ))" \
                eb_emit_event "parallel.member.dispatch.complete" "group=$stage" \
                "member=${stage}.${elems[$i]}" "verdict=$outcome" "reason=$reason" \
                "summary_path=$sum" "result_path=$res" 2>/dev/null || true
        fi
    done
    local noun="${dimension:-members}" head
    if [[ ${#unfinished[@]} -gt 0 ]]; then
        local u list=""
        for u in "${unfinished[@]}"; do list+="${list:+, }$u"; done
        head="${#unfinished[@]} of $n $noun did not finish: $list"
        _ZB_MAP_UNFINISHED="$head"
    else
        head="all $n $noun finished"
    fi
    if [[ ${#notpassed[@]} -gt 0 ]]; then
        local p plist=""
        for p in "${notpassed[@]}"; do plist+="${plist:+, }$p"; done
        _ZB_MAP_NOT_PASSED="${#notpassed[@]} of $n $noun did not pass: $plist"
    fi
    if [[ ${#halted[@]} -gt 0 ]]; then
        local hl=""; for p in "${halted[@]}"; do hl+="${hl:+; }$p"; done
        _ZB_MAP_HALTED="$hl"
    fi
    mkdir -p "$art" 2>/dev/null || true
    printf '## %s\n\n%s\n\n%s' "$stage" "$head" "$body" > "$art/${stage//[^A-Za-z0-9_.-]/_}-summary.md" 2>/dev/null || true
    return 0
}

# _map_group_verdict — the group's word on its complete event, after
# _map_write_summary: incomplete when a member did not finish, fail when one
# failed, else pass (#1753).
_map_group_verdict() {
    if [[ -n "${_ZB_MAP_UNFINISHED:-}" ]]; then printf 'incomplete'
    elif [[ -n "${_ZB_MAP_NOT_PASSED:-}" ]]; then printf 'fail'
    else printf 'pass'
    fi
}
