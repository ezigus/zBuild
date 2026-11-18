#!/usr/bin/env bash
# scripts/lib/stage-handoff.sh — a stage's last try changed nothing and its
# findings were the same: it is not run again, and what it answered decides
# where each finding goes (#2565; ADR-054 §6a, ADR-068 §6, ADR-071 §1). Loaded
# by stage-retry.sh the first time it is needed.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_STAGE_HANDOFF_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_HANDOFF_LOADED=1
# shellcheck source=stage-answers.sh
source "${BASH_SOURCE[0]%/*}/stage-answers.sh"

# stage_handoff_unchanged <plugin_dir> <stage> <state_file> — each answer in a
# result that did not pass:
#   wrong / not mine — the finding and the answer go to the stage's output
#     marked `handoff: true`, whose topic says which stage reads it, and the
#     result ends the round (ends_round, ADR-068 §3), as an untestable SPEC does;
#   done — nothing was changed for it: a finding back to the stage, in its own
#     result.
# A stage with no handoff output hands nothing on. Fail-open: bookkeeping never
# fails a stage.
stage_handoff_unchanged() {
    local plugin_dir="$1" stage="$2" state_file="$3"
    [[ -n "$stage" && "$state_file" == */* && -s "$plugin_dir/manifest.yaml" ]] || return 0
    declare -F _attempt_manifest_facts_v >/dev/null 2>&1 || return 0
    local sd="${state_file%/*}" ad facts k v xb="" hraw="" res="" body=""
    ad="${ZBUILD_ARTIFACT_DIR:-$sd/artifacts}"
    _attempt_manifest_facts_v facts "$plugin_dir/manifest.yaml"
    while IFS=$'\t' read -r k v; do
        case "$k" in X) xb="$v" ;; H) [[ -n "$hraw" ]] || hraw="$v" ;; esac
    done <<< "$facts"
    [[ -n "$xb" ]] || return 0
    while IFS=$'\t' read -r k v; do
        [[ "$k" == P && "${v##*/}" == "$xb" ]] || continue
        _registry_resolve_output_path_v res "$v" "$sd" "$ad"; break
    done <<< "$facts"
    [[ -n "$res" && -s "$res" ]] || return 0
    stage_result_is_current "$sd" "$stage" "$res" || return 0
    # Read by the shell: most tries that change nothing are judges that passed
    # and answered nothing, and they cost no program (ADR-065 §5).
    IFS= read -r -d '' body < "$res" || true
    [[ "$body" == *'"answers"'* ]] || return 0
    # Only a try that failed and may be tried again (fail, unusable) hands on:
    # a halting outcome (misconfigured, broken, …) must halt (review on #2565).
    # The first unescaped "outcome" key is the result's own, never a finding's.
    [[ "$body" =~ (^|[^\\])\"outcome\"[[:space:]]*:[[:space:]]*\"([a-z_]+)\" ]] || return 0
    [[ "${BASH_REMATCH[2]}" == fail || "${BASH_REMATCH[2]}" == unusable ]] || return 0

    # One row an answer, its fields split by \x1f (a tab is IFS white space, and
    # an empty field would vanish): <kind> <file of the finding's output> <n> <answer>.
    local -a ans=()
    local a kind key lbl n f rows="" on=0 back=0
    mapfile -t ans < <(jq -r '(.data.answers // [])[]? | tostring | gsub("[\r\n\t\u001f]+"; " ")' "$res" 2>/dev/null)
    for a in ${ans[@]+"${ans[@]}"}; do
        zb_answer_kind_v kind "$a"
        key="${a%%:*}"; lbl="${key% finding *}"; n="${key##* finding }"; n="${n%%[!0-9]*}"
        # Only the stage's own check's findings are handed on: a wrong or not
        # mine to another stage's finding already goes back to that judge
        # (ADR-068 §6). The stage's own findings are labelled by the stage.
        f=""; [[ "$lbl" == "$stage" ]] && f="$res"
        case "$kind" in
            done) back=$((back + 1)) ;;
            wrong|"not mine") [[ -n "$hraw" && -n "$f" ]] || continue; on=$((on + 1)) ;;
            *) continue ;;
        esac
        rows+="$kind"$'\x1f'"$f"$'\x1f'"${n:-0}"$'\x1f'"$a"$'\n'
    done
    (( on + back > 0 )) || return 0

    # The finding each answer is about, from the output its label names.
    local -a files=("$res")
    local -A seen=(["$res"]=1)
    while IFS=$'\x1f' read -r k f v; do
        [[ -n "$f" && -z "${seen[$f]+x}" ]] && { seen[$f]=1; files+=("$f"); }
    done <<< "$rows"
    local out hj="" rj=""
    out="$(jq -nrc --arg s "$stage" --arg rows "$rows" --arg resf "$res" '
        ([inputs | {(input_filename): .}] | add // {}) as $docs
        | [ $rows | split("\n")[] | select(length > 0) | split("\u001f")
            | {kind: .[0], f: .[1], n: (.[2] | tonumber? // 0), a: (.[3:] | join(" "))}
            | . as $r
            | .key = (.a | sub(":.*$"; ""))
            | .orig = ((($docs[$r.f] // {}).data.findings // [])
                       | map(select(type == "object" and .n == $r.n)) | .[0].text // "" | tostring) ] as $l
        | def tail($o): if $o == "" then "" else "\nThe finding: \($o)" end;
        ([$l[] | select(.kind != "done")
          | "\($s) changed nothing for \(.key) and answered: \(.a | sub("^[^:]*:[[:space:]]*"; ""))" + tail(.orig)]) as $on
        | ([$l[] | select(.kind == "done")
          | "\(.key): you answered done, but this try changed nothing — make the change, or answer wrong (it is already right, and why) or not mine (whose change it is)" + tail(.orig)]) as $back
        | (if ($on | length) == 0 then "-"
           else {data: {findings: ($on | to_entries | map({n: (.key + 1), text: .value}))}} | tojson end),
          ($docs[$resf]
           | (if ($back | length) == 0 then . else
                (.data.findings // []) as $f | ([$f[]?.n? | numbers] | max // 0) as $m
                | .data.findings = $f + ($back | to_entries | map({n: ($m + .key + 1), text: .value})) end)
           | (if ($on | length) > 0 then .data.ends_round = true else . end)
           | tojson)' "${files[@]}" 2>/dev/null)" || return 0
    { IFS= read -r hj; IFS= read -r rj; } <<< "$out"
    [[ -n "$rj" && "$rj" == "{"* ]] || return 0
    if [[ "$hj" == "{"* ]]; then
        local hp; _registry_resolve_output_path_v hp "$hraw" "$sd" "$ad"
        # A handoff that could not be written ends no round: nothing changes.
        if [[ -z "$hp" ]] || ! atomic_write "$hp" <<< "$hj" 2>/dev/null; then on=0; rj=""; fi
    fi
    # A result that could not be written takes its handoff with it: a handoff
    # with no ends_round would reach its owner while the round went on.
    if [[ -n "$rj" ]] && ! atomic_write "$res" <<< "$rj" 2>/dev/null; then
        [[ -n "${hp:-}" ]] && rm -f "$hp" 2>/dev/null
        return 0
    fi
    declare -F emit_event >/dev/null 2>&1 && emit_event "stage.findings.handed_on" \
        "stage=$stage" "handed_on=$on" "sent_back=$back" >/dev/null 2>&1
    return 0
}
