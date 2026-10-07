#!/usr/bin/env bash
# core/pipeline/unowned.sh — counting answers to findings (#2271, ADR-068).
#
# The engine never decides who owns a finding. Stages answer every finding they
# receive (scripts/lib/stage-answers.sh); this file only counts the answers:
#   - a loop with `unowned: yield` ends early when every one of its members that
#     answers findings said `nothing to do` to the same finding — the outer loop
#     then goes round from the top, carrying every finding;
#   - a loop with `unowned: halt` stops the run when every member that answers
#     findings and ran before the yielding loop came round again also said
#     `nothing to do` to it — nobody owns it.
# One `done` from anyone keeps a finding where it is. A member that should have
# answered and did not counts as not disclaiming.
#
# Answers live in <state_dir>/finding-answers/<unit>.json as
#   {"<stage> finding <n>": {answer, why, by}}.
# Source-only; no `set -e` at top level.
[[ -n "${_ZBUILD_UNOWNED_LOADED:-}" ]] && return 0
_ZBUILD_UNOWNED_LOADED=1

_UNOWNED_YIELD_FILE="unowned-yield.json"
# shellcheck source=../../scripts/lib/run-open-items.sh
source "${_CYCLE_ORCH_ROOT:-${BASH_SOURCE[0]%/*}/../..}/scripts/lib/run-open-items.sh"

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
    local -a f=() m u
    for m in "$@"; do
        f+=("$sd/finding-answers/$m.json")
        # A map member's per-unit files too (<stage>.<element>.json).
        for u in "$sd/finding-answers/$m".*.json; do [[ -e "$u" ]] && f+=("$u"); done
    done
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

