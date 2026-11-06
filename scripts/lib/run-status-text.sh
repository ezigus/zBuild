#!/usr/bin/env bash
# scripts/lib/run-status-text.sh — what a row of the run-status comment says
# (#2131, ADR-064 §4): a stage's findings and its summary's first line, as
# text. Sourced by run-status-render.sh; split from it (#2480) to keep each
# under 500 lines. Pure: reads files, writes nothing.

[[ -n "${_ZBUILD_RUN_STATUS_TEXT_LOADED:-}" ]] && return 0 2>/dev/null
_ZBUILD_RUN_STATUS_TEXT_LOADED=1

# rsc_row_findings_v <var> <state_dir> <stage> [result_path] — what a try that
# did not pass found (ADR-064 §4, #2476, #2480): "what failed: <the finding>",
# or the requirements and SPECs several are about ("what failed: `LOOP-1`,
# `GUAR-2`"), else "what failed: <n> findings", and what more there is folded
# under it; empty
# when its result holds none. The
# result is the stage's primary output (a map member's is named on its event),
# else `artifacts/<stage>-result.json`. A finding is its text, as
# stage_findings_json writes it, or a lens's severity, message and file.
rsc_row_findings_v() {
    local _rfv_p="${4:-}" _rfv_m="" _rfv_raw="" _rfv_l
    printf -v "$1" '%s' ""
    if [[ -z "$_rfv_p" ]] && declare -F _inputs_stage_manifest_v >/dev/null 2>&1 \
            && declare -F _verdict_primary_output_path_v >/dev/null 2>&1; then
        _inputs_stage_manifest_v _rfv_m "$3" "${ZBUILD_PLUGINS_ROOT:-$_RSC_ROOT/plugins}" 2>/dev/null || true
        [[ -n "$_rfv_m" && -f "$_rfv_m" ]] && _verdict_primary_output_path_v _rfv_raw "$_rfv_m"
        [[ -n "$_rfv_raw" ]] && _rfv_p="$(_inputs_output_paths "$3" "$_rfv_raw" "$2" 2>/dev/null || true)"
    fi
    [[ -n "$_rfv_p" && -s "$_rfv_p" ]] || _rfv_p="$2/artifacts/${3}-result.json"
    [[ -s "$_rfv_p" && "$(<"$_rfv_p")" == *'"findings"'* ]] || return 0
    # #2480: one finding heads the row, the rest of its lines folded; several
    # are named by the id each is about, or counted (by severity when they
    # carry one), and each is listed once.
    _rfv_l="$(jq -r "$_RSC_JQ_ESC"'[ ((.data.findings // .findings // [])[]? | select(type == "object")
            | {sev: (if (.severity | type) == "string" then (.severity | ascii_downcase) else null end),
               t: (if (.text | type) == "string" then .text
                   elif (.message | type) == "string" then
                       (if (.severity | type) == "string" then "\(.severity): " else "" end) + .message
                       + (if (.file // "unknown") != "unknown" then " (\(.file)\(if .line then ":\(.line)" else "" end))" else "" end)
                   else null end)}
            | select(.t != null) | .t |= (gsub("\r"; "") | gsub("\n+$"; "") | esc) | select(.t | test("[^[:space:]]"))) ] as $f
        | if ($f | length) == 0 then ""
          elif ($f | length) == 1 then
            ($f[0].t | split("\n")) as $ls
            | "what failed: " + ($ls[0] | gsub("\\|"; "\\|"))
              + (if ($ls | length) > 1 then
                  "\n<details><summary>what failed</summary>\n\n- " + ($ls[1:] | join("\n  ")) + "\n\n</details>"
                else "" end)
          else
            ([$f[] | .sev | select(. != null)]) as $sv
            | (["critical", "high", "medium", "low"]
               | map(. as $k | ([$sv[] | select(. == $k)] | length) as $c | select($c > 0) | "\($c) \($k)")) as $cnt
            # The requirement or SPEC each is about: the first id on its first
            # line. Named when every finding has one and none has a severity.
            | [$f[] | .t | split("\n")[0]
               | [match("(?<![A-Za-z0-9-])[A-Z][A-Z0-9]{2,3}-[0-9]+(?![0-9])"; "g").string][0]] as $ids
            | (if ($sv | length) == 0 and all($ids[]; . != null)
               then "what failed: " + ($ids | reduce .[] as $i ([]; if index([$i]) then . else . + [$i] end)
                                           | map("`" + . + "`") | join(", "))
               else "what failed: \($f | length) findings" + (if ($cnt | length) > 0 then ": " + ($cnt | join(", ")) else "" end) end)
              + "\n<details><summary>what failed</summary>\n\n"
              + ([$f[] | "- " + (.t | gsub("\n"; "\n  "))] | join("\n")) + "\n\n</details>"
          end' "$_rfv_p" 2>/dev/null || true)"
    [[ -n "$_rfv_l" ]] || return 0
    _rsc_code_labels_v _rfv_l "$_rfv_l"
    printf -v "$1" '%s' "$_rfv_l"
}

