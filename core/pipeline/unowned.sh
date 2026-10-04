#!/usr/bin/env bash
# core/pipeline/unowned.sh — counting answers to findings (#2271, ADR-068).
#
# The engine never decides who owns a finding. Stages answer every finding they
# receive (scripts/lib/stage-answers.sh); this file only counts the answers:
#   - a loop with `unowned: yield` ends early when every one of its members that
#     answers findings said `nothing to do` to the same finding — the outer loop
#     then goes round from the top, carrying every finding;
#   - a loop with `unowned: halt` stops the run when the members that answer in
#     the next part of the loop also say `nothing to do` to it — nobody owns it.
# One `done` from anyone keeps a finding where it is. A member that should have
# answered and did not counts as not disclaiming.
#
# Answers live in <state_dir>/finding-answers/<unit>.json as
#   {"<stage> finding <n>": {answer, why, by}}.
# Source-only; no `set -e` at top level.
[[ -n "${_ZBUILD_UNOWNED_LOADED:-}" ]] && return 0
_ZBUILD_UNOWNED_LOADED=1

_UNOWNED_YIELD_FILE="unowned-yield.json"

# _cycle_stage_answers_findings <stage> — rc 0 when the stage answers findings.
# Every stage that calls a model declares a save-as-you-go output (ADR-063 §5,
# lint-stage-checkpoint.sh) and answers findings (ADR-068): the same set.
_cycle_stage_answers_findings() {
    local stage="$1" root="${ZBUILD_PLUGINS_ROOT:-${_CYCLE_ORCH_ROOT:-}/plugins}" m
    declare -F manifest_graph_resolve_member >/dev/null 2>&1 || return 1
    m="$(manifest_graph_resolve_member "$root" "$stage" 2>/dev/null)" || return 1
    [[ -f "$m" ]] && grep -qE '^[[:space:]]+role:[[:space:]]*checkpoint' "$m" 2>/dev/null
}

# _unowned_answerers <member...> — the members that answer findings, one per line.
_unowned_answerers() {
    local m
    for m in "$@"; do _cycle_stage_answers_findings "$m" && printf '%s\n' "$m"; done
    return 0
}

