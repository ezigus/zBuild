#!/usr/bin/env bash
# plugins/agent/test-author/lib/correspondence.sh — test-author's second model
# call: does each assertion test what its SPEC SAYS? (#2370; was the
# spec-correspondence stage, #2034, ADR-036.)
#
# A passing test proves the implementation satisfies the ASSERTION, never that
# the assertion satisfies the SENTENCE. This judges that link, before any code
# exists, from the requirement and the assertion alone.
#
# #2464 (ADR-072): the check judges — it reads files itself, read-only; each
# complaint quotes the requirement's words; and each SPEC's answer is kept while
# its requirement and its test are unchanged, and judged again when test-author
# disputes it. #2467 (ADR-073 §6): it judges every part of a SPEC — each Given
# set up, the When done, each Then asserted, each Cleanup put back — and the
# test's sections, and says which part falls short and why.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TA_CORRESPONDENCE_LOADED:-}" ]] && return 0
_ZBUILD_TA_CORRESPONDENCE_LOADED=1
# #2460: a reply is read in whole units; loaded here too, for a caller that
# sources this file alone.
declare -F zb_reply_join_v >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/reply-units.sh" 2>/dev/null || true
# shellcheck source=../../../../scripts/lib/judge.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/judge.sh"

_ta_sc_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# _sc_spec_parts_v <array_var> <block> <sid> — the parts the check judges, each
# "<label><TAB><word><TAB><words>": the label tells them apart (Then 2), the
# word is the one design wrote (And) — all a model is shown (#2470). A SPEC
# written on one line is judged with its words as its one Then.
_sc_spec_parts_v() {
    local -n _ssp="$1"; local -a _ssp_p=() _ssp_w=(); local _ssp_i
    _ssp=()
    _acceptance_spec_line "$2" "$3" || return 0
    acceptance_parts_v _ssp_p "$_ACC_SPEC_PARTS" "" _ssp_w
    for _ssp_i in "${!_ssp_p[@]}"; do
        _ssp+=("${_ssp_p[_ssp_i]%%$'\t'*}"$'\t'"${_ssp_w[_ssp_i]}"$'\t'"${_ssp_p[_ssp_i]#*$'\t'}")
    done
    [[ ${#_ssp[@]} -gt 0 ]] || _ssp=("Then 1"$'\t'"Then"$'\t'"${_ACC_SPEC_TEXT:-}")
}

# _sc_batch_prompt <ids_arr> <shown_arr> <srcs_arr> [files] (namerefs) — each
# SPEC, shown with its parts as written, and the assertion tagged for it; one
# answer line for a SPEC whose test is right, one per part it is not (#2143,
# #2467, #2470). A one-SPEC call is the same prompt with one SPEC.
_sc_batch_prompt() {
    local -n _bp_ids="$1" _bp_txts="$2" _bp_srcs="$3"
    local _bp_files="${4:-}"
    cat <<'EOF'
You are checking acceptance requirements against the tests tagged as covering them, one SPEC at a time.

## What you own
For EACH SPEC, judge every part of it against its test, and the test's layout:
- a Given: does the test set it up?
- the When: does the test do it?
- a Then: does the test assert it — would the test fail if it were not so?
- a Cleanup: does the test put it back?
- sections: is each part's code under its own heading — a comment, in the language's own form, marking Given, When and Then (and Cleanup, when the SPEC has one)? The headings are the only comments you are shown.

Answer at least one line for every SPEC, each starting with that SPEC's identifier from its `###` heading, exactly as written there. When its test does every part and is laid out in sections, one line:

<identifier>: ok

Otherwise one line for each thing wrong, and no ok line:

<identifier> <part>: missing | WHY: <what the test does not do> | QUOTE: <that part's own words>
<identifier> <part>: wrong | WHY: <what the test does instead> | QUOTE: <that part's own words>
<identifier> sections: missing | WHY: <which heading is not there, or which part's code is not under its own> | QUOTE: <test file> | <the heading or line of the test that shows it>

<part> is the word the part's line starts with: Given, When, Then, And or Cleanup. The QUOTE is copied from that line, and says which line it is when the SPEC has several.

When no test could ever prove a SPEC — it describes what a file or a test contains, or it has no pass or fail — answer instead:

<identifier>: untestable | WHY: <why no test could prove it> | QUOTE: <the SPEC's own words>

Copy each QUOTE as it is, with no quote marks around it: it is checked, and a quote that is not there cannot be used.

## What you judge against
The SPECs below, each a REQUIREMENT with its parts and the ASSERTION tagged as covering it. In each ASSERTION, the lines marked >> are the ones tagged for the requirement; the lines above them set up the test, and what they do counts. Each test file is also shown whole, under THE TEST FILES: setup anywhere in the file counts — a helper function, a block shared by several cases — so judge what the test really does, not only the lines next to the assertion. The failure you are looking for is a test that does something real and specific, but not what a part says — including its opposite.
EOF
    local _i
    for (( _i=0; _i<${#_bp_ids[@]}; _i++ )); do
        printf '\n### %s\nREQUIREMENT:\n%s\n\nASSERTION:\n%s\n' "${_bp_ids[_i]}" "${_bp_txts[_i]}" "${_bp_srcs[_i]}"
    done
    [[ -n "$_bp_files" ]] && printf '\nTHE TEST FILES:\n%s\n' "$_bp_files"
    cat <<'EOF'

## What you must not do
- Judge what each test does, not what the code under test does: open the test files and any helper or fixture they use, never the code they test.
- Do not suggest a fix. Do not rewrite anything.
EOF
}

# _sc_call <tier> <task> [rc_file] [what-was-wrong reply] — compose the task and
# route it; with the last two, it is asked again with them (ADR-060 §6). The persona
# (ADR-051) reaches the model through the provider, not this text.
# rc_file: if given, the first non-zero router exit code is kept there (subshell boundary
# prevents a nameref from crossing; a file survives it — same pattern as
# review-lens and other stages that need the rc from inside a command substitution).
_sc_call() {
    local tier="$1" _task="$2" _rc_file="${3:-}" _framed="$2" _raw=""
    # ADR-067 §8: the stage's three parts and the engine's blocks, in the one
    # prompt order. A prompt that cannot be composed is not sent: the call
    # fails as misconfigured (rc 2), the first failure kept like any other.
    local _composed
    # #2458: it judges, so it composes fresh — no notes, and no rule to confirm earlier work.
    if ! _composed="$(stage_prompt_compose_parts --fresh "$_framed")"; then
        _ta_sc_emit "test_author.check.prompt_refused" "reason=not_composed"
        if [[ -n "$_rc_file" ]]; then
            local _prev0=0
            [[ -f "$_rc_file" ]] && _prev0="$(cat "$_rc_file" 2>/dev/null || printf '0')"
            [[ "$_prev0" =~ ^[1-9][0-9]*$ ]] || printf '2' > "$_rc_file" 2>/dev/null || true
        fi
        return 0
    fi
    _framed="$_composed"
    [[ -n "${4:-}" ]] && _framed="$(stage_prompt_reask "$_framed" "$4" "${5:-}")"
    # No 2>/dev/null: the stage-io input banner writes to fd 2 (#491). stdin
    # is /dev/null: a model that drains stdin must not eat a caller's stream (#2108).
    if declare -f route_to_model >/dev/null 2>&1; then
        local _call_rc=0
        # ADR-017 §12 (#2507): the call test-author's manifest lists as
        # `check`, with a judge's tools.
        local -x ZBUILD_ROUTE_CALL=check
        _raw="$(route_to_model "$tier" "$_framed" </dev/null)" || _call_rc=$?
        # The batch call and every fallback call share one rc file. The FIRST
        # non-zero rc is kept: a later success must not hide an earlier failure
        # (review on PR #2262), and the first failure is the cause — later calls
        # ran on whatever time the first one left.
        if [[ -n "$_rc_file" && "$_call_rc" -ne 0 ]]; then
            local _prev_rc=0
            [[ -f "$_rc_file" ]] && _prev_rc="$(cat "$_rc_file" 2>/dev/null || printf '0')"
            [[ "$_prev_rc" =~ ^[0-9]+$ ]] || _prev_rc=0
            [[ "$_prev_rc" -ne 0 ]] || printf '%s' "$_call_rc" > "$_rc_file" 2>/dev/null || true
        fi
    fi
    printf '%s' "$_raw"
}

# _sc_judge <reply> <sid> <parts_var> <words> <repo> <first> — read one SPEC's
# lines of an answer (#2467, #2470, ADR-073 §6). A part is named by the word its
# line starts with; the quote, its own words, picks which line when there are
# several. Sets _SC_V (corresponds, partial, mismatch or untestable), _SC_F (the
# finding: the SPEC whole, its first line <first> and each part as written, the
# lines joined by a record separator, [FIX IN TEST: …] on each line to fix), _SC_U
# (the same, for a SPEC no test can prove, marked [FIX IN DESIGN: …]), _SC_LINES
# (its own lines, which are what is kept) and _SC_PROBLEM (what makes them
# unusable: no line for it, a word that is not a verdict, a quote not there).
_sc_judge() {
    local _scj_reply="$1" _scj_sid="$2" _scj_words="$4" _scj_repo="$5" _scj_first="$6"
    local -n _scj_parts="$3"
    _SC_V="" _SC_F="" _SC_U="" _SC_LINES="" _SC_PROBLEM=""
    local -A _scj_text=() _scj_pw=() _scj_mark=()
    local -a _scj_order=() _scj_bad=() _scj_head=()
    local _scj_x _scj_l _scj_lab _scj_pw1 _scj_num _scj_word _scj_rest _scj_why _scj_q _scj_w _scj_c _scj_cand
    local _scj_seen=0 _scj_miss=0 _scj_wrong=0 _scj_sect="" _scj_unt="" _scj_n=0
    for _scj_x in ${_scj_parts[@]+"${_scj_parts[@]}"}; do
        _scj_lab="${_scj_x%%$'\t'*}"; _scj_x="${_scj_x#*$'\t'}"
        _scj_pw["$_scj_lab"]="${_scj_x%%$'\t'*}"; _scj_text["$_scj_lab"]="${_scj_x#*$'\t'}"; _scj_order+=("$_scj_lab")
    done
    local _scj_re="^${_scj_sid}[[:space:]]+(Given|When|Then|And|Cleanup|sections)([[:space:]]+[0-9]+)?[*\`_]*:[[:space:]]*([a-z_]+)(.*)$"
    local _scj_ure="^${_scj_sid}[*\`_]*:[[:space:]]*([a-z_]+)(.*)$"
    while IFS= read -r _scj_l; do
        judge_reply_line_v _scj_l "$_scj_l"
        if [[ "$_scj_l" =~ $_scj_re ]]; then
            _scj_pw1="${BASH_REMATCH[1]}"; _scj_num="${BASH_REMATCH[2]// /}"; _scj_word="${BASH_REMATCH[3]}"; _scj_rest="${BASH_REMATCH[4]}"
        elif [[ "$_scj_l" =~ $_scj_ure ]]; then
            _scj_pw1=""; _scj_num=""; _scj_word="${BASH_REMATCH[1]}"; _scj_rest="${BASH_REMATCH[2]}"
        else
            continue
        fi
        _SC_LINES+="$_scj_l"$'\n'; _scj_seen=1
        [[ "$_scj_word" == ok ]] && continue
        _scj_why=""; _scj_q=""
        if [[ "$_scj_rest" == *"| WHY:"* ]]; then _scj_why="${_scj_rest#*| WHY:}"; _scj_why="${_scj_why%%| QUOTE:*}"; fi
        _scj_why="${_scj_why#"${_scj_why%%[![:space:]]*}"}"; _scj_why="${_scj_why%"${_scj_why##*[![:space:]]}"}"
        if [[ "$_scj_rest" == *"| QUOTE:"* ]]; then
            _scj_q="${_scj_rest#*| QUOTE:}"; _scj_q="${_scj_q#"${_scj_q%%[![:space:]]*}"}"; _scj_q="${_scj_q%"${_scj_q##*[![:space:]]}"}"
        fi
        if [[ "$_scj_pw1" == sections ]]; then
            [[ "$_scj_word" == missing ]] || { _scj_bad+=("$_scj_sid sections is ok or missing, not $_scj_word"); continue; }
            # #2474: a quote of the test, when given, must be there.
            if [[ -n "$_scj_q" ]]; then
                judge_quote_check_v _scj_w "$_scj_q" "" "$_scj_repo" || { _scj_bad+=("$_scj_sid's quote $_scj_w"); continue; }
            fi
            _scj_miss=$((_scj_miss + 1)); _scj_n=$((_scj_n + 1))
            _scj_sect="${_scj_why:-a section is missing}"
            _scj_head+=("sections: $_scj_sect")
            continue
        fi
        if [[ -z "$_scj_pw1" ]]; then
            [[ "$_scj_word" == untestable ]] || { _scj_bad+=("$_scj_sid is ok or untestable, not $_scj_word"); continue; }
            [[ -n "$_scj_q" ]] || { _scj_bad+=("$_scj_sid has no QUOTE"); continue; }
            judge_quote_check_v _scj_w "$_scj_q" "$_scj_words" "$_scj_repo" || { _scj_bad+=("$_scj_sid's quote $_scj_w"); continue; }
            _scj_unt="${_scj_why:-no test can prove it}"
            # The line it is about: the part whose words hold the quote, else the first.
            _scj_c=""
            [[ "$_scj_q" =~ ^\"(.*)\"$ ]] && for _scj_lab in "${_scj_order[@]}"; do
                _judge_holds "${_scj_text[$_scj_lab]}" "${BASH_REMATCH[1]}" && { _scj_c="$_scj_lab"; break; }
            done
            _scj_n=$((_scj_n + 1))
            _scj_head+=("${_scj_c:+${_scj_pw[$_scj_c]}: }$_scj_unt — no test can prove it")
            _scj_mark["${_scj_c:-^}"]+=" [FIX IN DESIGN: $_scj_unt — no test can prove it; say something a test can see the code do]"
            continue
        fi
        case "$_scj_word" in
            missing|wrong) ;;
            *) _scj_bad+=("$_scj_sid $_scj_pw1 is ok, missing or wrong, not $_scj_word"); continue ;;
        esac
        [[ -n "$_scj_q" ]] || { _scj_bad+=("$_scj_sid $_scj_pw1 has no QUOTE"); continue; }
        # Which line: an old label (Then 2) names it; otherwise every line of
        # that word — a Then's Ands too — and the quote picks one.
        _scj_cand=""
        if [[ -n "$_scj_num" && "$_scj_pw1" != And && -n "${_scj_text[$_scj_pw1 $_scj_num]+x}" ]]; then
            _scj_cand="$_scj_pw1 $_scj_num"
        else
            for _scj_lab in "${_scj_order[@]}"; do
                if [[ "$_scj_pw1" == And ]]; then [[ "${_scj_pw[$_scj_lab]}" == And ]] && _scj_cand+="$_scj_lab"$'\n'
                elif [[ "${_scj_lab%% *}" == "$_scj_pw1" ]]; then _scj_cand+="$_scj_lab"$'\n'; fi
            done
        fi
        [[ -n "$_scj_cand" ]] || { _scj_bad+=("$_scj_sid has no $_scj_pw1 line"); continue; }
        _scj_lab=""
        if [[ "$_scj_q" =~ ^\"(.*)\"$ ]]; then
            _scj_x="${BASH_REMATCH[1]}"
            while IFS= read -r _scj_c; do
                [[ -n "$_scj_c" ]] && _judge_holds "${_scj_text[$_scj_c]}" "$_scj_x" && { _scj_lab="$_scj_c"; break; }
            done <<< "$_scj_cand"
        fi
        if [[ -z "$_scj_lab" ]]; then
            case "$_scj_pw1" in
                When) _scj_bad+=("$_scj_sid When's quote is not in its When line") ;;
                And)  _scj_bad+=("$_scj_sid And's quote is not in any of its And lines") ;;
                *)    _scj_bad+=("$_scj_sid $_scj_pw1's quote is not in any of its $_scj_pw1 or And lines") ;;
            esac
            continue
        fi
        if [[ "$_scj_word" == wrong ]]; then
            _scj_wrong=$((_scj_wrong + 1)); _scj_n=$((_scj_n + 1))
            _scj_head+=("${_scj_pw[$_scj_lab]}: the test does something else: ${_scj_why:-not what this line says}")
            _scj_mark["$_scj_lab"]+=" [FIX IN TEST: the test does something else: ${_scj_why:-not what this line says} — make it do what this line says]"
        else
            _scj_miss=$((_scj_miss + 1)); _scj_n=$((_scj_n + 1))
            case "$_scj_lab" in
                Given*)   _scj_x="set this up in the test" ;;
                When*)    _scj_x="do this in the test" ;;
                Cleanup*) _scj_x="put this back at the end of the test" ;;
                *)        _scj_x="assert this, so the test fails when it is not so" ;;
            esac
            _scj_head+=("${_scj_pw[$_scj_lab]}: ${_scj_why:-the test does not do it}")
            _scj_mark["$_scj_lab"]+=" [FIX IN TEST: ${_scj_why:-the test does not do it} — $_scj_x]"
        fi
    done <<< "$_scj_reply"
    (( _scj_seen )) || _scj_bad=("it has no line for $_scj_sid" ${_scj_bad[@]+"${_scj_bad[@]}"})
    if [[ ${#_scj_bad[@]} -gt 0 ]]; then
        local IFS=';'; _SC_PROBLEM="${_scj_bad[*]}"; _SC_PROBLEM="${_SC_PROBLEM//;/; }"
        return 0
    fi
    _SC_LINES="${_SC_LINES%$'\n'}"
    if [[ -n "$_scj_sect" ]]; then
        local _scj_secs="Given, When and Then"
        for _scj_lab in "${_scj_order[@]}"; do [[ "$_scj_lab" == Cleanup* ]] && _scj_secs="Given, When, Then and Cleanup"; done
        _scj_mark["^"]+=" [FIX IN TEST: lay the test out in $_scj_secs sections — $_scj_sect]"
    fi
    if [[ -n "$_scj_unt" ]]; then _SC_V=untestable
    elif (( _scj_wrong )); then _SC_V=mismatch
    elif (( _scj_miss )); then _SC_V=partial
    else _SC_V=corresponds; return 0; fi
    # The SPEC whole, the lines to fix marked, under a first line that says
    # what is wrong (#2480, ADR-064 §4): a run-status row shows that line.
    local _scj_out _scj_h=""
    for _scj_x in ${_scj_head[@]+"${_scj_head[@]}"}; do _scj_h+="${_scj_h:+; }$_scj_x"; done
    _scj_out="$_scj_sid $_scj_h"$'\x1e'"$_scj_first${_scj_mark[^]:-}"
    for _scj_lab in "${_scj_order[@]}"; do
        _scj_out+=$'\x1e'"  ${_scj_pw[$_scj_lab]}: ${_scj_text[$_scj_lab]}${_scj_mark[$_scj_lab]:-}"
    done
    if [[ "$_SC_V" == untestable ]]; then _SC_U="$_scj_out"; else _SC_F="$_scj_out"; fi
    return 0
}

# _sc_disputes <artifact_dir> <assoc_var> — test-author's `wrong` answers
# (zb_answer_kind_v) to its own check's findings (ADR-072 §5), by the SPEC each finding
# names: <assoc>[SID] = the answers. The finding is its last result's, by number.
_sc_disputes() {
    local art="$1"; local -n _scd="$2"
    local a n t k
    [[ -n "$art" && -s "$art/test-author-result.json" && ${#_TA_ANSWERS[@]} -gt 0 ]] || return 0
    local -A _scd_text=()
    while IFS=$'\t' read -r n t; do
        [[ -n "$n" ]] && _scd_text["$n"]="$t"
    done < <(jq -r '(.data.findings // [])[]? | "\(.n)\t\(.text)"' "$art/test-author-result.json" 2>/dev/null)
    for a in "${_TA_ANSWERS[@]}"; do
        [[ "$a" =~ ^test-author[[:space:]]+finding[[:space:]]+([0-9]+)[[:space:]]*: ]] || continue
        n="${BASH_REMATCH[1]}"; zb_answer_kind_v k "$a"; [[ "$k" == wrong ]] || continue
        t="${_scd_text[$n]:-}"
        [[ "$t" =~ ^(${_ACCEPTANCE_ID_ERE})(\'s|:|[[:space:]]) ]] || continue
        _scd["${BASH_REMATCH[1]}"]+="${_scd[${BASH_REMATCH[1]}]:+; }$a"
    done
}

# _ta_correspondence <design.md> <repo_root> <tier> [artifact_dir]
# Sets _TA_CORR_FINDINGS (one entry per SPEC a test falls short on, the SPEC
# shown whole with each line to fix marked), _TA_CORR_UNTESTABLE (each SPEC no
# test can prove, one per line, shown the same way: design's to rewrite) and _TA_CORR_OUTCOME: empty when every SPEC was judged, otherwise the
# outcome word for how the check failed — the call's own disposition, or
# unusable when the judge gave no usable answer. rc 0. [artifact_dir]: where
# each SPEC's answer is kept (ADR-072 §4), and test-author's last result, whose
# findings its answers name.
_ta_correspondence() {
    local design="$1" repo="$2" tier="${3:-T2}" art="${4:-}"
    _TA_CORR_FINDINGS=(); _TA_CORR_UNTESTABLE=""; _TA_CORR_OUTCOME=""
    # #2143: collect every judgeable (requirement, assertion) pair FIRST, judge
    # them in ONE model call, and fall back to a per-SPEC call only for what
    # the batch left unjudged.
    local sid _src _i _blk _x _shown _p _pn _tfs
    local -a _ids=() _txts=() _srcs=() _tfss=() _pnames=() _firsts=()
    _blk="$(extract_acceptance_block "$design" 2>/dev/null)" || _blk=""
    # #2508: each SPEC's test files, found by tag, once.
    local -A _sc_files=()
    acceptance_spec_files_v _sc_files "$design" "$repo"
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        _acceptance_spec_line "$_blk" "$sid" || continue
        [[ -z "$_ACC_SPEC_TEXT" ]] && continue
        _tfs="${_sc_files[$sid]:-}"
        # The whole assertion with its enclosing predicate, comments stripped:
        # a bare tagged line reads as a vacuous test, and a pasted SPEC sentence
        # in a comment would buy a false `corresponds`.
        _src=""
        declare -f acceptance_find_assertion_sources >/dev/null 2>&1 && _src="$(
            # shellcheck disable=SC2086
            acceptance_find_assertion_sources "$repo" "$sid" $_tfs 2>/dev/null || true)"
        # No tagged assertion: nothing to judge here (as before #2370); a missing
        # assertion is the acceptance check's to report.
        [[ -n "$_src" ]] || continue
        # #2467: the SPEC as the check reads it — its words, and each part by
        # the word design wrote (#2470).
        _firsts+=("$sid${_ACC_SPEC_TAG:+[$_ACC_SPEC_TAG]}: $_ACC_SPEC_REST")
        _pn="_sc_parts_${#_ids[@]}"
        local -a "$_pn=()"
        _sc_spec_parts_v "$_pn" "$_blk" "$sid"
        local -n _sc_pp="$_pn"
        _shown="$_ACC_SPEC_TEXT"
        for _p in "${_sc_pp[@]}"; do _p="${_p#*$'\t'}"; _shown+=$'\n'"  ${_p%%$'\t'*}: ${_p#*$'\t'}"; done
        unset -n _sc_pp
        _ids+=("$sid"); _txts+=("$_shown"); _srcs+=("$_src"); _tfss+=("$_tfs"); _pnames+=("$_pn")
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    local n=${#_ids[@]}
    [[ $n -gt 0 ]] || return 0

    local -a _verdicts=() _finds=() _unt=() _lines=() _fps=() _kept=()
    for (( _i=0; _i<n; _i++ )); do _verdicts+=(""); _finds+=(""); _unt+=(""); _lines+=(""); _fps+=(""); _kept+=(0); done

    # ADR-072 §4 §5: a SPEC whose requirement, assertion, test files and engine
    # are as they were keeps its answer — unless test-author disputes it.
    local kf="" eng _k="" _f
    [[ -n "$art" ]] && kf="${art%/}/test-author-judged.json"
    local -A _disp=()
    _sc_disputes "$art" _disp
    judge_engine_v eng
    for (( _i=0; _i<n; _i++ )); do
        judge_fp_v _k "$eng"$'\n'"${_ids[_i]}"$'\n'"${_txts[_i]}"$'\n'"${_srcs[_i]}"$'\n'"${_disp[${_ids[_i]}]:-}"
        _fps[_i]="$_k"
        [[ -n "$kf" ]] || continue
        judge_kept_get_v _k "$kf" "${_ids[_i]}" "${_fps[_i]}" "${_disp[${_ids[_i]}]:+1}"
        [[ -n "$_k" ]] || continue
        _sc_judge "$_k" "${_ids[_i]}" "${_pnames[_i]}" "${_txts[_i]}" "$repo" "${_firsts[_i]}"
        [[ -z "$_SC_PROBLEM" ]] || continue
        _verdicts[_i]="$_SC_V"; _finds[_i]="$_SC_F"; _unt[_i]="$_SC_U"; _lines[_i]="$_SC_LINES"; _kept[_i]=1
    done

    # Only the SPECs not kept are judged. #2450: each test file whole, once,
    # with the tags of every judged SPEC marked — the batch call reads it; a
    # one-SPEC call reads its own files.
    local -a _jx=() _jids=() _jtxts=() _jsrcs=() _tags=() _files_seen=()
    for (( _i=0; _i<n; _i++ )); do
        (( _kept[_i] )) && continue
        _jx+=("$_i"); _jids+=("${_ids[_i]}"); _jtxts+=("${_txts[_i]}")
        _src="${_srcs[_i]}"
        [[ -n "${_disp[${_ids[_i]}]:-}" ]] && _src+=$'\n\n'"THE TEST AUTHOR SAYS YOUR EARLIER FINDING ON THIS ONE IS WRONG — judge again with it in mind: ${_disp[${_ids[_i]}]}"
        _jsrcs+=("$_src")
        _tags+=("$(acceptance_spec_tag "${_ids[_i]}")")
    done
    if [[ ${#_jx[@]} -gt 0 ]]; then
        local _files_text="" _sf _seen
        for _i in "${_jx[@]}"; do
            for _f in ${_tfss[_i]}; do
                _seen=0
                for _sf in ${_files_seen[@]+"${_files_seen[@]}"}; do [[ "$_sf" == "$_f" ]] && _seen=1; done
                (( _seen )) && continue
                _files_seen+=("$_f")
                _files_text+="--- $_f ---"$'\n'"$(acceptance_testfile_source "$repo" "$_f" "${_tags[@]}")"$'\n'
            done
        done

        # A nameref cannot cross a subshell; a file survives it (#2032).
        local _rc_file; _rc_file="$(mktemp)" || _rc_file=""
        [[ -n "$_rc_file" ]] && printf '0' > "$_rc_file" 2>/dev/null || true
        local _opened; _opened="$(mktemp 2>/dev/null)" || _opened=""
        local -x ZBUILD_ROUTER_OPENED_FILE="$_opened"

        local _batch_raw _one_raw _one_task _j
        _batch_raw="$(_sc_call "$tier" "$(_sc_batch_prompt _jids _jtxts _jsrcs "$_files_text")" "$_rc_file")"
        zb_reply_join_v _batch_raw "$_batch_raw"
        local -a _bprob=()
        for _i in "${_jx[@]}"; do
            _sc_judge "$_batch_raw" "${_ids[_i]}" "${_pnames[_i]}" "${_txts[_i]}" "$repo" "${_firsts[_i]}"
            # A SPEC whose lines are missing or wrong is asked again on its own,
            # told what was wrong with them.
            _bprob[_i]="$_SC_PROBLEM"
            [[ -z "$_SC_PROBLEM" ]] || continue
            _verdicts[_i]="$_SC_V"; _finds[_i]="$_SC_F"; _unt[_i]="$_SC_U"; _lines[_i]="$_SC_LINES"
        done
        local -a _oid=() _otxt=() _osrc=()
        for (( _j=0; _j<${#_jx[@]}; _j++ )); do
            _i="${_jx[_j]}"
            [[ -z "${_verdicts[_i]}" ]] || continue
            _x=""
            for _f in ${_tfss[_i]}; do
                _x+="--- $_f ---"$'\n'"$(acceptance_testfile_source "$repo" "$_f" "${_tags[_j]}")"$'\n'
            done
            _oid=("${_ids[_i]}"); _otxt=("${_txts[_i]}"); _osrc=("${_jsrcs[_j]}")
            _one_task="$(_sc_batch_prompt _oid _otxt _osrc "$_x")"
            if [[ -n "${_bprob[_i]:-}" && -n "$_batch_raw" ]]; then
                _one_raw="$(_sc_call "$tier" "$_one_task" "$_rc_file" "${_bprob[_i]}" "$_batch_raw")"
            else
                _one_raw="$(_sc_call "$tier" "$_one_task" "$_rc_file")"
            fi
            zb_reply_join_v _one_raw "$_one_raw"
            _sc_judge "$_one_raw" "${_ids[_i]}" "${_pnames[_i]}" "${_txts[_i]}" "$repo" "${_firsts[_i]}"
            # ADR-060 §6: an answer that cannot be used is asked again once,
            # with what was wrong and the answer.
            if [[ -n "$_SC_PROBLEM" && "$(cat "$_rc_file" 2>/dev/null || printf 0)" == 0 ]]; then
                _one_raw="$(_sc_call "$tier" "$_one_task" "$_rc_file" "$_SC_PROBLEM" "$_one_raw")"
                zb_reply_join_v _one_raw "$_one_raw"
                _sc_judge "$_one_raw" "${_ids[_i]}" "${_pnames[_i]}" "${_txts[_i]}" "$repo" "${_firsts[_i]}"
            fi
            [[ -z "$_SC_PROBLEM" ]] || continue
            _verdicts[_i]="$_SC_V"; _finds[_i]="$_SC_F"; _unt[_i]="$_SC_U"; _lines[_i]="$_SC_LINES"
        done

        # A call that failed is how the check ended (#2032): its rc, classified.
        local _router_rc=0
        if [[ -n "$_rc_file" && -f "$_rc_file" ]]; then
            _router_rc="$(cat "$_rc_file" 2>/dev/null || echo 0)"; rm -f "$_rc_file" 2>/dev/null || true
        fi
        local -a _open_files=()
        judge_opened_v _open_files "$_opened" "$design"; rm -f "$_opened" 2>/dev/null
        if [[ "$_router_rc" =~ ^[0-9]+$ && "$_router_rc" -ne 0 ]]; then
            local _rv _rr
            _router_rc_classify "$_router_rc" _rv _rr 2>/dev/null || true
            # disposition-ok: the model router is not responding
            _TA_CORR_OUTCOME="$(router_reason_disposition "${_rr:-}" 2>/dev/null || true)"
            [[ -n "$_TA_CORR_OUTCOME" ]] || _TA_CORR_OUTCOME="unavailable"
            return 0
        fi
        # Each SPEC's answer judged now is kept, with the files it depends on.
        # #2477 (ADR-072 §4): the code its test exercises — the design's WIRING
        # files — counts whether or not the judge opened it.
        if [[ -n "$kf" ]]; then
            local -a _deps=() _wired=()
            while IFS= read -r _f; do
                [[ -n "$_f" && "$_f" != none ]] && _wired+=("$repo/$_f")
            done < <(acceptance_list_wiring "$design" 2>/dev/null || true)
            for _i in "${_jx[@]}"; do
                [[ -n "${_verdicts[_i]}" ]] || continue
                _deps=(${_open_files[@]+"${_open_files[@]}"} ${_wired[@]+"${_wired[@]}"})
                for _f in ${_tfss[_i]}; do _deps+=("$repo/$_f"); done
                judge_kept_put "$kf" "${_ids[_i]}" "${_fps[_i]}" "${_lines[_i]}" "${_deps[@]}"
            done
        fi
    fi

    local _unjudged=0
    for (( _i=0; _i<n; _i++ )); do
        case "${_verdicts[_i]:-}" in
            corresponds) ;;
            partial|mismatch) _TA_CORR_FINDINGS+=("${_finds[_i]}") ;;
            untestable)
                _TA_CORR_UNTESTABLE+="${_TA_CORR_UNTESTABLE:+$'\n'}${_unt[_i]}" ;;
            *) _unjudged=$(( _unjudged + 1 )) ;;
        esac
    done
    # #2062: a judge with no answer has no basis for "corresponds".
    [[ $_unjudged -gt 0 ]] && _TA_CORR_OUTCOME=unusable
    return 0
}
