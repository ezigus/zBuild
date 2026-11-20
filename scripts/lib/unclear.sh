#!/usr/bin/env bash
# scripts/lib/unclear.sh — what a stage finds unclear in the issue: one form,
# one validator, one way to judge a carried question, one way to show them
# (#2508, #2571, ADR-069 §12, ADR-064 §4).
#
# Any stage that reads the issue and finds words that could mean either of two
# things writes one line, outside any fenced block, and acts on its assumption:
#   UNCLEAR <id> | "<the issue's unclear words, quoted>" | <the readings> | ASSUMED: <the reading chosen and acted on>
# The quote is checked against the issue; a line with no assumption is refused.
# It is about what the issue means, never how to build it, and never takes the
# place of a verdict. A design written before #2571 holds the old form,
#   UNCLEAR: <id> | <the question> | <what it assumed>
# which is still read (its question as the readings), never written.
#
# The API, for every stage that asks the issue's owner a question:
#   ZB_UNCLEAR_FORM, ZB_UNCLEAR_RULES      the form, and the rule a writer is told
#   ZB_UNCLEAR_NOT_YOURS                   the rule a stage that works from the design is told
#   zb_unclear_lines_v / _text_v           every UNCLEAR line of a file / a text
#   zb_unclear_parse_v                     a line → id, quote, readings, assumed, form
#   zb_unclear_check_v                     a line a stage just wrote: in the one form?
#                                          (with a seen-ids array: one question per id)
#   zb_unclear_list_v                      every readable question of a file, parsed
#   zb_unclear_judge_block_v               the block a stage's check is shown
#   zb_unclear_answer_v / zb_unclear_answers_v   the check's answers → kept / dropped
#   zb_unclear_finding_v                   a dropped question → the raising stage's finding
#   zb_unclear_dropped_json_v              the dropped questions → JSON for data.unclear_dropped
#   zb_unclear_cap_v, ZB_UNCLEAR_MAX       at most 20 questions carried, the rest noted
#   zb_unclear_result_json_v               the questions → JSON for the result's data.unclear
#   zb_unclear_result_lines_v              a result's data.unclear → the lines (no fork)
#   zb_unclear_dropped_lines_v             a result's data.unclear_dropped → the retired ones (no fork)
#   zb_unclear_result_ok                   a stage result of this run, small enough, with questions
#   zb_unclear_results_in_v                the results in a folder that carry questions
#   zb_unclear_markdown_v / zb_unclear_markdown   the reports' questions section
# Only the raising stage retires its question: its own check judges what it
# carried. Where its questions live: design's in its design file; any other
# stage's in its result, data.unclear, an array of lines in the one form; the
# ones its check retired in data.unclear_dropped, each with its WHY, QUOTE and
# the question, so no retirement is silent: the reports show them as retired.
# The reports' side is in unclear-report.sh.
# One question per requirement id: a second one on the same requirement takes
# its own id, <id>a and <id>b (zb_unclear_check_v refuses a repeat). Lines
# carried from before that rule which share an id are one question: one answer
# settles every line with that id.
#
# Sourced library: no set -euo pipefail. Nothing here forks: the run-status
# comment renders the questions on every tick.
[[ -n "${_ZBUILD_UNCLEAR_LOADED:-}" ]] && return 0
_ZBUILD_UNCLEAR_LOADED=1
# #2567 (ADR-060, ADR-069 §12): text a model wrote is read in whole units.
declare -F zb_reply_join_v >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/reply-units.sh"
# shellcheck source=judge-quotes.sh
declare -F judge_quote_check_v >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/judge-quotes.sh"

