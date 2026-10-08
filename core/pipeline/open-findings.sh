#!/usr/bin/env bash
# core/pipeline/open-findings.sh — which findings are still open (ADR-068 §10).
#
# A finding is a numbered item in a stage's latest result (`data.findings`,
# ADR-068 §5), whatever the stage's verdict: a warning is a finding too. It is
# settled only by a `done` from some stage, or by its opener's `satisfied`
# (§6/§7), given since the opener last ran. Findings are numbered by position, so
# an answer is tied to the opener's run, not to a number: each dispatch counts
# its stage's runs here (plugin_hook_call), and every answer records the count it
# was given at (scripts/lib/stage-answers.sh). Once the opener runs again, older
# answers settle nothing — even when it reports the same sentence again: the
# stage said done; the check says it is still there.
#
# The engine still decides no ownership (§8): it only asks whether anyone acted.
#
# Source-only; no `set -e` at top level. Needs jq.
[[ -n "${_ZBUILD_OPEN_FINDINGS_LOADED:-}" ]] && return 0
_ZBUILD_OPEN_FINDINGS_LOADED=1
_ZBUILD_OF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_open_findings_runs_file() {   # <state_dir> <stage>
    printf '%s/finding-answers/.runs/%s' "$1" "${2//[^A-Za-z0-9._-]/_}"
}

# open_findings_runs <state_dir> <stage> — how many times the stage has run (0).
open_findings_runs() {
    local f n=0
    f="$(_open_findings_runs_file "$1" "$2")"
    [[ -s "$f" ]] && IFS= read -r n 2>/dev/null < "$f"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# open_findings_stage_ran <state_dir> <stage> — called once per dispatch.
open_findings_stage_ran() {
    local sd="${1:-}" stage="${2:-}" f n
    [[ -n "$sd" && -n "$stage" ]] || return 0
    f="$(_open_findings_runs_file "$sd" "$stage")"
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    n="$(open_findings_runs "$sd" "$stage")"
    printf '%s\n' "$(( n + 1 ))" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null || true
    return 0
}

# The stage's primary (v2 result) file, the same lookup the prompt's summaries
# use (core/pipeline/input-resolve.sh), so what a stage was shown and what is
# counted open are the same findings.
_open_findings_result_path() {   # <stage> <plugins_root> <state_dir>
    if ! declare -F _summaries_result_path >/dev/null 2>&1; then
        # shellcheck source=./input-resolve.sh
        source "$_ZBUILD_OF_ROOT/core/pipeline/input-resolve.sh" 2>/dev/null || return 0
    fi
    _summaries_result_path "$@" 2>/dev/null || true
}

# open_findings_json <state_file> [plugins_root] —
#   [{ref, opener, text, answers: [{answer, why, by}]}], the answers being those
#   given since the opener last ran.
open_findings_json() {
    local sf="${1:-}" pr="${2:-${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_OF_ROOT/plugins}}" sd stage res
    [[ -n "$sf" && -s "$sf" ]] || { printf '[]'; return 0; }
    sd="${sf%/*}"
    local found='[]' answers='{}'
    while IFS= read -r stage; do
        [[ -n "$stage" ]] || continue
        res="$(_open_findings_result_path "$stage" "$pr" "$sd")"
        [[ -n "$res" ]] || continue
        found="$(jq -c --arg s "$stage" --argjson runs "$(open_findings_runs "$sd" "$stage")" \
            --argjson acc "$found" '
            $acc + [ (.data.findings // [])[]?
                     | select(type == "object" and (.n | type) == "number")
                     | {ref: "\($s) finding \(.n)", opener: $s, runs: $runs,
                        text: (.text | tostring | gsub("[\r\n]+"; " "))} ]' "$res" 2>/dev/null || printf '%s' "$found")"
    done < <(jq -r '(.stage_statuses // {}) | keys_unsorted[]' "$sf" 2>/dev/null || true)
    local -a afiles=()
    local f
    for f in "$sd"/finding-answers/*.json; do [[ -s "$f" ]] && afiles+=("$f"); done
    if [[ ${#afiles[@]} -gt 0 ]]; then
        answers="$(jq -s -c '[ .[] | objects | to_entries[] ] | group_by(.key)
                             | map({key: .[0].key, value: map(.value)}) | from_entries' "${afiles[@]}" 2>/dev/null || printf '{}')"
    fi
    jq -n -c --argjson found "$found" --argjson ans "$answers" '
        [ $found[] as $f
          | ([ ($ans[$f.ref] // [])[] | select((.runs // -1) == $f.runs) ]) as $a
          | select(([ $a[] | select(.answer == "done"
                                    or (.answer == "satisfied" and .by == $f.opener)) ] | length) == 0)
          | {ref: $f.ref, opener: $f.opener, text: $f.text,
             answers: [ $a[] | {answer, why, by} ]} ]' 2>/dev/null || printf '[]'
}

# open_findings_count <state_file> [plugins_root]
open_findings_count() {
    jq 'length' <<< "$(open_findings_json "$@")" 2>/dev/null || printf '0'
}
