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
_ZBUILD_OF_SRC="${BASH_SOURCE[0]}"
# The repository root, absolute (a relative one would key the manifest index
# differently and miss its cache). Worked out on first use, not at source time:
# every engine process sources this file (ADR-065).
_open_findings_root() {
    if [[ -z "${_ZBUILD_OF_ROOT:-}" ]]; then
        if [[ -n "${_ZBUILD_ROOT:-}" ]]; then _ZBUILD_OF_ROOT="$_ZBUILD_ROOT"
        else _ZBUILD_OF_ROOT="$(cd "$(dirname "$_ZBUILD_OF_SRC")/../.." && pwd)"; fi
    fi
    printf '%s' "$_ZBUILD_OF_ROOT"
}

# Engine bookkeeping, so under runtime/ with the write-boundary markers.
_open_findings_runs_file() {   # <state_dir> <stage>
    printf '%s/runtime/stage-runs/%s' "$1" "${2//[^A-Za-z0-9._-]/_}"
}

# open_findings_runs <state_dir> <stage> — how many times the stage has run (0).
open_findings_runs() {
    local f n=0
    f="$(_open_findings_runs_file "$1" "$2")"
    [[ -s "$f" ]] && IFS= read -r n 2>/dev/null < "$f"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# open_findings_stage_ran <state_dir> <stage> — called once per dispatch, so it
# spends no process when it can avoid one (ADR-065): built-ins only once the
# folder exists. A torn read can only lose a count, which makes earlier answers
# stale — the safe direction.
open_findings_stage_ran() {
    local sd="${1:-}" stage="${2:-}" f n=0
    [[ -n "$sd" && -n "$stage" ]] || return 0
    f="$sd/runtime/stage-runs/${stage//[^A-Za-z0-9._-]/_}"
    [[ -d "${f%/*}" ]] || mkdir -p "${f%/*}" 2>/dev/null || return 0
    [[ -s "$f" ]] && IFS= read -r n 2>/dev/null < "$f"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s\n' "$(( n + 1 ))" > "$f" 2>/dev/null || true
    return 0
}

# The stages' primary (v2 result) files, by the same manifest lookup and path
# rules the prompt's summaries use (core/pipeline/input-resolve.sh), so what a
# stage was shown and what is counted open are the same findings. One awk over
# every manifest, not one per stage (ADR-065).
_open_findings_load() {
    declare -F _inputs_stage_manifest >/dev/null 2>&1 && return 0
    # shellcheck source=./input-resolve.sh
    source "$(_open_findings_root)/core/pipeline/input-resolve.sh" 2>/dev/null
}

# open_findings_json <state_file> [plugins_root] —
#   [{ref, opener, text, answers: [{answer, why, by}]}], the answers being those
#   given since the opener last ran.
open_findings_json() {
    local sf="${1:-}" pr="${2:-${ZBUILD_PLUGINS_ROOT:-}}" sd stage man raw res
    [[ -n "$pr" ]] || pr="$(_open_findings_root)/plugins"
    [[ -n "$sf" && -s "$sf" ]] || { printf '[]'; return 0; }
    _open_findings_load || { printf '[]'; return 0; }
    sd="${sf%/*}"
    local -A _of_man=() _of_raw=()
    local -a _of_stages=() _of_mans=()
    while IFS= read -r stage; do
        [[ -n "$stage" ]] || continue
        man="$(_inputs_stage_manifest "$stage" "$pr" 2>/dev/null || true)"
        [[ -n "$man" && -f "$man" ]] || continue
        _of_stages+=("$stage"); _of_man["$stage"]="$man"; _of_mans+=("$man")
    done < <(jq -r '(.stage_statuses // {}) | keys_unsorted[]' "$sf" 2>/dev/null || true)
    [[ ${#_of_mans[@]} -gt 0 ]] || { printf '[]'; return 0; }
    # The primary path of each manifest: the program _verdict_primary_output_path
    # runs, reset at each file.
    while IFS=$'\t' read -r man raw; do
        [[ -n "$man" && -n "$raw" ]] && _of_raw["$man"]="$raw"
    done < <(awk '
        function flush() { if (!done && prim == "true" && path != "") { print FILENAME_PREV "\t" path; done=1 } }
        FNR == 1 { if (NR > 1) flush(); FILENAME_PREV=FILENAME; inout=0; path=""; prim=""; done=0 }
        /^outputs:/ { inout=1; next }
        inout && /^[a-zA-Z_]/ { inout=0 }
        inout && /^[[:space:]]*-[[:space:]]*id:/ { flush(); path=""; prim=""; next }
        inout && /^[[:space:]]+path:/ { l=$0; sub(/^[[:space:]]+path:[[:space:]]*/, "", l); sub(/[[:space:]]*#.*/, "", l)
            gsub(/^["\047]|["\047]$/, "", l); gsub(/[[:space:]]*$/, "", l); path=l; next }
        inout && /^[[:space:]]+primary:/ { l=$0; sub(/^[[:space:]]+primary:[[:space:]]*/, "", l); sub(/[[:space:]]*#.*/, "", l)
            gsub(/^["\047]|["\047]$/, "", l); gsub(/[[:space:]]*$/, "", l); prim=l; next }
        END { flush() }' "${_of_mans[@]}" 2>/dev/null)
    local map=""
    local -a files=()
    for stage in "${_of_stages[@]}"; do
        raw="${_of_raw[${_of_man[$stage]}]:-}"
        [[ -n "$raw" ]] || continue
        res="$(_verdict_resolve_path "$raw" "$sd" 2>/dev/null || true)"
        [[ "$res" == *.json && -s "$res" ]] || continue
        files+=("$res")
        map+="${res}"$'\t'"${stage}"$'\t'"$(open_findings_runs "$sd" "$stage")"$'\n'
    done
    [[ ${#files[@]} -gt 0 ]] || { printf '[]'; return 0; }
    local f
    for f in "$sd"/finding-answers/*.json; do [[ -s "$f" ]] && files+=("$f"); done
    jq -n -c --arg tsv "$map" '
        ([ $tsv | split("\n")[] | select(length > 0) | split("\t")
           | {key: .[0], value: {stage: .[1], runs: (.[2] | tonumber? // 0)}} ] | from_entries) as $map
        | [ inputs as $d | input_filename as $fn | {fn: $fn, d: $d} ] as $all
        | ([ $all[] | select($map[.fn] != null) as $x | $map[$x.fn] as $m
             | ($x.d.data.findings // [])[]?
             | select(type == "object" and (.n | type) == "number")
             | {ref: "\($m.stage) finding \(.n)", opener: $m.stage, runs: $m.runs,
                text: (.text | tostring | gsub("[\r\n]+"; " "))} ]) as $found
        | ([ $all[] | select($map[.fn] == null) | .d | objects | to_entries[] ]
           | group_by(.key) | map({key: .[0].key, value: map(.value)}) | from_entries) as $ans
        | [ $found[] as $f
            | ([ ($ans[$f.ref] // [])[] | select((.runs // -1) == $f.runs) ]) as $a
            | select(([ $a[] | select(.answer == "done"
                                      or (.answer == "satisfied" and .by == $f.opener)) ] | length) == 0)
            | {ref: $f.ref, opener: $f.opener, text: $f.text, answers: [ $a[] | {answer, why, by} ]} ]' \
        "${files[@]}" 2>/dev/null || printf '[]'
}

# open_findings_count <state_file> [plugins_root]
open_findings_count() {
    jq 'length' <<< "$(open_findings_json "$@")" 2>/dev/null || printf '0'
}