# shellcheck disable=SC2016  # the form is text, not an expansion
ZB_UNCLEAR_FORM='UNCLEAR <id> | "<the issue'"'"'s unclear words, quoted>" | <the readings> | ASSUMED: <the reading chosen and acted on>'
# At most this many questions a stage carries (#2571 review); a reader takes at
# most _ZB_UNCLEAR_READ_MAX lines of at most _ZB_UNCLEAR_LINE_MAX characters, from
# a result of at most _ZB_UNCLEAR_FILE_MAX characters.
ZB_UNCLEAR_MAX=20
_ZB_UNCLEAR_READ_MAX=50 _ZB_UNCLEAR_LINE_MAX=500 _ZB_UNCLEAR_FILE_MAX=1048576
# What a stage that reads the issue is told (#2571): put in its prompt as is.
# shellcheck disable=SC2034  # read by the stages' prompts (design's run.sh)
ZB_UNCLEAR_RULES="When the issue's words could mean either of two things, do not guess in
silence, and do not leave it undecided. Write one line for it, outside any
fenced block:
${ZB_UNCLEAR_FORM}
<id> is the id of the requirement it is about. The quote is the issue's own
words, copied from the issue as they are: they are checked against it. Give
the readings you see. Pick one reading and act on it: work as if it were the
answer. An UNCLEAR line is about what the issue means, never about how to
build it, and it never takes the place of a decision you can make yourself.
The question and your assumption are shown to the people who can answer it."
# What a stage that works from the design is told instead (#2571 R5): it asks
# the issue's owner nothing, and works to the assumption a stage stated.
# shellcheck disable=SC2034  # read by build's and test-author's prompts
ZB_UNCLEAR_NOT_YOURS="What is unclear to you about what the issue or the design means is the design's to settle, never yours. Never decide the issue's meaning yourself.
Work to the design. Work to the assumption a stage stated in an UNCLEAR line under Previous work: one you think wrong is a finding for the stage that raised it, never a silent override. When the design leaves something unclear, or a stated assumption looks wrong to you, answer the finding it bears on, on its own line:
    ANSWER <its id>: not mine — design must <what design must settle>: <why>"

# The old form (#2508): groups 1 id, 2 question, 3 assumed.
_ZB_UNCLEAR_RE='^[[:space:]]*UNCLEAR:[[:space:]]*([^|]*[^|[:space:]])[[:space:]]*\|[[:space:]]*([^|]*[^|[:space:]])[[:space:]]*\|[[:space:]]*(.*[^[:space:]])[[:space:]]*$'
# The one form's head: group 1 the id, 2 the rest.
_ZB_UNCLEAR_ONE_RE='^[[:space:]]*UNCLEAR[[:space:]]+([^|:[:space:]]+)[[:space:]]*\|(.*)$'
# The assumption, the last ASSUMED: after a `|` or a space, in any case.
_ZB_UNCLEAR_ASSUMED_RE='^(.*)(\||[[:space:]])[[:space:]]*[Aa][Ss][Ss][Uu][Mm][Ee][Dd][[:space:]]*:(.*)$'

