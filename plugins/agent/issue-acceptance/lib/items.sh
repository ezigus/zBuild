#!/usr/bin/env bash
# plugins/agent/issue-acceptance/lib/items.sh — issue-acceptance keeps a
# verdict per item (#2574, ADR-072 §4 §5), as design's check does.
#
# It kept one verdict for the whole change, with the answers to its findings
# in that verdict's fingerprint: any change or new answer — or an answer no
# longer given — had every requirement judged again, which is where verdicts
# flipped. Now the items are each requirement (with no list, the issue as one
# item), each limit, the reverse question (`unasked`) and the questions it
# carries (`unclear`). A kept pass stands unless its item's inputs changed; an
# answer to one of its findings has a kept refusal judged again, held to it
# (judge_kept_get_all_v with the pass words); only the items whose verdict no
# longer holds are asked, in one call. Its callers are in plugin.sh.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_IA_ITEMS_LOADED:-}" ]] && return 0
_ZBUILD_IA_ITEMS_LOADED=1

# The verdict words a kept line is read by (judge_refused): the pass words, and
# with a `!` the refusal words a line may start with.
_IA_PASS_WORDS="met kept none !unmet !unsure !broken"

# _ia_line_name_v <var> <rest> — the id a verdict line names: the text before
# its first bar, its [fix-…] mark and trailing colon aside.
_ia_line_name_v() {
    local -n _iln="$1"; local r="$2"
    [[ "$r" =~ ^\[fix-[a-z]+\][[:space:]]*(.*)$ ]] && r="${BASH_REMATCH[1]}"
    r="${r%%|*}"; r="${r%"${r##*[![:space:]]}"}"; _iln="${r%:}"
}

# _ia_item_of_v <var> <line> <listed> — the item a reply line is about: a
# requirement's id (with no list, `issue`), a limit's id, `unasked`, `unclear`
# or `answers`; empty for any other line.
_ia_item_of_v() {
    local -n _iio="$1"; local l
    _iio=""
    judge_reply_line_v l "$2"
    if [[ "$l" =~ ^(MET|UNMET|UNSURE):[[:space:]]*(.*)$ ]]; then
        if [[ "$3" == 1 ]]; then _ia_line_name_v _iio "${BASH_REMATCH[2]}"; else _iio=issue; fi
    elif [[ "$l" =~ ^(KEPT|BROKEN):[[:space:]]*(.*)$ ]]; then _ia_line_name_v _iio "${BASH_REMATCH[2]}"
    elif [[ "$l" =~ ^UNASKED: ]]; then _iio=unasked
    elif [[ "$l" =~ ^UNCLEAR([[:space:]]|:) ]]; then _iio=unclear
    elif [[ "$l" =~ ^ANSWER[[:space:]] ]]; then _iio=answers
    fi
    return 0
}

# _ia_item_of_finding_v <var> <text> — the item one of its findings is about,
# as _ia_write words them; empty when it names none.
_ia_item_of_finding_v() {
    local -n _iif="$1"; local t="$2"
    _iif=""
    case "$t" in
        "The change does this and no requirement asks for it:"*) _iif=unasked; return 0 ;;
        "The issue is unclear here"*) _iif=unclear; return 0 ;;
        "The issue requires this and the change does not meet it: "*) t="${t#*meet it: }" ;;
        "Not sure this requirement is met: "*) t="${t#*is met: }" ;;
        *) return 0 ;;
    esac
    [[ "$t" =~ ^\[fix-[a-z]+\][[:space:]]*(.*)$ ]] && t="${BASH_REMATCH[1]}"
    _iif="${t%%:*}"
}

