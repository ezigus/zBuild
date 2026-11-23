#!/usr/bin/env bash
# plugins/agent/build/lib/steps-specs.sh — design's steps as build and its step
# check read them: each with the SPECs it serves (#2579, ADR-072 §3), and
# whether it changed since the check last answered it (ADR-072 §4). Split
# from steps.sh (under 500 lines); steps.sh sources it.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_BUILD_STEPS_SPECS_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_STEPS_SPECS_LOADED=1

# _build_steps_load <plan_json> — design's steps, in order, into _BUILD_STEP_DESC,
# _BUILD_STEP_AREAS (space separated) and _BUILD_STEP_SPECS (each SPEC the step
# serves, "- <id>: <text>", its parts under it, from design-steps.json's specs,
# each capped like a not-needed reason): one jq, none when there is no step.
# #2586 (ADR-073): _BSL[<n>] is entry <n>'s number as design wrote it — a
# part's `1.2`, else <n> — and _BSI[<number>] the entry it names.
_BUILD_STEP_DESC=() _BUILD_STEP_AREAS=() _BUILD_STEP_SPECS=()
declare -gA _BSL=() _BSI=()
_build_steps_load() {
    _BUILD_STEP_DESC=() _BUILD_STEP_AREAS=() _BUILD_STEP_SPECS=(); _BSL=(); _BSI=()
    [[ "${1:-}" == *'"steps"'* ]] || return 0
    local d a s i
    while IFS=$'\x1f' read -r i d a s; do
        [[ -n "$d" ]] || continue
        _BUILD_STEP_DESC+=("$d"); _BUILD_STEP_AREAS+=("$a"); _BUILD_STEP_SPECS+=("${s//$'\x1e'/$'\n'}")
        [[ "$i" =~ ^[0-9]+(\.[0-9]+)?$ ]] || i=${#_BUILD_STEP_DESC[@]}
        _BSL[${#_BUILD_STEP_DESC[@]}]="$i"; _BSI[$i]=${#_BUILD_STEP_DESC[@]}
    done < <(jq -r '(.specs // {}) as $sp | .steps // [] | .[] | select(type == "object")
        | "\(.id // "" | tostring | ltrimstr("step-") | gsub("[\u001f\r\n]"; ""))\u001f\(.description // "" | tostring | gsub("[\r\n\u001f]+"; " "))\u001f\((.areas // .files // []) | map(tostring) | join(" "))\u001f\((.serves // []) | map(tostring | . as $id | ($sp[$id] // "(the design has no such SPEC)" | tostring) as $t | "- \($id): \(if ($t | length) > 1000 then $t[0:1000] + "…" else $t end)") | join("\n") | gsub("\u001f"; " ") | gsub("\n"; "\u001e"))"' <<< "$1" 2>/dev/null)
}

# _build_steps_index_v <var> <number> — the entry a step's or a part's number
# names (`08` is 8, `1.02` is 1.2); rc 1 when it names none.
_build_steps_index_v() {
    local -n _bsix="$1"; local v="$2" a b=""
    [[ "$v" =~ ^([0-9]{1,6})(\.([0-9]{1,6}))?$ ]] || return 1
    a=$(( 10#${BASH_REMATCH[1]} )); [[ -n "${BASH_REMATCH[3]}" ]] && b=".$(( 10#${BASH_REMATCH[3]} ))"
    _bsix="${_BSI[$a$b]:-}"
    if [[ -z "$_bsix" && -z "$b" && ${#_BSI[@]} -eq 0 ]] && (( a >= 1 && a <= ${#_BUILD_STEP_DESC[@]} )); then _bsix=$a; fi
    [[ -n "$_bsix" ]]
}

# _build_steps_text_v <var> <n> — step <n> as its check judges it: its words,
# and the SPECs it serves. Kept with the step's verdict, so a change to either
# is shown as a change (judge-changed.sh).
_build_steps_text_v() {
    local -n _bst="$1"; local i=$(( $2 - 1 ))
    _bst="${_BUILD_STEP_DESC[i]:-}"
    [[ -n "${_BUILD_STEP_SPECS[i]:-}" ]] && _bst+=$'\n'"the SPECs it serves — the answer must not break any of these:"$'\n'"${_BUILD_STEP_SPECS[i]}"
    return 0
}

# _build_steps_texts_v <assoc> — every step's text, keyed step-<n>.
_build_steps_texts_v() {
    local -n _bsts="$1"; local _bsts_n
    _bsts=()
    for (( _bsts_n = 1; _bsts_n <= ${#_BUILD_STEP_DESC[@]}; _bsts_n++ )); do _build_steps_text_v "_bsts[step-${_BSL[$_bsts_n]:-$_bsts_n}]" "$_bsts_n"; done
}

# _build_steps_changed_v <var> <artifact_dir> — for build's own prompt: each
# step whose words or SPECs changed since its check last answered it, with what
# it was; empty when none did, nothing was kept, or a step only moved.
_build_steps_changed_v() {
    local -n _bsc="$1"; local kf="${2%/}/build-steps-judged.json" n w e
    _bsc=""
    [[ ${#_BUILD_STEP_DESC[@]} -gt 0 && -s "$kf" ]] || return 0
    local -A _none=() _got=() _now=()
    # No keys asked: this only loads _JUDGE_KEPT_TEXT from the kept file.
    judge_kept_get_all_v _got "$kf" _none
    _build_steps_texts_v _now
    for (( n = 1; n <= ${#_BUILD_STEP_DESC[@]}; n++ )); do
        judge_item_was_v w "step-${_BSL[$n]:-$n}" "${_now[step-${_BSL[$n]:-$n}]}" _now; [[ -n "$w" ]] || continue
        judge_changed_entry_v e "step ${_BSL[$n]:-$n} changed since you last answered it" "$w" "${_now[step-${_BSL[$n]:-$n}]}"; _bsc+="$e"
    done
    [[ -n "$_bsc" ]] && _bsc=$'\n'"These steps changed since you last answered them. Do the part that is new: \"done before\" does not cover it."$'\n'"$_bsc"
    return 0
}
