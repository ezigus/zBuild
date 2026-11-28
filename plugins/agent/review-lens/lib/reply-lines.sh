#!/usr/bin/env bash
# plugins/agent/review-lens/lib/reply-lines.sh — a lens answers in plain lines,
# like every other judge (#2598, ADR-038, ADR-072 §3): nothing in the answer is
# escaped, so a quote is the file's text as it is. #2532 run 45231040380 lost a
# run to a JSON quote of `\n` read as a line break.
#
# The answer:
#   SCORE: <0-10>
#   FINDING                         one block per finding (the word alone on
#                                   its line), a field per line:
#   severity: / category: / fix: / introduced: yes|no
#   quote: <file> | <the line>      also at: <file> | <the line>  (one each)
#   message: / trigger: / accepted if:
#   SUSPICION                       quote: / suspicion: / confirm by: / fix:
#   UNCLEAR <id> | …                a question (the shared form)
#   UNCLEAR <id>: <answer>          an answer to a carried question, its why:
#                                   and quote: lines under it (#2640), read
#                                   into the one line the other checks read:
#                                   `UNCLEAR <id>: <answer> | WHY: … | QUOTE: …`
# A line with no key carries on the field above it, up to a blank line. A list mark, bold or a
# backtick around a key is set aside. Read into the object the rest of the lens
# reads: {score, findings[], unclear[], unclear_answers[]}.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_REPLY_LINES_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_REPLY_LINES_LOADED=1

# shellcheck disable=SC2016  # jq's $vars, not the shell's
_RL_LINES_JQ='
def bare: sub("^[[:space:]]*(#+[[:space:]]+)?([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)?"; "")
    | sub("^(\\*\\*|__|`)(?<k>[A-Za-z][A-Za-z0-9 _#-]*:?)(\\*\\*|__|`)"; "\(.k)")
    | sub("^(?<k>[A-Za-z][A-Za-z _-]*)[[:space:]]*(\\*\\*|__|`)[[:space:]]*:"; "\(.k):");
# Only the fields a finding or suspicion has are keys: any other line, such
# as a wrapped "Note: …", carries on the field above it (review on #2598).
def key: ((capture("^(?<k>[A-Za-z][A-Za-z _-]*?)[[:space:]]*:") | .k | ascii_downcase | gsub("[[:space:]-]+"; "_")) // null) as $k
    | if $k != null and ($k | IN("severity", "category", "fix", "introduced", "quote", "message", "trigger", "accepted_if", "also_at", "file", "suspicion", "confirm_by")) then $k else null end;
def kv: capture("^(?<k>[A-Za-z][A-Za-z _-]*?)[[:space:]]*:[[:space:]]*(?<v>.*)$");
def fq: (index(" | ") // -1) as $i
    | if $i >= 0 then {file: (.[:$i] | gsub("^[`*\\s]+|[`*\\s]+$"; "")), quote: .[$i + 3:]} else {file: "", quote: .} end;
def yes: ascii_downcase | test("^(yes|true|y)\\b");
def put($k; $v):
    if .kind == "f" then
        if $k == "quote" then .findings[-1] += ($v | fq)
        elif $k == "also_at" then .findings[-1].also_at += [$v]
        elif $k == "introduced" then .findings[-1].introduced = ($v | yes)
        else .findings[-1][$k] = $v end
    elif .kind == "s" then
        if $k == "quote" then .unclear[-1] += ($v | fq) else .unclear[-1][$k] = $v end
    else . end | .last = $k;
split("\n") | map(sub("\r$"; "") | bare)
| reduce .[] as $l ({score: null, findings: [], unclear: [], unclear_answers: [], kind: null, last: null, stray: false, stray_line: null};
    if ($l | test("^[[:space:]]*$")) then .last = null | (if .kind == "a" then .kind = null else . end)
    elif ($l | test("^FINDING([[:space:]]+#?[0-9]+)?[[:space:]]*:?[[:space:]]*$"; "i")) then .kind = "f" | .last = null | .findings += [{also_at: []}]
    elif ($l | test("^SUSPICION([[:space:]]+#?[0-9]+)?[[:space:]]*:?[[:space:]]*$"; "i")) then .kind = "s" | .last = null | .unclear += [{}]
    elif ($l | test("^UNCLEAR[[:space:]]+[^[:space:]|:]+[[:space:]]*\\|")) then .kind = null | .unclear += [$l]
    elif ($l | test("^UNCLEAR[[:space:]]+[^[:space:]|:]+[[:space:]]*:")) then .kind = "a" | .last = null | .unclear_answers += [$l]
    elif ($l | test("^SCORE[[:space:]]*:"; "i")) then .kind = null
        | .score = ($l | capture(":[[:space:]]*(?<n>[0-9]+)").n | tonumber? // null)
    # #2640: the why: and quote: lines under an answer join it, as the shared reader
    # joins them (zb_reply_join_v); a note: is set aside, and only the first
    # quote is read.
    elif .kind == "a" and ($l | test("^(why|quote|note)[[:space:]]*:"; "i")) then
        ($l | capture("^(?<k>[A-Za-z]+)[[:space:]]*:[[:space:]]*(?<v>.*)$")) as $m | ($m.k | ascii_downcase) as $k
        | if $k == "note" or ($k == "quote" and (.unclear_answers[-1] | test(" \\| QUOTE: "))) then .last = null
          else .unclear_answers[-1] += " | " + ($k | ascii_upcase) + ": " + $m.v | .last = $k end
    elif ($l | key) != null then
        if .kind == null or .kind == "a" then .stray = true | .stray_line = (.stray_line // $l)
        else ($l | kv) as $m | put($m.k | ascii_downcase | gsub("[[:space:]-]+"; "_"); $m.v) end
    elif .kind == "a" and .last == "why" and ($l | test("[^[:space:]]")) then .unclear_answers[-1] += " " + $l
    elif .kind != null and .kind != "a" and .last != null and ($l | test("[^[:space:]]"))
         and (.last | IN("message", "trigger", "accepted_if", "suspicion", "confirm_by")) then
        if .kind == "f" then .findings[-1][.last] += " " + $l else .unclear[-1][.last] += " " + $l end
    else . end)
| {score, findings, unclear, unclear_answers, stray, stray_line}'

# _rl_reply_lines_v <json_var> <reply> — the lens's line answer read into its
# object (one jq, the reply on stdin); empty when jq cannot read it.
_rl_reply_lines_v() {
    local -n _rrl="$1"
    _rrl="$(jq -Rsc "$_RL_LINES_JQ" <<< "$2" 2>/dev/null)" || _rrl=""
}