_zb_unclear_trim_v() {
    local -n _zut="$1"; _zut="${2#"${2%%[![:space:]]*}"}"; _zut="${_zut%"${_zut##*[![:space:]]}"}"
}

# _zb_unclear_split_v <array_var> <fields> — <fields> split on tabs, an empty
# field kept (read would fold two tabs into one).
_zb_unclear_split_v() {
    local -n _zsp="$1"; local _zsp_s="$2"
    _zsp=()
    while [[ "$_zsp_s" == *$'\t'* ]]; do _zsp+=("${_zsp_s%%$'\t'*}"); _zsp_s="${_zsp_s#*$'\t'}"; done
    _zsp+=("$_zsp_s")
}

# zb_unclear_lines_text_v <array_var> <text> — every UNCLEAR line of <text>
# outside a fenced block, joined whole and trimmed, readable or not. An
# `ASSUMED:` a model wrapped onto a line of its own is part of the question above.
zb_unclear_lines_text_v() {
    local -n _zult="$1"; local _zult_j="" _zult_l _zult_in=0 _zult_prev=0
    _zult=()
    [[ "$2" == *UNCLEAR* ]] || return 0
    zb_reply_join_v _zult_j "${2//$'\r'/}"
    while IFS= read -r _zult_l; do
        if [[ "$_zult_l" =~ ^[[:space:]]*\`\`\` ]]; then _zult_in=$(( 1 - _zult_in )); _zult_prev=0; continue; fi
        _zb_unclear_trim_v _zult_l "$_zult_l"
        zb_unclear_plain_v _zult_l "$_zult_l"
        if (( _zult_in == 0 && _zult_prev )) && [[ "$_zult_l" =~ ^ASSUMED[[:space:]]*: \
                && ! "${_zult[-1]}" =~ $_ZB_UNCLEAR_ASSUMED_RE ]]; then
            _zult[-1]+=" | $_zult_l"; _zult_prev=0; continue
        fi
        _zult_prev=0
        (( _zult_in == 0 )) && [[ "$_zult_l" =~ ^UNCLEAR(:|[[:space:]]) ]] || continue
        _zult+=("$_zult_l"); _zult_prev=1
    done <<< "$_zult_j"
    return 0
}

# zb_unclear_plain_v <var> <line> — <line> without a list mark, numbering, quote
# or heading mark, or bold and code marks around it: a question is read the
# same however a model formats its line (#2571).
zb_unclear_plain_v() {
    local -n _zup="$1"; local _zup_l="${2#"${2%%[![:space:]>#]*}"}"
    [[ "$_zup_l" =~ ^([-*+]|[0-9]+[.\)])[[:space:]]+(.*)$ ]] && _zup_l="${BASH_REMATCH[2]}"
    _zup_l="${_zup_l#"${_zup_l%%[![:space:]*_\`]*}"}"; _zup="${_zup_l%"${_zup_l##*[![:space:]*_\`]}"}"
}

# zb_unclear_lines_v <array_var> <file> — the same, of a file (a design).
zb_unclear_lines_v() {
    local -n _zun="$1"; local _zun_f="${2:-}" _zun_txt=""
    _zun=()
    [[ -n "$_zun_f" && -f "$_zun_f" ]] || return 0
    IFS= read -r -d '' _zun_txt < "$_zun_f" || true
    zb_unclear_lines_text_v "$1" "$_zun_txt"
}

# zb_unclear_parse_v <var> <line> — rc 0 when <line> is a readable question,
# "<id><TAB><quote><TAB><readings><TAB><assumed><TAB><form>" into <var>; <form>
# is `one`, or `old` for a line written before #2571 (its question is the
# readings, its quote empty). A question with no assumption is none.
zb_unclear_parse_v() {
    local -n _zup="$1"; local _zup_id _zup_r _zup_q _zup_rd _zup_a
    _zup=""
    if [[ "$2" =~ $_ZB_UNCLEAR_ONE_RE ]]; then
        _zup_id="${BASH_REMATCH[1]}"; _zup_r="${BASH_REMATCH[2]}"
        [[ "$_zup_r" =~ $_ZB_UNCLEAR_ASSUMED_RE ]] || return 1
        _zup_r="${BASH_REMATCH[1]}"; _zb_unclear_trim_v _zup_a "${BASH_REMATCH[3]}"
        [[ "$_zup_r" == *"|"* ]] || return 1
        _zb_unclear_trim_v _zup_q "${_zup_r%%|*}"; _zb_unclear_trim_v _zup_rd "${_zup_r#*|}"
        _zup_rd="${_zup_rd%|}"; _zb_unclear_trim_v _zup_rd "$_zup_rd"
        _zup_q="${_zup_q#[\"“]}"; _zup_q="${_zup_q%[\"”]}"; _zb_unclear_trim_v _zup_q "$_zup_q"
        [[ -n "$_zup_q" && -n "$_zup_rd" && -n "$_zup_a" ]] || return 1
        _zup="$_zup_id"$'\t'"$_zup_q"$'\t'"$_zup_rd"$'\t'"$_zup_a"$'\t'one
        return 0
    fi
    [[ "$2" =~ $_ZB_UNCLEAR_RE ]] || return 1
    _zup_id="${BASH_REMATCH[1]}"; _zup_q="${BASH_REMATCH[2]}"; _zup_a="${BASH_REMATCH[3]}"
    # A leading "Assumed:" is set aside; one that is all there is, is none (#2567).
    [[ "$_zup_a" =~ ^[Aa][Ss][Ss][Uu][Mm][Ee][Dd][[:space:]]*:[[:space:]]*(.*)$ ]] && _zup_a="${BASH_REMATCH[1]}"
    [[ -n "${_zup_a//[[:space:]]/}" ]] || return 1
    _zup="$_zup_id"$'\t\t'"$_zup_q"$'\t'"$_zup_a"$'\t'old
    return 0
}

# zb_unclear_check_v <why_var> <line> [issue_text] [seen_assoc] — rc 0 when
# <line>, which a stage just wrote, is in the one form with an assumption and
# its quote is the issue's words (matched against the issue's text, never read
# as a file). Otherwise rc 1, <why_var> saying what is wrong in words for the
# stage. With no issue text the quote is not checked. [seen_assoc], an
# associative array the caller keeps across one stage's lines, refuses a second
# question on an id already seen, and records the id of a line that passes.
zb_unclear_check_v() {
    local -n _zuc="$1"; local _zuc_p _zuc_q _zuc_id
    _zuc=""
    if [[ "$2" =~ ^[[:space:]]*UNCLEAR: ]]; then
        _zuc="is in the old form — write it as $ZB_UNCLEAR_FORM"; return 1
    fi
    if ! [[ "$2" =~ $_ZB_UNCLEAR_ONE_RE ]]; then
        _zuc="is not in its form — write it as $ZB_UNCLEAR_FORM, every part on one line"; return 1
    fi
    if ! [[ "${BASH_REMATCH[2]}" =~ $_ZB_UNCLEAR_ASSUMED_RE ]] || [[ -z "${BASH_REMATCH[3]//[[:space:]]/}" ]]; then
        _zuc="has no ASSUMED: every UNCLEAR line picks a reading and acts on it — write it as $ZB_UNCLEAR_FORM"; return 1
    fi
    if ! zb_unclear_parse_v _zuc_p "$2"; then
        _zuc="is missing its quote or its readings — write it as $ZB_UNCLEAR_FORM"; return 1
    fi
    local -a _zuc_f=(); _zb_unclear_split_v _zuc_f "$_zuc_p"; _zuc_id="${_zuc_f[0]}"; _zuc_q="${_zuc_f[1]}"
    if [[ -n "${3:-}" ]] && ! _judge_holds "$3" "$_zuc_q"; then
        _zuc="quotes words that are not in the issue: $_zuc_q — copy the issue's own words, as they are"; return 1
    fi
    if [[ -n "${4:-}" ]]; then
        local -n _zuc_seen="$4"
        if [[ -n "${_zuc_seen[$_zuc_id]+x}" ]]; then
            _zuc="is a second question on $_zuc_id: one question per id — give each its own id, ${_zuc_id}a and ${_zuc_id}b"; return 1
        fi
        _zuc_seen["$_zuc_id"]=1
    fi
    return 0
}

# _zb_unclear_words_hold <text> <quote> — rc 0 when <text> holds <quote> as
# whole words, spacing and the marks a quote may drop aside (_judge_marks_v);
# a backslash escape is read as the character it stands for, as _judge_holds does.
_zb_unclear_words_hold() {
    local _zwh_t _zwh_q _zwh_r _zwh_pre _zwh_post _zwh_try _zwh_u
    _judge_marks_v _zwh_t "$1"; _judge_words_v _zwh_t "$_zwh_t"; _zwh_t=" $_zwh_t "
    _zwh_u="${2//\\\\/$'\x01'}"; _zwh_u="${_zwh_u//\\/}"; _zwh_u="${_zwh_u//$'\x01'/\\}"
    for _zwh_try in "$2" "$_zwh_u"; do
        _judge_marks_v _zwh_q "$_zwh_try"; _judge_words_v _zwh_q "$_zwh_q"
        [[ -n "$_zwh_q" ]] || continue
        _zwh_r="$_zwh_t"
        while [[ "$_zwh_r" == *"$_zwh_q"* ]]; do
            _zwh_pre="${_zwh_r%%"$_zwh_q"*}"; _zwh_post="${_zwh_r#*"$_zwh_q"}"
            [[ "${_zwh_pre: -1}" != [[:alnum:]] && "${_zwh_post:0:1}" != [[:alnum:]] ]] && return 0
            _zwh_r="${_zwh_r#"$_zwh_pre"?}"
        done
    done
    return 1
}

# zb_unclear_list_v <array_var> <file> — each readable question of <file>,
# parsed (zb_unclear_parse_v). A line that is not one is left out.
zb_unclear_list_v() {
    local -n _zul="$1"; local -a _zul_all=(); local _zul_l _zul_q
    _zul=()
    zb_unclear_lines_v _zul_all "${2:-}"
    for _zul_l in ${_zul_all[@]+"${_zul_all[@]}"}; do
        zb_unclear_parse_v _zul_q "$_zul_l" && _zul+=("$_zul_q")
    done
    return 0
}

# zb_unclear_judge_block_v <var> <carried> — the block a stage's own check is
# shown to judge the questions the stage carries (<carried>: their lines, one
# per line, as written), or empty when it carries none. Its answers are read
# by zb_unclear_answers_v.
zb_unclear_judge_block_v() {
    local -n _zjb="$1"
    _zjb=""
    [[ -n "${2//[[:space:]]/}" ]] || return 0
    _zjb="QUESTIONS — what was found unclear in the issue earlier, each with the reading the work went on with. Judge each against the issue as it is now:
${2%$'\n'}

One line for every question, by its id:

UNCLEAR <id>: answered | WHY: <how the issue answers it> | QUOTE: <the issue's words that answer it>
UNCLEAR <id>: not needed | WHY: <the requirement it was about is gone or rewritten>
UNCLEAR <id>: open

answered — the issue's words settle it now. The QUOTE is copied from the issue as it is, with no quote marks around it; it is checked.
not needed — the requirement it was about is gone from the issue or rewritten.
open — the issue still leaves it unclear."
}

# zb_unclear_answer_v <out_var> <why_var> <line> [issue_text] [question] — one
# line of a check's reply. rc 2 when it is no answer to a question; rc 1 when it
# is one that cannot be used, <why_var> saying why; rc 0 with
# "<id><TAB><answered|not needed|open><TAB><why><TAB><quote>" in <out_var>.
# An answered quote (#2571 review) is at least three words, is not inside the
# question's own quoted words ([question]: its line as carried; an old-form
# one's question), and is in the issue's text as whole words when there is one.
zb_unclear_answer_v() {
    local -n _zua="$1" _zuw="$2"; local _zua_l _zua_id _zua_v _zua_why _zua_q _zua_qp _zua_own
    _zua=""; _zuw=""
    judge_reply_line_v _zua_l "$3"
    [[ "$_zua_l" =~ ^UNCLEAR[[:space:]]+([^[:space:]:|]+)[[:space:]]*:[[:space:]]*([^|]*) ]] || return 2
    _zua_id="${BASH_REMATCH[1]}"; _zb_unclear_trim_v _zua_v "${BASH_REMATCH[2],,}"
    judge_reply_field_v _zua_why "$_zua_l" WHY; judge_reply_field_v _zua_q "$_zua_l" QUOTE
    case "$_zua_v" in
        open) _zua_why=""; _zua_q="" ;;
        "not needed"|not-needed)
            _zua_v="not needed"; _zua_q=""
            [[ -n "$_zua_why" ]] || { _zuw="UNCLEAR $_zua_id: not needed has no WHY — say what of the issue's requirement is gone or rewritten"; return 1; } ;;
        answered)
            [[ -n "$_zua_why" ]] || { _zuw="UNCLEAR $_zua_id: answered has no WHY"; return 1; }
            [[ -n "$_zua_q" ]] || { _zuw="UNCLEAR $_zua_id: answered has no QUOTE of the issue's words"; return 1; }
            local -a _zua_ws=(); read -r -a _zua_ws <<< "$_zua_q"
            (( ${#_zua_ws[@]} >= 3 )) || { _zuw="UNCLEAR $_zua_id's quote is too short to answer it: copy at least three words of the issue that settle it"; return 1; }
            if [[ -n "${5:-}" ]] && zb_unclear_parse_v _zua_qp "$5"; then
                local -a _zua_f=(); _zb_unclear_split_v _zua_f "$_zua_qp"
                _zua_own="${_zua_f[1]}"; [[ -n "$_zua_own" ]] || _zua_own="${_zua_f[2]}"
                if _judge_holds "$_zua_own" "$_zua_q"; then
                    _zuw="UNCLEAR $_zua_id's quote is the question's own words, which do not answer it: quote the other words of the issue that settle it"; return 1
                fi
            fi
            if [[ -n "${4:-}" ]] && ! _zb_unclear_words_hold "$4" "$_zua_q"; then
                _zuw="UNCLEAR $_zua_id's quote is not in the issue as whole words: $_zua_q"; return 1
            fi ;;
        *) _zuw="UNCLEAR $_zua_id is answered, not needed or open, not $_zua_v"; return 1 ;;
    esac
    _zua="$_zua_id"$'\t'"$_zua_v"$'\t'"$_zua_why"$'\t'"$_zua_q"
    return 0
}

# zb_unclear_answers_v <kept_array> <dropped_array> <problem_var> <reply> <carried> [issue_text]
# — the check's answers to the questions <carried> (their lines, one per line):
# the ids still open into <kept_array>; each answered or not-needed one, as
# zb_unclear_answer_v gives it, into <dropped_array>; <problem_var> empty, or
# what makes the answers unusable — a line that cannot be used, a question with
# no line — for the check to be asked again. An id not carried is left alone:
# only the raising stage's own questions are its check's to judge.
zb_unclear_answers_v() {
    local -n _zas_k="$1" _zas_d="$2" _zas_p="$3"; local _zas_j="" _zas_l _zas_x _zas_w _zas_rc _zas_id _zas_v
    local -A _zas_c=() _zas_seen=(); local -a _zas_ids=() _zas_bad=()
    _zas_k=(); _zas_d=(); _zas_p=""
    while IFS= read -r _zas_l; do
        zb_unclear_parse_v _zas_x "$_zas_l" || continue
        _zas_id="${_zas_x%%$'\t'*}"; [[ -n "${_zas_c[$_zas_id]+x}" ]] && continue
        _zas_c["$_zas_id"]="$_zas_l"; _zas_ids+=("$_zas_id")
    done <<< "$5"
    zb_reply_join_v _zas_j "$4"
    while IFS= read -r _zas_l; do
        _zas_id=""; [[ "$_zas_l" =~ UNCLEAR[[:space:]]+([^[:space:]:|*\`]+) ]] && _zas_id="${BASH_REMATCH[1]}"
        _zas_rc=0; zb_unclear_answer_v _zas_x _zas_w "$_zas_l" "${6:-}" "${_zas_id:+${_zas_c[$_zas_id]:-}}" || _zas_rc=$?
        (( _zas_rc == 2 )) && continue
        if (( _zas_rc == 1 )); then
            _zas_id="${_zas_w#UNCLEAR }"; _zas_id="${_zas_id%%[: \']*}"
            [[ -n "${_zas_c[$_zas_id]+x}" && -z "${_zas_seen[$_zas_id]+x}" ]] || continue
            _zas_seen["$_zas_id"]=1; _zas_bad+=("$_zas_w"); continue
        fi
        _zas_id="${_zas_x%%$'\t'*}"
        [[ -n "${_zas_c[$_zas_id]+x}" && -z "${_zas_seen[$_zas_id]+x}" ]] || continue
        _zas_seen["$_zas_id"]=1
        _zas_v="${_zas_x#*$'\t'}"; _zas_v="${_zas_v%%$'\t'*}"
        if [[ "$_zas_v" == open ]]; then _zas_k+=("$_zas_id"); else _zas_d+=("$_zas_x"); fi
    done <<< "$_zas_j"
    for _zas_id in ${_zas_ids[@]+"${_zas_ids[@]}"}; do
        [[ -n "${_zas_seen[$_zas_id]+x}" ]] || _zas_bad+=("no line for UNCLEAR $_zas_id")
    done
    if [[ ${#_zas_bad[@]} -gt 0 ]]; then
        local IFS=';'; _zas_p="${_zas_bad[*]}"; _zas_p="${_zas_p//;/; }"
    fi
    return 0
}

# zb_unclear_finding_v <var> <dropped> <STAGE> — a dropped question as a
# finding for the stage that raised it, marked [FIX IN <STAGE>: …]: drop the
# line and, for one the issue answers, follow the issue's words.
zb_unclear_finding_v() {
    local -n _zuf="$1"; local -a _zuf_f=(); local _zuf_id _zuf_v _zuf_why _zuf_q
    _zb_unclear_split_v _zuf_f "$2"
    _zuf_id="${_zuf_f[0]}"; _zuf_v="${_zuf_f[1]:-}"; _zuf_why="${_zuf_f[2]:-}"; _zuf_q="${_zuf_f[3]:-}"
    if [[ "$_zuf_v" == answered ]]; then
        _zuf="UNCLEAR $_zuf_id: the issue now answers it: $_zuf_why — $_zuf_q [FIX IN ${3}: ACCEPTED IF: the UNCLEAR $_zuf_id line is gone, and the work follows the issue's words where they differ from its assumption]"
    else
        _zuf="UNCLEAR $_zuf_id: no longer needed: $_zuf_why [FIX IN ${3}: ACCEPTED IF: the UNCLEAR $_zuf_id line is gone]"
    fi
}

# zb_unclear_cap_v <array_name> <note_var> — at most ZB_UNCLEAR_MAX questions
# kept, the first ones; <note_var> says how many were left out, or is empty.
zb_unclear_cap_v() {
    local -n _zcp="$1" _zcp_n="$2"; local _zcp_c=${#_zcp[@]}
    _zcp_n=""
    (( _zcp_c > ZB_UNCLEAR_MAX )) || return 0
    _zcp=("${_zcp[@]:0:ZB_UNCLEAR_MAX}")
    _zcp_n="$(( _zcp_c - ZB_UNCLEAR_MAX )) more questions were not carried: a stage carries at most $ZB_UNCLEAR_MAX"
}

# The reports' side — a stage's result, read and written, and the questions
# section every report shows — is in unclear-report.sh.
# shellcheck source=unclear-report.sh
source "${BASH_SOURCE[0]%/*}/unclear-report.sh"
