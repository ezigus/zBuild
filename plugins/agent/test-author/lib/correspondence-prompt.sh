#!/usr/bin/env bash
# plugins/agent/test-author/lib/correspondence-prompt.sh — what test-author's
# assertion check is asked (#2370, ADR-073 §6). Split from correspondence.sh
# (#2569: under 500 lines); its callers are there.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TA_CORRESPONDENCE_PROMPT_LOADED:-}" ]] && return 0
_ZBUILD_TA_CORRESPONDENCE_PROMPT_LOADED=1

# _sc_spec_shown_v <var> <block> <sid> — a SPEC as its check is shown it: its
# words, then each part by the word design wrote (#2470). Kept with the
# check's verdict (#2579), and compared with it in test-author's own prompt.
_sc_spec_shown_v() {
    local -n _sss="$1"; local -a _sss_p=(); local _sss_x
    _sc_spec_parts_v _sss_p "$2" "$3"
    _sss="$_ACC_SPEC_TEXT"
    for _sss_x in ${_sss_p[@]+"${_sss_p[@]}"}; do _sss_x="${_sss_x#*$'\t'}"; _sss+=$'\n'"  ${_sss_x%%$'\t'*}: ${_sss_x#*$'\t'}"; done
}

# _ta_changed_specs_v <var> <artifact_dir> <block> <sid>... — for test-author's
# own prompt: each SPEC whose words changed since its check last judged it,
# with what it was (#2579, ADR-072 §4); empty when none did.
_ta_changed_specs_v() {
    local -n _tcs="$1"; local kf="${2%/}/test-author-judged.json" blk="$3" sid w e t
    shift 3; _tcs=""
    [[ -s "$kf" && $# -gt 0 ]] || return 0
    local -A _none=() _got=()
    judge_kept_get_all_v _got "$kf" _none
    for sid in "$@"; do
        _sc_spec_shown_v t "$blk" "$sid"
        judge_item_was_v w "$sid" "$t"; [[ -n "$w" ]] || continue
        judge_changed_entry_v e "$sid changed since you last answered it" "$w" "$t"; _tcs+="$e"
    done
    [[ -n "$_tcs" ]] && _tcs=$'\n'"These SPECs changed since your tests for them were last checked. Test the part that is new: \"done before\" does not cover it."$'\n'"$_tcs"
    return 0
}

# _sc_batch_prompt <ids_arr> <shown_arr> <srcs_arr> [files] [held] (namerefs)
# — each SPEC, shown with its parts as written, and the assertion tagged for
# it; one answer line for a SPEC whose test is right, one per part it is not
# (#2143, #2467, #2470). A one-SPEC call is the same prompt with one SPEC.
# [held]: its earlier findings on these SPECs and test-author's answers
# (judge_held_block_v, #2569). A SPEC whose words changed since it was last
# judged is shown as it was and is now (judge-changed.sh, #2579).
_sc_batch_prompt() {
    local -n _bp_ids="$1" _bp_txts="$2" _bp_srcs="$3"
    local _bp_files="${4:-}" _bp_held="${5:-}" _bp_c="" _bp_w _bp_e _bp_i
    for _bp_i in "${!_bp_ids[@]}"; do
        judge_item_was_v _bp_w "${_bp_ids[_bp_i]}" "${_bp_txts[_bp_i]}"; [[ -n "$_bp_w" ]] || continue
        judge_changed_entry_v _bp_e "${_bp_ids[_bp_i]}" "$_bp_w" "${_bp_txts[_bp_i]}"; _bp_c+="$_bp_e"
    done
    judge_changed_block_v _bp_c "$_bp_c"; _bp_held+="$_bp_c"
    cat <<'EOF'
You are checking acceptance requirements against the tests tagged as covering them, one SPEC at a time.

## What you own
For EACH SPEC, judge every part of it against its test, and the test's layout:
- a Given: does the test set it up?
- the When: does the test do it?
- a Then: does the test assert it — would the test fail if it were not so?
- cleanup: does the test change anything outside its own sandbox — an exported variable, a file outside its own folder, global config or git state — and not put it back?
- sections: is each part's code under its own heading — a comment, in the language's own form, marking Given, When and Then (and Cleanup, when the test puts something back)? The headings are the only comments you are shown.

A test aimed at the right thing but narrower than the part — fewer of its cases, a weaker check — does not do that part: answer missing, and say what it leaves out.

Answer at least one line for every SPEC, each starting with that SPEC's identifier from its `###` heading, exactly as written there. When its test does every part and is laid out in sections, one line:

<identifier>: ok

Otherwise one line for each thing wrong, and no ok line:

<identifier> <part>: missing | WHY: <what the test does not do> | ACCEPTED IF: <the SPEC's line the test must do, in its own words> | QUOTE: <that part's own words>
<identifier> <part>: wrong | WHY: <what the test does instead> | ACCEPTED IF: <the SPEC's line the test must do, in its own words> | QUOTE: <that part's own words>
<identifier> sections: missing | WHY: <which heading is not there, or which part's code is not under its own> | ACCEPTED IF: <the headings the test must have> | QUOTE: <test file> | <the heading or line of the test that shows it>
<identifier> cleanup: missing | WHY: <what the test leaves changed> | ACCEPTED IF: <what the test must put back> | QUOTE: <test file> | <the line that changes it>

<part> is the word the part's line starts with: Given, When, Then or And. The QUOTE is copied from that line, and says which line it is when the SPEC has several.

When no test could ever prove a SPEC — it describes what a file or a test contains, or it has no pass or fail — answer instead:

<identifier>: untestable | WHY: <why no test could prove it> | ACCEPTED IF: <the SPEC's line no test can prove, in its own words> | QUOTE: <the SPEC's own words>

ACCEPTED IF names the line you judge against: the SPEC's line the test must do, in its own words, so the finding says what would be accepted. A sections or cleanup line with no ACCEPTED IF cannot be used.

Copy each QUOTE as it is, with no quote marks around it: it is checked, and a quote that is not there cannot be used.

## What you judge against
The SPECs below, each a REQUIREMENT with its parts and the ASSERTION tagged as covering it. In each ASSERTION, the lines marked >> are the ones tagged for the requirement; the lines above them set up the test, and what they do counts. Each test file is also shown whole, under THE TEST FILES: setup anywhere in the file counts — a helper function, a block shared by several cases — so judge what the test really does, not only the lines next to the assertion. The failure you are looking for is a test that does something real and specific, but not what a part says — including its opposite.
EOF
    local _i
    for (( _i=0; _i<${#_bp_ids[@]}; _i++ )); do
        printf '\n### %s\nREQUIREMENT:\n%s\n\nASSERTION:\n%s\n' "${_bp_ids[_i]}" "${_bp_txts[_i]}" "${_bp_srcs[_i]}"
    done
    [[ -n "$_bp_files" ]] && printf '\nTHE TEST FILES:\n%s\n' "$_bp_files"
    [[ -n "$_bp_held" ]] && printf '%s\n' "$_bp_held"
    cat <<'EOF'

## What you must not do
- Judge what each test does, not what the code under test does: open the test files and any helper or fixture they use, never the code they test.
- Do not suggest a fix. Do not rewrite anything.
EOF
}