# _rsc_first_line_v <var> <summary_file> — the first line with a non-blank
# character that is not a heading, `- ` stripped, `|` escaped, whole; the rest
# folded under it.
_rsc_first_line_v() {
    local _rsv_p="$2" _rsv_l=""
    printf -v "$1" '%s' ""
    [[ -s "$_rsv_p" ]] || return 0
    # The first line with a non-blank character that is not a heading, read by
    # the shell (it was an awk: `NF && $0 !~ /^#/`).
    local _rsv_found=0 _rsv_rest="" _rsv_x
    while IFS= read -r _rsv_x || [[ -n "$_rsv_x" ]]; do
        if (( _rsv_found )); then
            _rsv_rest+="${_rsv_x}"$'\n'
        elif [[ "$_rsv_x" =~ [^[:space:]] && "$_rsv_x" != \#* ]]; then
            _rsv_found=1; _rsv_l="$_rsv_x"
        fi
    done < "$_rsv_p"
    (( _rsv_found )) || return 0
    _rsv_l="${_rsv_l#- }"
    _rsc_text_v _rsv_l "$_rsv_l"
    _rsv_l="${_rsv_l//|/\\|}"
    # The rest, without its leading and trailing blank lines.
    while [[ "$_rsv_rest" == $'\n'* ]]; do _rsv_rest="${_rsv_rest#$'\n'}"; done
    while [[ "$_rsv_rest" == *$'\n' ]]; do _rsv_rest="${_rsv_rest%$'\n'}"; done
    _rsc_text_v _rsv_rest "$_rsv_rest"
    [[ "$_rsv_rest" =~ [^[:space:]] ]] \
        && _rsv_l+=$'\n'"<details><summary>the rest of what it reported</summary>"$'\n\n'"${_rsv_rest}"$'\n\n'"</details>"
    _rsc_code_labels_v _rsv_l "$_rsv_l"
    printf -v "$1" '%s' "$_rsv_l"
}

# _rsc_text_v <var> <text> — what a stage wrote, as text (#2480, ADR-064 §4):
# `<` and `>` outside a code span become &lt; and &gt;, so GitHub never takes
# `<s>` for a tag; inside one they stay. Read by the shell, appended piece by
# piece: a pattern replacement's `&` means the match in bash 5.2.
_rsc_text_v() {
    local -n _rtv="$1"; local _rt_in="$2" _rt_out="" _rt_seg _rt_code=0
    while [[ "$_rt_in" == *'`'* ]]; do
        _rt_seg="${_rt_in%%\`*}"; _rt_in="${_rt_in#*\`}"
        if (( _rt_code )); then _rt_out+="$_rt_seg"; else _rsc_text_plain "$_rt_seg"; fi
        _rt_out+='`'; _rt_code=$(( 1 - _rt_code ))
    done
    # A backtick with no partner opens no span (review on #2481): what follows
    # it is text.
    _rsc_text_plain "$_rt_in"
    _rtv="$_rt_out"
}
# _rsc_text_plain <text> — <text> outside a code span, escaped, appended to
# _rt_out, the local of its caller _rsc_text_v (bash's dynamic scope).
_rsc_text_plain() {
    local _rtp="$1"
    while [[ "$_rtp" == *[\<\>]* ]]; do
        _rt_out+="${_rtp%%[\<\>]*}"; _rtp="${_rtp#"${_rtp%%[\<\>]*}"}"
        if [[ "$_rtp" == \<* ]]; then _rt_out+='&lt;'; else _rt_out+='&gt;'; fi
        _rtp="${_rtp:1}"
    done
    _rt_out+="$_rtp"
}

# _rsc_code_labels_v <var> <text> — each requirement label, `[#1805/FSTG-1]`
# (#2462: any SPEC id, descriptive or the old SPEC-3),
# shown as code (#2460): GitHub links `#1805` and shows the issue's title in its
# place. One already between backticks is left as it is. Read by the shell.
_rsc_code_labels_v() {
    local -n _rcl="$1"; local _in="$2" _out="" _pre _lbl
    local _re='\[#[0-9]+/[A-Z][A-Z0-9][A-Z0-9][A-Z0-9]?-[0-9]+\]'
    while [[ "$_in" =~ $_re ]]; do
        _lbl="${BASH_REMATCH[0]}"; _pre="${_in%%"$_lbl"*}"
        if [[ "$_pre" == *'`' ]]; then _out+="$_pre$_lbl"; else _out+="$_pre\`$_lbl\`"; fi
        _in="${_in#*"$_lbl"}"
    done
    _rcl="$_out$_in"
}