# _unowned_halt_check <state_dir> <member...> — the outer loop (`unowned: halt`)
# is about to re-enter the loop that yielded a finding; <member...> are the
# outer loop's members that ran before it this round. Every one of them that
# answers findings is expected to answer the yielded finding:
#   - one `done` from any of them hands it back to the loop (record cleared), rc 1;
#   - all `nothing to do` → nobody owns it: the report is written, rc 0;
#   - a member that did not answer counts as not disclaiming, rc 1.
_unowned_halt_check() {
    local sd="$1"; shift
    local yf="$sd/$_UNOWNED_YIELD_FILE"
    [[ -s "$yf" ]] || return 1
    local -a ans=(); local m
    while IFS= read -r m; do [[ -n "$m" ]] && ans+=("$m"); done < <(_unowned_leaf_answerers "$@")
    [[ ${#ans[@]} -gt 0 ]] || return 1
    local answers refs still
    answers="$(_unowned_answers_of "$sd" "${ans[@]}")"
    refs="$(jq -c '.refs' "$yf" 2>/dev/null || printf '[]')"
    if jq -e --argjson refs "$refs" 'any(.[]; (.ref as $r | $refs | index($r)) and .answer == "done")' \
            <<< "$answers" >/dev/null 2>&1; then
        rm -f "$yf" 2>/dev/null || true
        return 1
    fi
    still="$(_unowned_refs "$answers" "${ans[@]}")"
    still="$(jq -c --argjson refs "$refs" '[ .[] | select(. as $r | $refs | index($r)) ]' <<< "${still:-[]}" 2>/dev/null || printf '[]')"
    [[ -n "$still" && "$still" != "[]" ]] || return 1
    _unowned_report "$sd" "$still" "$(jq -c --argjson a "$answers" '.answers + $a' "$yf" 2>/dev/null || printf '[]')" halt
    return 0
}

# _unowned_leaf_answerers <member...> — the stages that answer findings among
# these members, a nested loop expanded to its stages; one per line.
_unowned_leaf_answerers() {
    local -a leaves=(); local m l
    for m in "$@"; do
        local sv="_TPL_CYCLE_STAGES_${m//-/_}"
        if declare -F _tpl_flow_leaves >/dev/null 2>&1 && [[ -n "${!sv:-}" ]]; then
            while IFS= read -r l; do [[ -n "$l" ]] && leaves+=("$l"); done < <(_tpl_flow_leaves "$m")
        else
            leaves+=("$m")
        fi
    done
    [[ ${#leaves[@]} -gt 0 ]] || return 0
    _unowned_answerers "${leaves[@]}"
}

# _unowned_last_round_report <state_dir> <member...> — #2330: the outer loop
# (`unowned: halt`) has no round left, so the check above, which runs only when
# another round is coming, never will. Items no stage could act on are reported
# now: the findings a loop handed back this round, and the findings of every
# check that is not sure an item is met (`data.unsure`). <member...> are the
# outer loop's members; their answers go in the report. rc 0 when it was written.
_unowned_last_round_report() {
    local sd="$1"; shift
    local yf="$sd/$_UNOWNED_YIELD_FILE" refs='[]' prior='[]' f
    if [[ -s "$yf" ]]; then
        refs="$(jq -c '.refs // []' "$yf" 2>/dev/null || printf '[]')"
        prior="$(jq -c '.answers // []' "$yf" 2>/dev/null || printf '[]')"
    fi
    local -a unsure=()
    for f in "$sd"/artifacts/*-result.json; do
        [[ -s "$f" ]] && unsure+=("$f")
    done
    if [[ ${#unsure[@]} -gt 0 ]]; then
        refs="$(jq -n -c --argjson refs "$refs" '
            $refs + [ inputs as $r | (input_filename | split("/") | last | sub("-result\\.json$"; "")) as $c
                      | $r | select(type == "object" and .verdict != "pass" and ((.data.unsure // []) | length) > 0)
                      | (.data.findings // [])[] | "\($c) finding \(.n)" ] | unique' "${unsure[@]}" 2>/dev/null || printf '%s' "$refs")"
    fi
    [[ -n "$refs" && "$refs" != "[]" ]] || return 1
    local -a ans=(); local m answers='[]'
    while IFS= read -r m; do [[ -n "$m" ]] && ans+=("$m"); done < <(_unowned_leaf_answerers "$@")
    [[ ${#ans[@]} -gt 0 ]] && answers="$(_unowned_answers_of "$sd" "${ans[@]}")"
    _unowned_report "$sd" "$refs" "$(jq -c --argjson a "${answers:-[]}" '. + $a' <<< "$prior" 2>/dev/null || printf '%s' "$prior")" last_round
    return 0
}

# _unowned_clear_yield <state_dir> — the loop that handed findings back is about
# to run again: what it hands back now is recorded afresh.
_unowned_clear_yield() {
    rm -f "$1/$_UNOWNED_YIELD_FILE" 2>/dev/null || true
}

# _unowned_yielder <state_dir> — the loop that yielded a finding this round, or "".
_unowned_yielder() {
    jq -r '.loop // empty' "$1/$_UNOWNED_YIELD_FILE" 2>/dev/null || true
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

# _unowned_report <state_dir> <refs_json> <answers_json> <why> — the report read
# when the run stops on items no stage could act on (#2330: in plain words, each
# item with what is unresolved and what would settle it). <why> is `halt` (every
# stage that could change something answered "nothing to do") or `last_round`
# (no round was left). The items also go to artifacts/open-items.json, which
# every other report of the run's end lists (scripts/lib/run-open-items.sh).
_unowned_report() {
    local sd="$1" refs="$2" answers="$3" why="${4:-halt}" ref op n items='[]'
    mkdir -p "$sd/artifacts" 2>/dev/null || true
    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        op="${ref%% finding *}"; n="${ref##* finding }"
        items="$(jq -c --arg r "$ref" --arg o "$op" --arg t "$(_unowned_finding_text "$sd" "$op" "$n")" \
            --argjson a "${answers:-[]}" \
            '. + [{ref: $r, opener: $o, text: $t,
                   answers: ([ $a[]? | select(.ref == $r) ] | unique_by(.by) | map({by, answer, why}))}]' \
            <<< "$items" 2>/dev/null || printf '%s' "$items")"
    done < <(jq -r '.[]' <<< "$refs" 2>/dev/null)
    printf '%s\n' "$items" > "$sd/artifacts/open-items.json" 2>/dev/null || true
    {
        printf '# Open items the run could not settle\n\n'
        if [[ "$why" == "last_round" ]]; then
            printf 'The run used its last round with these items still open, and no stage that ran could act on them.\n\n'
        else
            printf 'Every stage that could change something answered that it had nothing to do for these items, so the run stopped instead of going round again.\n\n'
        fi
        open_items_render "$items" 1
    } > "$sd/artifacts/unowned-findings.md" 2>/dev/null || true
}