# _ia_judge — the judging part of issue_acceptance_run, in its scope (issue,
# acc, change, _change_fp, test_verdict, tier, art, _reqs, _lims, _terms,
# _root_q, diff_f): every item's kept verdict that still holds, one call for
# the rest, and the stage's result. rc as issue_acceptance_run's.
# shellcheck disable=SC2154,SC2034  # its inputs are the caller's; earlier, putfp are passed by name
_ia_judge() {
    local kf="${art%/}/issue-acceptance-judged.json" eng _ans="" l k t it ti a
    judge_engine_v eng
    judge_answers_to_v _ans "$art" issue-acceptance issue-acceptance-design issue-acceptance-test issue-acceptance-code ${_IA_FCODE:+"$_IA_FCODE"}
    local -a _ia_lf=(); for l in "" -design -test -code; do _ia_lf+=("issue-acceptance$l=${art%/}/issue-acceptance$l-result.json"); done
    # The items, and what each verdict is kept under.
    local -a rids=() lids=() items=()
    local -A rline=() lline=() fps=()
    while IFS= read -r l; do
        [[ "$l" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] || continue
        rids+=("${BASH_REMATCH[1]}"); rline["${BASH_REMATCH[1]}"]="$l"
    done <<< "$_reqs"
    while IFS= read -r l; do
        [[ "$l" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] || continue
        lids+=("${BASH_REMATCH[1]}"); lline["${BASH_REMATCH[1]}"]="$l"
    done <<< "$_lims"
    local listed=0; [[ ${#rids[@]} -gt 0 ]] && listed=1
    # What a requirement or limit is judged by that is not its own — the
    # change's files, the test verdict, the issue's words and terms — is one checksum
    # for every item (ADR-065 §5); the item's own lines are its words.
    local chg="${change//"${diff_f:-<none>}"/<the patch>}" accl _fp _sfp
    # Review on #2574: and the change's content (_change_fp: each changed file's
    # blob, or the patch) — a kept MET must not survive a regression in a file
    # no line quoted and the call did not open.
    judge_fp_v _sfp "$eng"$'\n'"$issue"$'\n'"$_terms"$'\n'"$test_verdict"$'\n'"$chg"$'\n'"$_change_fp"
    if (( listed )); then
        for k in "${rids[@]}"; do
            accl=""; while IFS= read -r l; do [[ "$l" == *"$k"* ]] && accl+="$l"$'\n'; done <<< "$acc"
            # One line, no tab: a kept file's record reads its fingerprint so.
            accl="${rline[$k]}|$accl"; fps["$k"]="$_sfp|req|${accl//[$'\n\t']/ }"; items+=("$k")
        done
    else
        judge_fp_v _fp "$eng"$'\n'"$issue"$'\n'"$_lims"$'\n'"$_terms"$'\n'"$acc"$'\n'"$_change_fp"$'\n'"$test_verdict"
        fps[issue]="$_fp"; items+=(issue)
    fi
    for k in ${lids[@]+"${lids[@]}"}; do fps["$k"]="$_sfp|lim|${lline[$k]//$'\t'/ }"; items+=("$k"); done
    judge_fp_v _fp "$eng"$'\n'unasked$'\n'"$_change_fp"$'\n'"$issue"$'\n'"$_reqs"$'\n'"$acc"; fps[unasked]="$_fp"; items+=(unasked)
    # The questions it carries are an item while there are any (#2571): its
    # next call judges each.
    accl="${_IA_UQ_CARRIED:-}|$_reqs"; fps[unclear]="$_sfp|unclear|${accl//[$'\n\t']/ }"
    [[ -n "${_IA_UQ_CARRIED:-}" ]] && items+=(unclear)
    fps[answers]="$eng|answers"
    # Each answer to one of its findings, by the item the finding is about; one
    # that names none is every item's (#2569, ADR-072 §5).
    local -A af=() disp=() dfp=() held=() kept=() earlier=() kwhy=() keyit=()
    [[ -n "$_ans" ]] && judge_answered_findings_v af "$_ans" "${_ia_lf[@]}"
    while IFS= read -r a; do
        k="${a%%:*}"; [[ -n "$k" && -n "${af[$k]+x}" ]] || continue
        _ia_item_of_finding_v ti "${af[$k]%%$'\x1f'*}"
        local -a _to=("$ti"); [[ -n "$ti" && -n "${fps[$ti]+x}" ]] || { _to=("${items[@]}"); ti=""; }
        for it in "${_to[@]}"; do disp["$it"]+="$a"$'\n'; held["$it"]+="$k"$'\x1c'"${af[$k]}"$'\x1d'; done
        # A finding no item holds is every item's, and hands none on.
        [[ -n "$ti" ]] && keyit["$k"]="$ti"
        af["$k"]=""; unset 'af[$k]'
    done <<< "$_ans"
    for it in "${!disp[@]}"; do judge_fp_v _fp "${disp[$it]}"; dfp["$it"]="$_fp"; done
    # #2579 (ADR-072 §4): each requirement's and limit's words, kept with its verdict.
    _JUDGE_ITEM_TEXT=()
    for k in "${!rline[@]}"; do _JUDGE_ITEM_TEXT["$k"]="${rline[$k]}"; done
    for k in "${!lline[@]}"; do _JUDGE_ITEM_TEXT["$k"]="${lline[$k]}"; done
    judge_kept_get_all_v kept "$kf" fps dfp earlier "$_IA_PASS_WORDS" kwhy
    # #2574 (ADR-072 §5): an item a stage handed on waits, its last verdict
    # standing; one back from the stage it was handed to is judged again.
    judge_handoff_check "$kf" "$_ans" keyit kept earlier "${items[@]}"
    for it in "${!_JUDGE_HANDOFF_WAIT[@]}"; do
        judge_handoff_waiting_v l "${_JUDGE_HANDOFF_WAIT[$it]}"; _IA_HANDOFF_NOTES+="$it: $l"$'\n'
    done
    for it in "${!_JUDGE_HANDOFF_BACK[@]}"; do
        [[ -n "${held[$it]:-}" ]] || held["$it"]="$it"$'\x1c'"${_JUDGE_HANDOFF_BACK[$it]}"$'\x1d'
    done
    # A kept answer is read as it was given; kept ones that no longer read are judged again.
    local kraw="" kwant="" want=""
    for it in "${items[@]}"; do
        if [[ -n "${kept[$it]+x}" ]]; then kraw+="${kept[$it]}"$'\n'; kwant+=" $it"; else want+=" $it"; fi
    done
    if [[ -n "$kwant" ]]; then
        _ia_parse "$kraw" "$_reqs" "$issue" "$_root_q" "$_lims" "$kwant"
        [[ -n "$_IA_PROBLEM" ]] && { want+="$kwant"; kraw=""; kwant=""; }
    fi
    if [[ -z "$want" ]]; then
        # Nothing to ask: the kept verdicts stand, and so do the answers it gave.
        _ia_parse "$kraw" "$_reqs" "$issue" "$_root_q" "$_lims"
        zb_answers_collect_v _IA_ANSWERS "${kept[answers]:-}"
        _JUDGE_ITEM_TEXT=(); _ia_finish "$art"; return 0
    fi
    # The items asked, and what it is shown of the ones kept.
    local areqs="" alims="" others="" rev=1 _held=""
    for it in $want; do
        [[ -n "${rline[$it]+x}" ]] && areqs+="${rline[$it]}"$'\n'
        [[ -n "${lline[$it]+x}" ]] && alims+="${lline[$it]}"$'\n'
    done
    (( listed )) || areqs="$_reqs"
    for it in $kwant; do
        [[ -n "${rline[$it]+x}${lline[$it]+x}" ]] && others+="- $it — judged before; its verdict is kept"$'\n'
        [[ "$it" == unasked ]] && rev=0
    done
    (( listed )) && [[ -z "$areqs" ]] && areqs="<none to judge this time: every requirement keeps its verdict — write no MET: or UNMET: line>"
    local _he _hk _hv _hf
    for it in $want; do
        while IFS= read -r -d $'\x1d' _he; do
            _hk="${_he%%$'\x1c'*}"; _hv="${_he#*$'\x1c'}"; _hf=""
            [[ "$_held" == *"- $_hk: "* ]] && continue
            case "${kwhy[$it]:-}" in disputed) _hf=same ;; fingerprint|file) _hf=changed ;; esac
            judge_held_entry_v _he "$_hk" "$_hv" "$_hf"; _held+="$_he"
        done <<< "${held[$it]:-}"
    done
    judge_held_block_v _held "$_held"
    local _chg="" _was
    for it in $want; do
        judge_item_was_v _was "$it"; [[ -n "$_was" ]] || continue
        judge_changed_entry_v _he "$it" "$_was" "${_JUDGE_ITEM_TEXT[$it]}"; _chg+="$_he"
    done
    judge_changed_block_v _chg "$_chg"; _held+="$_chg"
    # Review on #2574: each pass judged again because the code moved, shown so.
    local _pas=""; judge_pass_entries_v _pas earlier kwhy "$_IA_PASS_WORDS" "fingerprint file" $want
    judge_pass_block_v _pas "$_pas"; _held+="$_pas"
    local _uqb=""; zb_unclear_judge_block_v _uqb "$_IA_UQ_CARRIED"
    [[ -n "$_uqb" ]] && _held+=$'\n'"$_uqb"$'\n'
    _ia_call "$(_ia_prompt "$issue" "${acc:-<none>}" "${change:-<no change found>}" "${test_verdict:-unknown}" "${areqs%$'\n'}" "$_held" "${alims%$'\n'}" "$_terms" "$rev" "${others%$'\n'}")" "$want" || return "$_IA_STOP_RC"
    # Each item asked is kept with the files the call read and those its own
    # lines quote; the verdict is every item's: the kept ones and this call's.
    local -A pay=() put=() putfp=() deps=() carry=()
    local _opened_all="" q qp
    for l in ${_IA_DEPS[@]+"${_IA_DEPS[@]}"}; do _opened_all+="$l"$'\n'; done
    while IFS= read -r l; do
        _ia_item_of_v it "$l" "$listed"; [[ -n "$it" ]] || continue
        pay["$it"]+="$l"$'\n'
        judge_reply_field_v q "$l" QUOTE; [[ -n "$q" ]] || continue
        judge_quote_path_v qp "$q" "$_root_q"; [[ -n "$qp" ]] && deps["$it"]+="$_root_q/$qp"$'\n'
    done <<< "$_IA_RAW"
    # A kept pass judged again is refused only on a line added since; else it stands.
    for it in $want; do
        [[ -n "${earlier[$it]+x}" && -n "${pay[$it]:-}" ]] || continue
        case "${kwhy[$it]:-}" in fingerprint|file) ;; *) continue ;; esac
        judge_pass_hold_lines "$kf" "$it" "$_root_q" "${earlier[$it]}" "pay[$it]" "$_IA_PASS_WORDS" || continue
        # A held pass keeps the baseline of the verdict that passed it.
        pay["$it"]+=$'\n'; carry["$it"]=1
    done
    local nraw=""
    # A question raised now, with no question carried, is read, and carried
    # by the result (data.unclear), not kept here.
    [[ " $want " == *" unclear "* ]] || nraw+="${pay[unclear]:-}"
    for it in $want answers; do
        # shellcheck disable=SC2034  # put, putfp and deps are read by judge_kept_put_all through their names
        { put["$it"]="${pay[$it]:-}"; judge_kept_fp_v "putfp[$it]" "${fps[$it]}" "${dfp[$it]:-}"; deps["$it"]+="$_opened_all"; }
        [[ "$it" == answers ]] || nraw+="${pay[$it]:-}"
    done
    # Each verdict kept with the repository as it is now (#2574 review).
    local _JUDGE_KEEP_BASE=""; judge_keep_baseline_v _JUDGE_KEEP_BASE "$_root_q"
    judge_kept_put_all "$kf" put putfp deps carry
    _JUDGE_ITEM_TEXT=()
    judge_handoff_done "$kf"
    _ia_parse "$kraw$nraw" "$_reqs" "$issue" "$_root_q" "$_lims"
    _ia_finish "$art"
    return 0
}
