#!/usr/bin/env bash
# scripts/lib/stage-summary.sh — every stage states what it did (#2000).
#
# ADR-055 §9 makes this mandatory for every stage-bound plugin, not just the
# gates #1988 covered. A stage that publishes nothing is indistinguishable from
# one that had nothing to say, and the pipeline cannot tell those apart — so the
# second silently absorbs the first. `acceptance-summary.txt` is the worked
# example: written by spec-acceptance, declared by nobody, unread for months.
#
# Shared rather than hand-rolled five times: the write is identical everywhere,
# and centralising it is what makes "every gate always speaks" enforceable
# rather than five separate chances to forget.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_STAGE_SUMMARY_SH_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_SUMMARY_SH_LOADED=1
# shellcheck source=item-ids.sh
source "${BASH_SOURCE[0]%/*}/item-ids.sh"

# ─── stage_findings_json — one finding per line on stdin → [{n, text}] ──────
# #2271 (ADR-068): a check lists what it found as numbered items in its result
# (`data.findings`), so later stages can answer each one and the check that
# opened it can close it. Blank lines are skipped; numbering starts at 1.
# #2470: a finding of several lines (a SPEC shown whole) comes as one line with
# its lines joined by a record separator (\x1e), and keeps them. #2556 (ADR-071
# §1): a finding names no topic of its own — its output's topic decides who
# reads it; a stage with findings for several topics writes them with
# stage_findings_route.
# #2574 (ADR-068 §5): with <dir> and <code>, each finding also gets its id
# (zb_fids, item-ids.sh): the same finding keeps it, numbered in the same jq.
stage_findings_json() {
    local _sfj_reg="" _sfj_out="" _sfj_f="" _sfj_r=""
    if ! zb_findings_reg_v _sfj_reg "${1:-}" "${2:-}"; then
        jq -R -s -c '[ split("\n")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0) ]
             | to_entries | map({n: (.key + 1), text: (.value | gsub("\u001e"; "\n"))})' 2>/dev/null || printf '[]'
        return 0
    fi
    _sfj_out="$(jq -R -s -r --arg reg "$_sfj_reg" --arg code "$2" "$_ZB_FINDING_IDS_JQ"'
        [ split("\n")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0) ]
        | to_entries | map({n: (.key + 1), text: (.value | gsub("\u001e"; "\n"))})
        | if length == 0 then "[]", "-" else zb_fids($reg; $code) | (.out | tojson), (.r | tojson) end' 2>/dev/null)"
    { IFS= read -r _sfj_f; IFS= read -r _sfj_r; } <<< "$_sfj_out"
    [[ "$_sfj_r" == "{"* ]] && zb_findings_reg_put "$1" "$2" "$_sfj_r"
    printf '%s' "${_sfj_f:-[]}"
}

# The topics a finding line may be routed to, and each one's word in its file's
# name: <name>-<word>-result.json. #2569: the word is what must change.
_ZB_FINDING_TOPICS='^(design-findings|test-findings|code-findings)\t'

