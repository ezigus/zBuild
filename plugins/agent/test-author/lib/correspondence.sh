#!/usr/bin/env bash
# plugins/agent/test-author/lib/correspondence.sh — test-author's second model
# call: does each assertion test what its SPEC SAYS? (#2370; was the
# spec-correspondence stage, #2034, ADR-036.)
#
# A passing test proves the implementation satisfies the ASSERTION, never that
# the assertion satisfies the SENTENCE. This judges that link, before any code
# exists, from the requirement and the assertion alone.
#
# #2464 (ADR-072): the check judges — it reads files itself, read-only; a
# verdict short of `corresponds` quotes the requirement's words the assertion
# does not establish; and each SPEC's verdict is kept while its requirement and
# its test are unchanged, and judged again when test-author disputes it.
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

# _sc_prompt <requirement> <assertion>
# Deliberately specific about the task and deliberately starved of the code.
# Naming the failure mode matters: without it the judge evaluates "is this a
# good test?", and a good test that tests the wrong thing sails through.
_sc_prompt() {
    cat <<EOF
You are checking ONE acceptance requirement against ONE test assertion.

## What you own
One judgement: if the ASSERTION passes, does that establish the REQUIREMENT?

Answer in exactly these lines:

VERDICT: corresponds | partial | mismatch | uncheckable
REASON: <one sentence>
QUOTE: "<the requirement's own words this assertion does not establish>"

QUOTE is for partial, mismatch and uncheckable only. Copy the words exactly from
the REQUIREMENT: they are checked, and a quote that is not there cannot be used.

  corresponds — passing this assertion would establish the requirement.
  partial     — it tests the right thing, but establishes only part of what
                the requirement promises (one case of several, a narrower
                property, one form where the requirement names two).
  mismatch    — it tests something else, or the reverse of what is required.
  uncheckable — the requirement is too vague to say what would establish it.

Reserve the mismatch verdict for a genuine disagreement between the assertion
and the requirement. An assertion aimed at the right property but narrower in
reach is partial, not mismatch.

## What you judge against
Exactly two things, shown at the end of this part:

REQUIREMENT — a single sentence from a design document.
ASSERTION   — the source of the test assertion tagged as covering it: the lines
              marked >> are the ones tagged for the requirement; the lines
              above them set up the test, and what they do counts.

The failure you are looking for is an assertion that tests something real
and specific, but not what the requirement says — including asserting its
opposite. It will look like reasonable test code. That is expected. The
question is not whether it is a good test. The question is whether it
tests THIS requirement.

REQUIREMENT:
$1

ASSERTION:
$2
${3:+
THE TEST FILE (whole; setup anywhere in it counts):
$3
}
## What you must not do
- Judge what the test establishes, not what the code under test does: open the
  test files and any helper or fixture they use, never the code they test.
- Do not suggest a fix. Do not rewrite the assertion. Answer only.
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
        # ADR-072 §1: this call reads and searches files, and nothing else.
        local -x ZBUILD_ROUTE_TOOLS=read
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
# _sc_parse_verdict / _sc_parse_reason / _sc_parse_quote <reply-or-line> — the
# first VERDICT word, the REASON text and the QUOTE. No `| head` (#1886):
# capture in full, trim in bash.
_sc_parse_verdict() {
    local v; v="$(grep -oE 'VERDICT:[[:space:]]*(corresponds|partial|mismatch|uncheckable)' <<< "$1" || true)"
    v="${v%%$'\n'*}"; printf '%s' "${v##*[[:space:]]}"
}
_sc_parse_reason() {
    # #2460: the rest of the line — a reason may quote a `|`. #2464: up to its QUOTE.
    local r; r="$(grep -oE 'REASON:.*' <<< "$1" || true)"
    r="${r%%$'\n'*}"; r="${r#REASON:}"; r="${r%%| QUOTE:*}"; r="${r#"${r%%[![:space:]]*}"}"; printf '%s' "${r%"${r##*[![:space:]]}"}"
}
_sc_parse_quote() {
    local q="" l
    while IFS= read -r l; do
        if [[ "$l" == *"| QUOTE:"* ]]; then q="${l#*| QUOTE:}"; break; fi
        [[ "$l" =~ ^[[:space:]]*QUOTE:(.*)$ ]] && { q="${BASH_REMATCH[1]}"; break; }
    done <<< "$1"
    q="${q#"${q%%[![:space:]]*}"}"; printf '%s' "${q%"${q##*[![:space:]]}"}"
}
# _sc_quote_problem_v <var> <sid> <verdict> <quote> <requirement> <repo> — what
# is wrong with a verdict's quote; empty when it is right (or not needed).
_sc_quote_problem_v() {
    local -n _sqp="$1"; local _sqp_w=""
    _sqp=""
    [[ "$3" == corresponds || -z "$3" ]] && return 0
    if [[ -z "$4" ]]; then
        _sqp="it has no QUOTE: line with the requirement's own words the assertion does not establish"
    elif ! judge_quote_check_v _sqp_w "$4" "$5" "$6"; then
        _sqp="$2's quote $_sqp_w"
    fi
}
# _sc_one_reason <reply> — the REASON of a one-requirement answer, read whole
# (#2460, review on #2461): a REASON that wraps onto the next line is joined.
_sc_one_reason() {
    local _sor_j=""; zb_reply_join_v _sor_j "$1"; _sc_parse_reason "$_sor_j"
}
# _sc_batch_line_v <var> <reply> <id> — the batch answer's line for <id>, read
# whole (#2460): its continued lines joined, and a REASON: on the line after
# its verdict taken as its own. A glob match, not a regex built from the id
# (review on #2148).
_sc_batch_line_v() {
    local -n _sbl="$1"; local _sbl_j="" _sbl_l _sbl_take=0
    _sbl=""
    zb_reply_join_v _sbl_j "$2"
    while IFS= read -r _sbl_l; do
        if (( _sbl_take )); then
            [[ "$_sbl_l" =~ ^[[:space:]]*REASON: ]] && _sbl+=" | ${_sbl_l#"${_sbl_l%%[![:space:]]*}"}"
            break
        fi
        [[ "$_sbl_l" == "$3:"*"VERDICT:"* ]] || continue
        _sbl="$_sbl_l"
        [[ "$_sbl_l" == *REASON:* ]] && break
        _sbl_take=1
    done <<< "$_sbl_j"
}
# _sc_batch_prompt <ids_arr> <txts_arr> <srcs_arr> (namerefs) — every pair in
# one prompt, one answer line per SPEC (#2143).
_sc_batch_prompt() {
    local -n _bp_ids="$1" _bp_txts="$2" _bp_srcs="$3"
    local _bp_files="${4:-}"
    cat <<'EOF'
You are checking acceptance requirements against the test assertions tagged as covering them, one pair at a time.

## What you own
For EACH pair, one judgement: if the ASSERTION passes, does that establish the REQUIREMENT?

Answer with exactly one line per SPEC, in this form and nothing else — begin each line with that SPEC's identifier from its `###` heading, exactly as written there:

<identifier>: VERDICT: <corresponds, partial, mismatch or uncheckable> | REASON: <one sentence> | QUOTE: "<the requirement's own words it does not establish>"

QUOTE is for partial, mismatch and uncheckable only. Copy the words exactly from the REQUIREMENT: they are checked, and a quote that is not there cannot be used.

  corresponds — passing this assertion would establish the requirement.
  partial     — it tests the right thing, but establishes only part of it.
  mismatch    — it tests something else, or the reverse of what is required.
  uncheckable — the requirement is too vague to say what would establish it.

Reserve mismatch for a genuine disagreement.

## What you judge against
The pairs below, each a REQUIREMENT and the ASSERTION tagged as covering it. In each ASSERTION, the lines marked >> are the ones tagged for the requirement; the lines above them set up the test, and what they do counts. Each test file is also shown whole, under THE TEST FILES: setup anywhere in the file counts — a helper function, a block shared by several cases — so judge what the test really does, not only the lines next to the assertion. The failure you are looking for is an assertion that tests something real and specific, but not what the requirement says — including its opposite.
EOF
    local _i
    for (( _i=0; _i<${#_bp_ids[@]}; _i++ )); do
        printf '\n### %s\nREQUIREMENT:\n%s\n\nASSERTION:\n%s\n' "${_bp_ids[_i]}" "${_bp_txts[_i]}" "${_bp_srcs[_i]}"
    done
    [[ -n "$_bp_files" ]] && printf '\nTHE TEST FILES:\n%s\n' "$_bp_files"
    cat <<'EOF'

## What you must not do
- Judge what each test establishes, not what the code under test does: open the test files and any helper or fixture they use, never the code they test.
- Do not suggest a fix. Do not rewrite anything.
EOF
}

# _sc_disputes <artifact_dir> <assoc_var> — test-author's "nothing to do"
# answers to its own check's findings (ADR-072 §5), by the SPEC each finding
# names: <assoc>[SID] = the answer. The finding is its last result's, by number.
_sc_disputes() {
    local art="$1"; local -n _scd="$2"
    local a n t
    [[ -n "$art" && -s "$art/test-author-result.json" && ${#_TA_ANSWERS[@]} -gt 0 ]] || return 0
    local -A _scd_text=()
    while IFS=$'\t' read -r n t; do
        [[ -n "$n" ]] && _scd_text["$n"]="$t"
    done < <(jq -r '(.data.findings // [])[]? | "\(.n)\t\(.text)"' "$art/test-author-result.json" 2>/dev/null)
    for a in "${_TA_ANSWERS[@]}"; do
        [[ "$a" =~ ^test-author[[:space:]]+finding[[:space:]]+([0-9]+)[[:space:]]*:[[:space:]]*nothing[[:space:]]to[[:space:]]do ]] || continue
        t="${_scd_text[${BASH_REMATCH[1]}]:-}"
        [[ "$t" =~ ^(${_ACCEPTANCE_ID_ERE})(\'s|:) ]] || continue
        _scd["${BASH_REMATCH[1]}"]="$a"
    done
}

# _ta_correspondence <design.md> <repo_root> <tier> [artifact_dir]
# Sets _TA_CORR_FINDINGS (one entry per SPEC whose assertion does not establish
# it: partial, mismatch or uncheckable) and _TA_CORR_OUTCOME: empty when every
# SPEC was judged, otherwise the outcome word for how the check failed — the
# call's own disposition, or unusable when the judge gave no verdict. rc 0.
# [artifact_dir]: where each SPEC's verdict is kept (ADR-072 §4), and test-author's
# last result, whose findings its answers name.
_ta_correspondence() {
    local design="$1" repo="$2" tier="${3:-T2}" art="${4:-}"
    _TA_CORR_FINDINGS=(); _TA_CORR_OUTCOME=""
    # #2143: collect every judgeable (requirement, assertion) pair FIRST, judge
    # them in ONE model call, and fall back to a per-SPEC call only for what
    # the batch left unjudged.
    local sid _txt _tfs _src _i
    local -a _ids=() _txts=() _srcs=() _tfss=()
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        [[ "$(acceptance_spec_status "$design" "$sid" 2>/dev/null || true)" == "done" ]] && continue
        _txt="$(acceptance_spec_text "$design" "$sid" 2>/dev/null || true)"
        [[ -n "$_txt" ]] || continue
        _tfs="$(acceptance_list_testfiles_for_spec "$design" "$sid" 2>/dev/null || true)"
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
        _ids+=("$sid"); _txts+=("$_txt"); _srcs+=("$_src"); _tfss+=("$_tfs")
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    local n=${#_ids[@]}
    [[ $n -gt 0 ]] || return 0

    local -a _verdicts=() _reasons=() _quotes=() _fps=() _kept=()
    for (( _i=0; _i<n; _i++ )); do _verdicts+=(""); _reasons+=(""); _quotes+=(""); _fps+=(""); _kept+=(0); done

    # ADR-072 §4 §5: a SPEC whose requirement, assertion, test files and engine
    # are as they were keeps its verdict — unless test-author disputes it.
    local kf="" eng _k="" _f
    [[ -n "$art" ]] && kf="${art%/}/test-author-judged.json"
    local -A _disp=()
    _sc_disputes "$art" _disp
    judge_engine_v eng
    for (( _i=0; _i<n; _i++ )); do
        judge_fp_v _k "$eng"$'\n'"${_ids[_i]}"$'\n'"${_txts[_i]}"$'\n'"${_srcs[_i]}"$'\n'"${_disp[${_ids[_i]}]:-}"
        _fps[_i]="$_k"
        [[ -n "$kf" ]] || continue
        judge_kept_get_v _k "$kf" "${_ids[_i]}" "${_fps[_i]}"
        [[ -n "$_k" ]] || continue
        IFS=$'\t' read -r "_verdicts[_i]" "_reasons[_i]" "_quotes[_i]" <<< "$_k"
        _kept[_i]=1
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
    if [[ ${#_jx[@]} -eq 0 ]]; then
        _ta_sc_emit "judge.kept" "check=test-author-correspondence"
    else
        local _files_text="" _sf _seen _x
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

        local _batch_raw _line _v _q _why
        _batch_raw="$(_sc_call "$tier" "$(_sc_batch_prompt _jids _jtxts _jsrcs "$_files_text")" "$_rc_file")"
        for _i in "${_jx[@]}"; do
            _sc_batch_line_v _line "$_batch_raw" "${_ids[_i]}"
            [[ -n "$_line" ]] || continue
            _v="$(_sc_parse_verdict "$_line")"; _q="$(_sc_parse_quote "$_line")"
            # A verdict whose quote is missing or wrong is asked again on its own.
            _sc_quote_problem_v _why "${_ids[_i]}" "$_v" "$_q" "${_txts[_i]}" "$repo"
            [[ -z "$_why" ]] || continue
            _verdicts[_i]="$_v"; _quotes[_i]="$_q"
            _reasons[_i]="$(_sc_parse_reason "$_line")"
        done
        local _one_raw _one_task
        for _i in "${_jx[@]}"; do
            [[ -z "${_verdicts[_i]}" ]] || continue
            _x=""
            for _f in ${_tfss[_i]}; do
                _x+="--- $_f ---"$'\n'"$(acceptance_testfile_source "$repo" "$_f" "$(acceptance_spec_tag "${_ids[_i]}")")"$'\n'
            done
            _src="${_srcs[_i]}"
            [[ -n "${_disp[${_ids[_i]}]:-}" ]] && _src+=$'\n\n'"THE TEST AUTHOR SAYS YOUR EARLIER FINDING ON THIS ONE IS WRONG — judge again with it in mind: ${_disp[${_ids[_i]}]}"
            _one_task="$(_sc_prompt "${_txts[_i]}" "$_src" "$_x")"
            _one_raw="$(_sc_call "$tier" "$_one_task" "$_rc_file")"
            _v="$(_sc_parse_verdict "$_one_raw")"; _q="$(_sc_parse_quote "$_one_raw")"
            _why=""
            if [[ -z "$_v" ]]; then
                _why="it has no VERDICT: line saying corresponds, partial, mismatch or uncheckable"
            else
                _sc_quote_problem_v _why "${_ids[_i]}" "$_v" "$_q" "${_txts[_i]}" "$repo"
            fi
            # ADR-060 §6: an answer that cannot be used is asked again once,
            # with what was wrong and the answer.
            if [[ -n "$_why" && "$(cat "$_rc_file" 2>/dev/null || printf 0)" == 0 ]]; then
                _one_raw="$(_sc_call "$tier" "$_one_task" "$_rc_file" "$_why" "$_one_raw")"
                _v="$(_sc_parse_verdict "$_one_raw")"; _q="$(_sc_parse_quote "$_one_raw")"
                _why=""; [[ -n "$_v" ]] && _sc_quote_problem_v _why "${_ids[_i]}" "$_v" "$_q" "${_txts[_i]}" "$repo"
            fi
            [[ -n "$_why" ]] && _v=""
            _verdicts[_i]="$_v"; _quotes[_i]="$_q"
            _reasons[_i]="$(_sc_one_reason "$_one_raw")"
        done

        # A call that failed is how the check ended (#2032): its rc, classified.
        local _router_rc=0
        if [[ -n "$_rc_file" && -f "$_rc_file" ]]; then
            _router_rc="$(cat "$_rc_file" 2>/dev/null || echo 0)"; rm -f "$_rc_file" 2>/dev/null || true
        fi
        local -a _open_files=()
        judge_opened_v _open_files "$_opened"; rm -f "$_opened" 2>/dev/null
        if [[ "$_router_rc" =~ ^[0-9]+$ && "$_router_rc" -ne 0 ]]; then
            local _rv _rr
            _router_rc_classify "$_router_rc" _rv _rr 2>/dev/null || true
            # disposition-ok: the model router is not responding
            _TA_CORR_OUTCOME="$(router_reason_disposition "${_rr:-}" 2>/dev/null || true)"
            [[ -n "$_TA_CORR_OUTCOME" ]] || _TA_CORR_OUTCOME="unavailable"
            return 0
        fi
        # Each verdict judged now is kept, with the files it depends on.
        if [[ -n "$kf" ]]; then
            local -a _deps=()
            local _qp
            for _i in "${_jx[@]}"; do
                [[ -n "${_verdicts[_i]}" ]] || continue
                _deps=(${_open_files[@]+"${_open_files[@]}"})
                for _f in ${_tfss[_i]}; do _deps+=("$repo/$_f"); done
                judge_quote_path_v _qp "${_quotes[_i]}" "$repo"; [[ -n "$_qp" ]] && _deps+=("$repo/$_qp")
                judge_kept_put "$kf" "${_ids[_i]}" "${_fps[_i]}" \
                    "${_verdicts[_i]}"$'\t'"${_reasons[_i]//$'\t'/ }"$'\t'"${_quotes[_i]//$'\t'/ }" "${_deps[@]}"
            done
        fi
    fi

    local _unjudged=0
    for (( _i=0; _i<n; _i++ )); do
        case "${_verdicts[_i]:-}" in
            corresponds) ;;
            partial)     _TA_CORR_FINDINGS+=("${_ids[_i]}'s assertion establishes only part of the requirement: ${_reasons[_i]} (not established: ${_quotes[_i]})") ;;
            mismatch)    _TA_CORR_FINDINGS+=("${_ids[_i]}'s assertion does not test what the requirement says: ${_reasons[_i]} (not established: ${_quotes[_i]})") ;;
            uncheckable) _TA_CORR_FINDINGS+=("${_ids[_i]}: it cannot be said what would establish this requirement: ${_reasons[_i]} (unclear: ${_quotes[_i]})") ;;
            *)           _unjudged=$(( _unjudged + 1 )) ;;
        esac
    done
    # #2062: a judge with no answer has no basis for "corresponds".
    [[ $_unjudged -gt 0 ]] && _TA_CORR_OUTCOME=unusable
    return 0
}