# _unowned_clear_round <state_dir> <member...> — a round starts with no answers
# from these members, so what is there at its end was given in it.
_unowned_clear_round() {
    local sd="$1"; shift
    [[ -d "$sd/finding-answers" && $# -gt 0 ]] || return 0
    local -a f=() m
    for m in "$@"; do f+=("$sd/finding-answers/$m.json"); done
    rm -f "${f[@]}" 2>/dev/null || true
}

# _unowned_answers_of <state_dir> <member...> — every answer the members gave,
# as [{ref, by, member, answer, why}]. A map member's units ("<stage>.<x>") count
# as that member.
_unowned_answers_of() {
    local sd="$1"; shift
    local -a files=() m f
    for m in "$@"; do
        for f in "$sd/finding-answers/$m.json" "$sd/finding-answers/$m".*.json; do
            [[ -s "$f" ]] && files+=("$f")
        done
    done
    [[ ${#files[@]} -gt 0 ]] || { printf '[]'; return 0; }
    jq -s -c '[ .[] | to_entries[] | {ref: .key, by: .value.by, answer: .value.answer, why: .value.why,
                member: (.value.by | split(".")[0])} ]' "${files[@]}" 2>/dev/null || printf '[]'
}

# _unowned_refs <answers_json> <member...> — the findings every listed member
# (other than the finding's opener) answered, all with `nothing to do`.
_unowned_refs() {
    local answers="$1"; shift
    local members; members="$(printf '%s\n' "$@" | jq -R . | jq -s -c . 2>/dev/null || printf '[]')"
    jq -c --argjson want "$members" '
        group_by(.ref) | map(
            (.[0].ref) as $r | ($r | split(" finding ")[0]) as $opener
            | ($want - [$opener]) as $exp
            | select(($exp | length) > 0)
            | select(all(.[]; .answer == "nothing to do"))
            | select(([.[].member] | unique) as $got | ($exp - $got) | length == 0)
            | $r )' <<< "$answers" 2>/dev/null || printf '[]'
}

# _unowned_yield_check <state_dir> <cycle_id> <member...> — rc 0 when this round
# left a finding none of the loop's answering members owns; records it for the
# outer loop. rc 1 otherwise.
_unowned_yield_check() {
    local sd="$1" cid="$2"; shift 2
    local -a ans_members=(); local m
    while IFS= read -r m; do [[ -n "$m" ]] && ans_members+=("$m"); done < <(_unowned_answerers "$@")
    [[ ${#ans_members[@]} -gt 0 ]] || return 1
    local answers refs
    answers="$(_unowned_answers_of "$sd" "${ans_members[@]}")"
    refs="$(_unowned_refs "$answers" "${ans_members[@]}")"
    [[ -n "$refs" && "$refs" != "[]" ]] || return 1
    jq -n -c --arg loop "$cid" --argjson refs "$refs" --argjson answers "$answers" \
        '{loop: $loop, refs: $refs, answers: [ $answers[] | select(.ref as $r | $refs | index($r)) ]}' \
        > "$sd/$_UNOWNED_YIELD_FILE" 2>/dev/null || return 1
    return 0
}

# _unowned_halt_check <state_dir> <member_cycle> — after <member_cycle> ran in an
# outer loop with `unowned: halt`: rc 0 when its answering members also said
# `nothing to do` to a finding an inner loop yielded — nobody owns it; the report
# is written. A `done` hands the finding back to the loop (record cleared). rc 1
# when there is nothing to stop for.
_unowned_halt_check() {
    local sd="$1" mc="$2" yf
    yf="$sd/$_UNOWNED_YIELD_FILE"
    [[ -s "$yf" ]] || return 1
    [[ "$(jq -r '.loop // empty' "$yf" 2>/dev/null)" == "$mc" ]] && return 1
    local mv="_TPL_CYCLE_STAGES_${mc//-/_}" m
    local -a members=() ans_members=()
    IFS=',' read -r -a members <<< "${!mv:-$mc}"
    while IFS= read -r m; do [[ -n "$m" ]] && ans_members+=("$m"); done < <(_unowned_answerers "${members[@]}")
    [[ ${#ans_members[@]} -gt 0 ]] || return 1
    local answers refs still
    answers="$(_unowned_answers_of "$sd" "${ans_members[@]}")"
    refs="$(jq -c '.refs' "$yf" 2>/dev/null || printf '[]')"
    # Of the yielded findings these members answered: one `done` hands it back.
    if jq -e --argjson refs "$refs" 'any(.[]; (.ref as $r | $refs | index($r)) and .answer == "done")' \
            <<< "$answers" >/dev/null 2>&1; then
        rm -f "$yf" 2>/dev/null || true
        return 1
    fi
    still="$(jq -c --argjson refs "$refs" '[ .[] | select(.answer == "nothing to do" and (.ref as $r | $refs | index($r))) | .ref ] | unique' <<< "$answers" 2>/dev/null || printf '[]')"
    [[ -n "$still" && "$still" != "[]" ]] || return 1
    _unowned_report "$sd" "$still" "$(jq -c --argjson a "$answers" '.answers + $a' "$yf" 2>/dev/null || printf '[]')"
    return 0
}

# _unowned_finding_text <state_dir> <opener> <n> — the finding's own words, from
# the opener's result.
_unowned_finding_text() {
    local sd="$1" op="$2" n="$3" res=""
    if declare -F _summaries_result_path >/dev/null 2>&1; then
        res="$(_summaries_result_path "$op" "${ZBUILD_PLUGINS_ROOT:-${_CYCLE_ORCH_ROOT:-}/plugins}" "$sd" 2>/dev/null || true)"
    fi
    [[ -s "$res" ]] || res="$sd/artifacts/$op-result.json"
    jq -r --argjson n "$n" '(.data.findings // [])[]? | select(.n == $n) | .text' "$res" 2>/dev/null || true
}

# _unowned_report <state_dir> <refs_json> <answers_json> — the report a human
# reads when the run stops for a finding nobody owns.
_unowned_report() {
    local sd="$1" refs="$2" answers="$3" ref op n
    mkdir -p "$sd/artifacts" 2>/dev/null || true
    {
        printf '# Findings no stage owns\n\n'
        printf 'Every stage that could change something answered "nothing to do" to these, so the run stopped instead of going round again.\n'
        while IFS= read -r ref; do
            [[ -n "$ref" ]] || continue
            op="${ref%% finding *}"; n="${ref##* finding }"
            printf '\n## %s (opened by %s)\n\n%s\n\n' "$ref" "$op" "$(_unowned_finding_text "$sd" "$op" "$n")"
            jq -r --arg r "$ref" '[ .[] | select(.ref == $r) ] | unique_by(.by) | .[] | "- \(.by): \(.answer) — \(.why)"' \
                <<< "$answers" 2>/dev/null || true
        done < <(jq -r '.[]' <<< "$refs" 2>/dev/null)
    } > "$sd/artifacts/unowned-findings.md" 2>/dev/null || true
}