# stage_findings_route <dir> <name> <default-topic> [code] — reads finding lines on
# stdin, "<topic><TAB><text>" or "<text>" (the default topic); writes each
# topic's findings, numbered, to <dir>/<name>-<word>-result.json (the topic
# without "-findings"), with no verdict of its own, and removes the file of a
# topic that has none; prints every finding, numbered and naming no topic, for
# the stage's own result (#2556, ADR-071 §1). [code]: each finding's id
# (#2574), the same in every output it is in.
stage_findings_route() {
    local dir="$1" name="$2" def="$3" code="${4:-}" _in="" _l _w _j _all="[]" _reg="" _ids=0
    zb_findings_reg_v _reg "$dir" "$code" && _ids=1
    IFS= read -r -d '' _in || true
    local -A _sfr_has=()
    local -a _sfr_gone=()
    # No findings: no jq — only the files of an earlier try are removed, and
    # rm runs only when there is one (ADR-065).
    if [[ -z "${_in//[[:space:]]/}" ]]; then
        for _w in design test code; do
            [[ -e "$dir/$name-$_w-result.json" ]] && _sfr_gone+=("$dir/$name-$_w-result.json")
        done
        [[ ${#_sfr_gone[@]} -gt 0 ]] && rm -f "${_sfr_gone[@]}"
        printf '[]'; return 0
    fi
    while IFS=$'\t' read -r _w _j; do
        [[ -n "$_w" ]] || continue
        if [[ "$_w" == ALL ]]; then _all="$_j"; continue; fi
        if [[ "$_w" == REG ]]; then zb_findings_reg_put "$dir" "$code" "$_j"; continue; fi
        # Counted as written only once it is: a file that could not be
        # written is removed below, never left from an earlier try.
        atomic_write "$dir/$name-$_w-result.json" <<< "$_j" 2>/dev/null && _sfr_has[$_w]=1
    # #2574: with a code, every finding gets its id once, over the whole list,
    # so it has the same id in the stage's own list and in its topic's output.
    done < <(jq -R -s -r --arg d "$def" --arg re "$_ZB_FINDING_TOPICS" --arg reg "$_reg" --arg code "$code" --argjson ids "$_ids" "$_ZB_FINDING_IDS_JQ"'
        [ split("\n")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0)
          | if test($re) then {t: split("\t")[0], x: sub("^[^\t]+\t"; "")} else {t: $d, x: .} end
          | .x |= gsub("\u001e"; "\n") ] as $l0
        # Ids are given once over the distinct texts, then fanned out: a finding
        # sent to several topics has one id in each (review on #2574).
        | (reduce $l0[].x as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)) as $dx
        | (if $ids == 1 then ($dx | map({text: .}) | zb_fids($reg; $code)) else {out: ($dx | map({text: .})), r: null} end) as $z
        | ([$z.out[] | select(.id) | {(.text): .id}] | add // {}) as $idof
        | ($l0 | map({text: .x, t: .t} + (if $idof[.x] then {id: $idof[.x]} else {} end))) as $l
        | def item: {text} + (if .id then {id} else {} end);
        ([$l[].t] | unique[] | . as $t
           | "\($t | sub("-findings$"; ""))\t" + ({data: {findings: ([$l[] | select(.t == $t)] | to_entries | map({n: (.key + 1)} + (.value | item)))}} | tojson)),
          "ALL\t" + ($dx | to_entries | map({n: (.key + 1), text: .value} + (if $idof[.value] then {id: $idof[.value]} else {} end)) | tojson),
          (if $z.r then "REG\t" + ($z.r | tojson) else empty end)' <<< "$_in" 2>/dev/null)
    for _w in design test code; do
        [[ -z "${_sfr_has[$_w]:-}" && -e "$dir/$name-$_w-result.json" ]] && _sfr_gone+=("$dir/$name-$_w-result.json")
    done
    [[ ${#_sfr_gone[@]} -gt 0 ]] && rm -f "${_sfr_gone[@]}"
    printf '%s' "$_all"
}

# stage_findings_routed_lines <dir> <name> <default-topic> — the findings
# stage_findings_route wrote, read back as the lines it takes, so a stage that
# adds to them keeps each one's topic.
stage_findings_routed_lines() {
    local _w _f; local -a _fs=()
    for _w in design test code; do
        _f="$1/$2-$_w-result.json"; [[ -s "$_f" ]] && _fs+=("$_f")
    done
    [[ ${#_fs[@]} -gt 0 ]] || return 0
    # One jq for every file: each finding with its file's topic, the default's bare.
    jq -r --arg d "$3" '(input_filename | capture("-(?<w>[a-z]+)-result\\.json$").w + "-findings") as $t
        | (.data.findings // [])[]? | (.text | tostring | gsub("[\r\n]+"; " ")) as $x
        | if $t == $d then $x else "\($t)\t\($x)" end' "${_fs[@]}" 2>/dev/null
    return 0
}

# ─── stage_summary_write <path> <stage> <verdict> <reason> [body] ────────────
# Writes the gate's summary on EVERY terminal verdict — pass, fail and skip.
#
# ADR-055 §9: a summary states what the stage DID, not what went wrong. A gate
# that passed still did work, and a later stage that cannot see its conclusion
# must either assume the work never happened or redo it. Writing
# unconditionally also collapses the ambiguity between "ran and found nothing"
# and "published nothing" — a missing summary now means something went wrong,
# full stop, which is why the output is `required: true`.
#
# The heading names the stage so a reader of the assembled prompt can tell whose
# statement it is once several are stacked.
stage_summary_write() {
    local path="${1:-}" stage="${2:-}" verdict="${3:-}" reason="${4:-}" body="${5:-}"
    [[ -n "$path" ]] || return 0
    [[ "$path" != */* || -d "${path%/*}" ]] || mkdir -p "${path%/*}" 2>/dev/null || true
    {
        printf '## %s — %s\n\n' "${stage:-stage}" "${verdict:-unknown}"
        if [[ -n "$reason" ]]; then
            printf -- '- %s\n' "$reason"
        else
            # Never silent: a verdict with nothing said still states that this
            # gate ran and reached it, which is the fact a later stage needs.
            printf -- '- no findings\n'
        fi
        [[ -n "$body" ]] && printf '\n%s\n' "$body"
    } > "$path" 2>/dev/null || true
}

# ─── stage_errors_append <stage> <text...> ──────────────────────────────────
# Append to THIS stage's declared error channel (#2183). One place, so a stage
# adds a line without knowing where the file lives or how it is published: the
# engine reads the manifest's `errors: true` output and carries a bounded tail
# into the summaries the other stages read when this stage fails.
#
# Path convention: ${artifact_dir}/<stage>-errors.log. Appends, so a stage with
# several failing subprocesses keeps all of them. Emptied by the engine at the
# start of each dispatch (stage_errors_clear; the attempt archive keeps the
# earlier copy). Fail-open: a diagnostic write never changes a stage's fate.
# stage_lens_findings_head_v <var> <findings-array-json> <none-words> [body-var]
# #2476 (ADR-064 §4): a lens's summary line names what it found, or
# <none-words>. #2611: each finding is said once — one finding is the line and
# there is no list; several are counted by severity on the line ("found 2
# findings: 1 high, 1 medium", as the status row says) and the body (when asked
# for) lists each. One jq.
stage_lens_findings_head_v() {
    local -n _slh="$1"; local _sl_out _sl_none="$3"
    _sl_out="$(jq -r 'def one: (if (.severity | type) == "string" then "\(.severity): " else "" end)
            + ((.message // .text // "") | tostring | gsub("[\r\n]+"; " "))
            + (if (.file // "unknown") != "unknown" then " (\(.file)\(if .line then ":\(.line)" else "" end))" else "" end);
        [ (if type == "array" then . else (.findings // []) end)[]? | select(type == "object") ] as $o
        | [ $o[] | one ] as $f
        | ([ $o[] | .severity | select(type == "string") | ascii_downcase ]) as $sv
        | (["critical", "high", "medium", "low"]
           | map(. as $k | ([$sv[] | select(. == $k)] | length) as $c | select($c > 0) | "\($c) \($k)")) as $cnt
        | if ($f | length) == 0 then ""
          elif ($f | length) == 1 then "found: " + $f[0]
          else ("found \($f | length) findings" + (if ($cnt | length) > 0 then ": " + ($cnt | join(", ")) else "" end)),
               ($f[] | "- " + .)
          end' <<< "${2:-[]}" 2>/dev/null || true)"
    _slh="${_sl_out%%$'\n'*}"
    [[ -n "$_slh" ]] || _slh="$_sl_none"
    if [[ -n "${4:-}" ]]; then
        local -n _slb="$4"
        if [[ "$_sl_out" == *$'\n'* ]]; then _slb="${_sl_out#*$'\n'}"; else _slb=""; fi
    fi
}

stage_errors_append() {
    local stage="${1:-${ZBUILD_CURRENT_STAGE:-}}"; shift || true
    local log; log="$(_stage_errors_log "$stage")"
    [[ -n "$log" ]] || return 0
    [[ -d "${log%/*}" ]] || mkdir -p "${log%/*}" 2>/dev/null || true
    printf '%s\n' "$*" >> "$log" 2>/dev/null || true
    return 0
}

_stage_errors_log() {
    local stage="${1:-}" art="${ZBUILD_ARTIFACT_DIR:-${ZBUILD_STATE_DIR:+$ZBUILD_STATE_DIR/artifacts}}"
    [[ -n "$stage" && -n "$art" ]] || return 0
    printf '%s/%s-errors.log' "$art" "${stage//[^A-Za-z0-9_-]/_}"
}

# stage_errors_clear <stage> — empty the stage's error log, so it holds only the
# latest dispatch's errors.
stage_errors_clear() {
    local log; log="$(_stage_errors_log "${1:-}")"
    [[ -n "$log" && -e "$log" ]] && { : > "$log"; } 2>/dev/null || true
    return 0
}

# ─── stage_errors_append_file <stage> <file> [label] ────────────────────────
# The same, for a file a subprocess wrote (its stderr, a tool's log).
stage_errors_append_file() {
    local stage="${1:-${ZBUILD_CURRENT_STAGE:-}}" file="${2:-}" label="${3:-}"
    [[ -n "$file" && -s "$file" ]] || return 0
    [[ -n "$label" ]] && stage_errors_append "$stage" "--- $label ---"
    stage_errors_append "$stage" "$(cat "$file" 2>/dev/null || true)"
    return 0
}
