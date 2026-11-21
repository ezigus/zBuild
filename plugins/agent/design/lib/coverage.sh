#!/usr/bin/env bash
# plugins/agent/design/lib/coverage.sh — design's second model call: do the
# SPECs cover what the issue asks? (#2369, ADR-040 §5, ADR-070 §4; was the
# spec-coverage stage, #1683.)
#
# Its standard is the issue, which design cannot re-author, so the only way to
# pass is to cover it. The call is given the list beside the issue's own words
# (ADR-070 §4), found among the stage's inputs by what they are: on #1805 run
# 42340358110 it was told the issue was under Previous work, where it was not.
#
# #2464 (ADR-072): the check judges — it reads the code itself, read-only, and
# a [done] claim on the code from before the change; it answers one line for
# every requirement and every SPEC, each complaint quoted; and its answer is
# kept while nothing it judged has changed. #2569: an item it refused, which
# design answered, is judged again, shown the finding and the answer.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_DESIGN_COVERAGE_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_COVERAGE_LOADED=1
# #2460: a reply is read in whole units; loaded here too, for a caller that
# sources this file alone.
declare -F zb_reply_join_v >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/reply-units.sh" 2>/dev/null || true
# shellcheck source=../../../../scripts/lib/judge.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/judge.sh"
# shellcheck source=./coverage-answer.sh
source "${BASH_SOURCE[0]%/*}/coverage-answer.sh"
# shellcheck source=./coverage-prompt.sh
source "${BASH_SOURCE[0]%/*}/coverage-prompt.sh"

# _dcov_steps_v <var> <design_md> — the lines of the design's ```steps block.
_dcov_steps_v() {
    local -n _dsv="$1"; local _l _in=0
    _dsv=""
    [[ -f "$2" ]] || return 0
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        if [[ "$_l" =~ ^'```steps'[[:space:]]*$ ]]; then _in=1; continue; fi
        [[ $_in -eq 1 && "$_l" =~ ^'```' ]] && break
        [[ $_in -eq 1 ]] && _dsv+="$_l"$'\n'
    done < "$2"
    return 0
}

# _dcov_unclear_v <var> <design_md> — the questions the design carries, one
# readable UNCLEAR line per line, as written (#2571, ADR-069 §12): judged by
# the check as one more item, through the shared block (scripts/lib/unclear.sh).
_dcov_unclear_v() {
    local -n _duv="$1"; local -a _duv_l=(); local _duv_x _duv_p
    _duv=""
    zb_unclear_lines_v _duv_l "${2:-}"
    for _duv_x in ${_duv_l[@]+"${_duv_l[@]}"}; do
        zb_unclear_parse_v _duv_p "$_duv_x" && _duv+="$_duv_x"$'\n'
    done
    return 0
}

# _dcov_decision_v <var> <design_md> — the design's decisions (#2567, ADR-073 §5).
_dcov_decision_v() {
    # #2567: the one decisions extractor build and the lenses read (acceptance-judge.sh), uncapped.
    design_decisions_prose_v "$1" "${2:-}" 0
}

# _dcov_specs <acceptance> — every SPEC of the block, read once, into the
# caller's ids, first, text, st, render, labs, pword and ptext: its first line as
# written, its words, its status, the whole SPEC as a model is shown it, and
# each part by its label (Then 2) with the word design wrote (And) and its words.
_dcov_specs() {
    local _dsl _dsid _dsi _dslab
    while IFS= read -r _dsl; do
        [[ "$_dsl" =~ $_ACCEPTANCE_SPEC_RE ]] || continue
        _dsid="${BASH_REMATCH[1]}"
        _acceptance_spec_line "$_dsl" "$_dsid" || continue
        ids+=("$_dsid"); text["$_dsid"]="$_ACC_SPEC_TEXT"; st["$_dsid"]="$_ACC_SPEC_STATUS"
        first["$_dsid"]="$_dsid${_ACC_SPEC_TAG:+[$_ACC_SPEC_TAG]}: $_ACC_SPEC_REST"
        render["$_dsid"]="${first[$_dsid]}"; labs["$_dsid"]=""
        local -a _dsp=() _dsw=()
        acceptance_parts_v _dsp "$_ACC_SPEC_PARTS" "" _dsw
        for _dsi in "${!_dsp[@]}"; do
            _dslab="${_dsp[_dsi]%%$'\t'*}"
            labs["$_dsid"]+="$_dslab"$'\n'
            pword["$_dsid $_dslab"]="${_dsw[_dsi]}"; ptext["$_dsid $_dslab"]="${_dsp[_dsi]#*$'\t'}"
            render["$_dsid"]+=$'\n'"  ${_dsw[_dsi]}: ${_dsp[_dsi]#*$'\t'}"
        done
    done <<< "$1"
}

# _dcov_done_evidence_v <assoc_var> <design_md> <base_dir> — each [done] SPEC's
# evidence, by file and text, per SPEC: the check opens the code itself, in the
# copy of the code from before the change (#2464, ADR-069 §2), never a window
# of it. Reads the caller's ids and st.
_dcov_done_evidence_v() {
    local -n _dde="$1"; local _dde_sid _dde_item _dde_path
    # shellcheck disable=SC2034  # the split's text and line, not needed here
    local _t _n
    for _dde_sid in ${ids[@]+"${ids[@]}"}; do
        [[ "${st[$_dde_sid]}" == "done" ]] || continue
        while IFS= read -r _dde_item; do
            [[ -n "$_dde_item" ]] || continue
            acceptance_evidence_split "$_dde_item" _dde_path _t _n
            _dde["$_dde_sid"]+="- $_dde_sid: $_dde_item — open ${3:+$3/}$_dde_path"$'\n'
        done < <(acceptance_spec_evidence "$2" "$_dde_sid" 2>/dev/null)
    done
}

# _dcov_ev_items_v <var> <done_evidence> <base> — the evidence as its
# fingerprint takes it: without the copy's path, which differs every run; with
# no copy, unchanged (review on #2465: an empty base stripped every `/`).
_dcov_ev_items_v() {
    local -n _dei="$1"
    if [[ -n "$3" ]]; then _dei="${2//"$3/"/}"; else _dei="$2"; fi
}

# _dcov_answered_v <assoc_var> <answers> <verdict_json> [held_assoc] — each
# answer design gave a finding of this check, done, wrong or not mine
# (zb_answer_kind_v), by the item its finding is about: a SPEC id,
# `requirements` for a requirement's, `steps` or `decision`. An item it refused
# that design answered is judged again (judge_kept_get_all_v, disputed);
# [held_assoc] gets each answer with the finding as design was given it, for
# the check to be held to (#2569, ADR-072 §5): "<key><FS><finding and
# answer><FS><1 when the finding names no item>", one per GS, rendered by
# _dcov_held_v. A finding's first word names its item, as
# _design_coverage_findings writes it; one that names nothing known is every
# SPEC's and the requirements' (#2470).
_dcov_answered_v() {
    local -n _ddv="$1"; local _ddv_hn="${4:-_ddv_noh}" _ddv_a _ddv_t _ddv_id _ddv_k _ddv_e _ddv_x
    local -A _ddv_noh=()
    local -n _ddv_h="$_ddv_hn"
    [[ "$2" == *"design finding "* || ( -n "${_DESIGN_FCODE:-}" && "$2" == *"$_DESIGN_FCODE-"* ) ]] || return 0
    local -A _ddv_af=()
    judge_answered_findings_v _ddv_af "$2" "design=$3"
    # #2574: an answer names the finding's id (DSFND-<n>), or its place.
    local _ddv_re="^(design finding [0-9]+${_DESIGN_FCODE:+|$_DESIGN_FCODE-[0-9]+})[[:space:]]*:"
    while IFS= read -r _ddv_a; do
        [[ "$_ddv_a" =~ $_ddv_re ]] || continue
        _ddv_k="${BASH_REMATCH[1]}"
        [[ -n "${_ddv_af[$_ddv_k]+x}" ]] || continue
        zb_answer_kind_v _ddv_x "$_ddv_a"; [[ -n "$_ddv_x" ]] || continue
        _ddv_t="${_ddv_af[$_ddv_k]%%$'\x1f'*}"; _ddv_e="$_ddv_k"$'\x1c'"${_ddv_af[$_ddv_k]}"
        unset '_ddv_af[$_ddv_k]'
        _ddv_id="${_ddv_t%%[: ]*}"
        if [[ -n "${first[$_ddv_id]+x}" ]]; then :
        elif [[ -n "${req_text[$_ddv_id]+x}" ]]; then _ddv_id=requirements
        elif [[ "$_ddv_id" == Steps ]]; then _ddv_id=steps
        elif [[ "$_ddv_id" == Decision ]]; then _ddv_id=decision
        elif [[ "$_ddv_id" == UNCLEAR ]]; then _ddv_id=unclear
        else
            for _ddv_x in ${ids[@]+"${ids[@]}"} requirements; do _ddv["$_ddv_x"]+="$_ddv_a"$'\n'; _ddv_h["$_ddv_x"]+="$_ddv_e"$'\x1c'1$'\x1d'; done
            continue
        fi
        _ddv["$_ddv_id"]+="$_ddv_a"$'\n'; _ddv_h["$_ddv_id"]+="$_ddv_e"$'\x1c'0$'\x1d'
    done <<< "$2"
}

# _dcov_held_v <var> <items> — the earlier findings on each item of <items>
# (one per line) and design's answers, in _design_coverage's scope (held,
# kwhy): each finding once, with whether its item is the same as when it was
# refused (judge_held_entry_v; review on #2569). A finding that names no item
# is every item's, so nothing is said of one.
_dcov_held_v() {
    local -n _dhv="$1"; local _dhv_k _dhv_e _dhv_key _dhv_val _dhv_bc _dhv_f _dhv_r
    local -A _dhv_seen=()
    _dhv=""
    while IFS= read -r _dhv_k; do
        [[ -n "$_dhv_k" && -n "${held[$_dhv_k]:-}" ]] || continue
        while IFS= read -r -d $'\x1d' _dhv_e; do
            _dhv_key="${_dhv_e%%$'\x1c'*}"; _dhv_e="${_dhv_e#*$'\x1c'}"
            _dhv_val="${_dhv_e%$'\x1c'*}"; _dhv_bc="${_dhv_e##*$'\x1c'}"
            [[ -n "${_dhv_seen[$_dhv_key]+x}" ]] && continue
            _dhv_seen["$_dhv_key"]=1; _dhv_f=""
            if [[ "$_dhv_bc" != 1 ]]; then
                case "${kwhy[$_dhv_k]:-}" in disputed) _dhv_f=same ;; fingerprint|file) _dhv_f=changed ;; esac
            fi
            judge_held_entry_v _dhv_r "$_dhv_key" "$_dhv_val" "$_dhv_f"; _dhv+="$_dhv_r"
        done <<< "${held[$_dhv_k]}"
    done <<< "$2"
}

# _design_coverage <design_md> <requirements_text> [tier] [answers]
# Sets _DESIGN_UNCOVERED, _DESIGN_OUTSIDE, _DESIGN_STATUS_WRONG,
# _DESIGN_PART_WRONG and _DESIGN_COV_OUTCOME: empty when
# the call judged the design, otherwise the outcome word for how the call failed
# (rate_limited, unavailable, unusable, misconfigured, broken);
# _DESIGN_COV_NOTES, what the run log is told that is no finding. [answers]:
# design's own answers to findings of this check, one per line (ADR-072 §5).
#
# #2470 (ADR-072 §4): the answer is kept per SPEC, and requirement coverage as
# one more item. A SPEC is judged again only when it, its evidence or an answer
# to its finding changed; requirement coverage whenever any SPEC changed. The
# call is given the draft by its path and, in full, only the SPECs it judges.
# rc 0 always.
_design_coverage() {
    local design_md="$1" reqs="$2" tier="${3:-T2}" answers="${4:-}" lims="${5:-}" terms="${6:-}"
    _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_STATUS_WRONG=(); _DESIGN_COV_OUTCOME=""
    _DESIGN_PART_WRONG=(); _DESIGN_COV_FINDINGS=(); _DESIGN_NEW_OWNER=(); _DESIGN_REQ_NONE=()
    _DESIGN_STEP_WRONG=(); _DESIGN_DECISION_WRONG=(); _DESIGN_UNCLEAR_DROP=(); _DESIGN_COV_NOTES=()
    local acc; acc="$(extract_acceptance_block "$design_md" 2>/dev/null || true)"
    [[ -n "$acc" ]] || return 0

    local -a ids=() req_order=()
    # shellcheck disable=SC2034  # read by coverage-answer.sh, in this scope
    local -A first=() text=() st=() render=() labs=() pword=() ptext=() req_text=()
    local -A _DCOV_LINES=() _DCOV_QUOTED=()
    _dcov_specs "$acc"
    local l
    while IFS= read -r l; do
        [[ "$l" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] || continue
        req_text["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"; req_order+=("${BASH_REMATCH[1]}")
    done <<< "$reqs"

    local repo="${ZBUILD_REPO_ROOT:-$PWD}" base="" base_sha=""
    # #2482: the copy design's prompt named, when it has run — the local
    # _DESIGN_BASE_DIR of _design_stage_run_inner (plugin.sh), read through
    # bash's dynamic scope; else, called on its own, made here.
    if [[ -n "${_DESIGN_BASE_DIR+x}" ]]; then base="$_DESIGN_BASE_DIR"
    else judge_base_dir_v base "$repo" || base=""; fi
    [[ -n "$base" && -f "$base.sha" ]] && base_sha="$(<"$base.sha")"
    local -A ev=()
    _dcov_done_evidence_v ev "$design_md" "$base"

    local kf="" eng id _kd="${artifact_dir:-${ZBUILD_ARTIFACT_DIR:-}}"
    [[ -n "$_kd" ]] && kf="${_kd%/}/design-judged.json"
    judge_engine_v eng
    # Review on #2569 (ADR-072 §4 §5): an answer is not in an item's
    # fingerprint. A kept refusal of an item design answered is judged again,
    # held to its finding; a kept pass stays, so the next try, with no answer,
    # does not judge the item from scratch (#1764's flip).
    local -A disp=() held=() fps=() kept=() kwhy=() _earl=() dfp=()
    _dcov_answered_v disp "$answers" "${_kd:+${_kd%/}/design-verdict.json}" held
    # Each answered item's answers, by fingerprint: a verdict is kept with the
    # answers it heard, so the same answer again is not judged again.
    local k _fpv
    for k in "${!disp[@]}"; do judge_fp_v _fpv "${disp[$k]}"; dfp["$k"]="$_fpv"; done
    local _all="" _ev_all="" _evi _fpv
    for id in ${ids[@]+"${ids[@]}"}; do
        _dcov_ev_items_v _evi "${ev[$id]:-}" "$base"
        _ev_all+="$_evi"; _all+="${render[$id]}"$'\n'
        judge_fp_v _fpv "$eng"$'\n'"$id"$'\n'"${render[$id]}"$'\n'"$_evi"$'\n'"$base_sha"$'\n'"$lims"$'\n'"$terms"
        fps["$id"]="$_fpv"
    done
    judge_fp_v _fpv "$eng"$'\n'"$reqs"$'\n'"$_all"$'\n'"$_ev_all"$'\n'"$base_sha"$'\n'"$lims"$'\n'"$terms"
    fps["requirements"]="$_fpv"
    # #2555 (ADR-072 §3): the design's steps are an item of their own, judged
    # for a new owner where one exists, and judged again only when they change.
    local steps=""; _dcov_steps_v steps "$design_md"
    if [[ -n "$steps" ]]; then
        # #2567: judged against the requirements, limits and terms too.
        judge_fp_v _fpv "$eng"$'\n'steps$'\n'"$steps"$'\n'"$base_sha"$'\n'"$reqs"$'\n'"$lims"$'\n'"$terms"
        fps["steps"]="$_fpv"
    fi
    # #2567 (ADR-073 §5): the design's decisions are an item too.
    local decision=""; _dcov_decision_v decision "$design_md"
    if [[ -n "$decision" ]]; then
        judge_fp_v _fpv "$eng"$'\n'decision$'\n'"$decision"$'\n'"$base_sha"$'\n'"$reqs"$'\n'"$lims"$'\n'"$terms"
        fps["decision"]="$_fpv"
    fi
    # #2571 (ADR-069 §12): the questions the design carries are an item too,
    # judged again when they, the requirements, limits, terms or the issue's
    # own words change (review on #2571: an open answer outlived the issue's edit).
    local unclear="" issue=""; _dcov_unclear_v unclear "$design_md"
    if [[ -n "$unclear" ]]; then
        issue="$(earlier_issue_text "${artifact_dir:-${ZBUILD_ARTIFACT_DIR:-}}" "${state_dir:-}" 2>/dev/null || true)"
        judge_fp_v _fpv "$eng"$'\n'unclear$'\n'"$unclear"$'\n'"$reqs"$'\n'"$lims"$'\n'"$terms"$'\n'"$issue"
        fps["unclear"]="$_fpv"
    fi
    # An open question is no refusal (judge_refused).
    [[ -n "$kf" ]] && judge_kept_get_all_v kept "$kf" fps dfp _earl "ok covered open" kwhy

    # A kept answer is read as it was given; one that no longer reads is judged again.
    local kept_raw="" kept_want="" k
    for k in "${!kept[@]}"; do kept_raw+="${kept[$k]}"; kept_want+="$k"$'\n'; done
    if [[ -n "$kept_want" ]]; then
        _dcov_parse "$kept_raw" "$kept_want"
        [[ -n "$_DCOV_PROBLEM" ]] && { kept=(); kept_raw=""; kept_want=""; }
    fi
    local want="" shown="" others="" done_ev=""
    for id in ${ids[@]+"${ids[@]}"}; do
        if [[ -n "${kept[$id]+x}" ]]; then others+="${first[$id]}"$'\n'; continue; fi
        want+="$id"$'\n'; shown+="${render[$id]}"$'\n'; done_ev+="${ev[$id]:-}"
    done
    local reqs_asked=""
    [[ -n "${kept["requirements"]+x}" ]] || { want+=requirements$'\n'; reqs_asked="$reqs"; }
    local steps_asked=""
    [[ -n "$steps" && -z "${kept["steps"]+x}" ]] && { want+=steps$'\n'; steps_asked="$steps"; }
    local decision_asked=""
    [[ -n "$decision" && -z "${kept["decision"]+x}" ]] && { want+=decision$'\n'; decision_asked="$decision"; }
    local unclear_asked=""
    [[ -n "$unclear" && -z "${kept["unclear"]+x}" ]] && { want+=unclear$'\n'; unclear_asked="$unclear"; }
    if [[ -z "$want" ]]; then
        _dcov_parse "$kept_raw" "$kept_want"
        _dcov_findings_build
        return 0
    fi

    local framed _disp_shown=""
    # #2567 (review): steps and decisions are judged against the requirements
    # and the issue's words, so they are shown whenever those parts are asked,
    # though the requirement lines are asked only with the requirements.
    local reqs_ctx=""
    [[ -z "$reqs_asked" && ( -n "$steps_asked" || -n "$decision_asked" ) ]] && reqs_ctx="$reqs"
    [[ -z "$issue" && -n "$reqs_asked$steps_asked$decision_asked$unclear_asked" ]] && issue="$(earlier_issue_text "${artifact_dir:-${ZBUILD_ARTIFACT_DIR:-}}" "${state_dir:-}" 2>/dev/null || true)"
    # #2569 (ADR-072 §5): each item asked that it refused before, with design's
    # answer to its finding, in the order the items are asked.
    _dcov_held_v _disp_shown "$want"
    judge_held_block_v _disp_shown "$_disp_shown"
    # Review on #2574: a pass judged again because a file it read moved (its
    # own words did not change) is refused only on a line added since.
    local _dpas=""; judge_pass_entries_v _dpas _earl kwhy "ok covered open" file $want
    judge_pass_block_v _dpas "$_dpas"; _disp_shown+="$_dpas"
    local _ublk=""; zb_unclear_judge_block_v _ublk "$unclear_asked"
    [[ -n "$_ublk" ]] && _disp_shown=$'\n'"$_ublk"$'\n'"$_disp_shown"
    # #2458: it judges, so it composes fresh — no notes, and no rule to confirm earlier work.
    if ! framed="$(stage_prompt_compose_text --fresh "$(_dcov_prompt_own "$reqs_asked" "$steps_asked" "$decision_asked")" "$(_dcov_prompt_judge "$design_md" "${shown%$'\n'}" "$reqs_asked" "${others%$'\n'}" "$done_ev" "$base" "$issue" "$lims" "$terms" "$steps_asked" "$decision_asked" "$reqs_ctx")$_disp_shown" "$(_dcov_prompt_limits)")"; then
        _DESIGN_COV_OUTCOME=misconfigured
        return 0
    fi
    local raw="" rc=0 rc_file ask="$framed" _try opened="" need="$want"
    local -A got=() gotq=()
    # ADR-017 §12 (#2507): the call design's manifest lists as `coverage`,
    # with a judge's tools.
    local -x ZBUILD_ROUTE_CALL=coverage ZBUILD_ROUTER_OPENED_FILE=""
    opened="$(mktemp 2>/dev/null)" && ZBUILD_ROUTER_OPENED_FILE="$opened"
    # ADR-060 §6: an answer that cannot be used is asked again once, at once,
    # with what was wrong and the answer. A failed call is not asked again.
    for _try in 1 2; do
        rc=0
        # Without a file to keep the call's exit code in, a failed call would read
        # as a verdict (review on PR #2393): the check cannot run.
        if ! rc_file="$(mktemp)" || [[ -z "$rc_file" ]]; then
            _DESIGN_COV_OUTCOME=broken
            rm -f "$opened" 2>/dev/null
            return 0
        fi
        # No 2>/dev/null on this call: the stage-io input banner writes to fd 2 and
        # suppressing it breaks ADR-015 §v4's ordering (the #491 defect).
        raw="$(route_to_model "$tier" "$ask"; printf '%s' "$?" > "$rc_file" || true)"
        if [[ -n "$rc_file" && -f "$rc_file" ]]; then
            rc="$(cat "$rc_file" 2>/dev/null || echo 0)"; rm -f "$rc_file" 2>/dev/null || true
        fi

        # The call's rc is classified on every path: a call that printed a readable
        # verdict and then failed still failed (review on PR #2262).
        if [[ "$rc" -ne 0 ]]; then
            local _rv _rr
            _router_rc_classify "$rc" _rv _rr 2>/dev/null || true
            # disposition-ok: the model router is not responding
            _DESIGN_COV_OUTCOME="$(router_reason_disposition "${_rr:-}" 2>/dev/null || true)"
            [[ -n "$_DESIGN_COV_OUTCOME" ]] || _DESIGN_COV_OUTCOME=unavailable
            rm -f "$opened" 2>/dev/null
            return 0
        fi
        # #2460: each item read whole, however many lines it spans.
        zb_reply_join_v raw "$raw"
        # #2472: an item whose lines are good is taken at once; the re-ask asks
        # only for the items whose lines are not.
        _dcov_take "$raw" "$need"
        [[ -z "$need" ]] && break
        ask="$(stage_prompt_reask "$framed" "$_DCOV_PROBLEM"$'\n\n'"Answer again only for: $(_dcov_need_names "$need")" "$raw")"
    done
    local -a files=()
    # ADR-072 §4 (#2472): the draft and design.md are not depended on — each
    # SPEC's own words are in its fingerprint.
    judge_opened_v files "$opened" "$design_md" "${_kd:+${_kd%/}/design.md}"; rm -f "$opened" 2>/dev/null
    # Each item judged is kept with what it depended on: the files the call
    # opened, and the files its own quotes name — even when another item's
    # lines could not be used (#2472).
    # shellcheck disable=SC2034  # putfp is passed by name to judge_kept_put_all
    local -A put=() putfp=() deps=() carry=()
    local _opened_all="" f q
    for f in ${files[@]+"${files[@]}"}; do _opened_all+="$f"$'\n'; done
    local new_raw="" new_want=""
    while IFS= read -r k; do
        [[ -n "$k" && -n "${got[$k]+x}" ]] || continue
        if [[ "${kwhy[$k]:-}" == file && -n "${_earl[$k]+x}" ]] \
            && judge_pass_hold_lines "$kf" "$k" "$repo" "${_earl[$k]}" "got[$k]" "ok covered open"; then
            got["$k"]="${got[$k]%$'\n'}"$'\n'; gotq["$k"]=""
            # shellcheck disable=SC2034  # carry is read by judge_kept_put_all by name
            carry["$k"]=1
        fi
        # shellcheck disable=SC2034  # passed by name to judge_kept_put_all
        { put["$k"]="${got[$k]}"; judge_kept_fp_v "putfp[$k]" "${fps[$k]}" "${dfp[$k]:-}"; deps["$k"]="$_opened_all"; }
        while IFS= read -r q; do [[ -n "$q" ]] && deps["$k"]+="$repo/$q"$'\n'; done <<< "${gotq[$k]:-}"
        new_raw+="${got[$k]}"; new_want+="$k"$'\n'
    done <<< "$want"
    # Kept with the repository as it is; a held pass keeps its own (#2574 review).
    local _JUDGE_KEEP_BASE=""; [[ -n "$kf" ]] && judge_keep_baseline_v _JUDGE_KEEP_BASE "$repo"
    [[ -n "$kf" ]] && judge_kept_put_all "$kf" put putfp deps carry
    # Review on #2571 (ADR-069 §12): carried questions still unjudged after the
    # one re-ask stay open — not kept, so the next try judges them — and the
    # other items' answers stand; a note says so. They never fail the try.
    if [[ "$need" == *$'\n'unclear$'\n'* || "$need" == unclear$'\n'* ]]; then
        need="${need/#unclear$'\n'/}"; need="${need//$'\n'unclear$'\n'/$'\n'}"
        _DESIGN_COV_NOTES+=("the check gave no usable answer for the UNCLEAR questions the design carries ($_DCOV_PROBLEM): they stay open, with their assumptions, and are judged again on the next try")
    fi
    if [[ -n "$need" ]]; then
        # #2555 (R6): what the usable items found still reaches design, with a
        # note naming what was not judged; with nothing found, it cannot be used.
        local _why_left="$_DCOV_PROBLEM"
        _dcov_parse "$kept_raw$new_raw" "$kept_want$new_want"
        _dcov_findings_build
        # A requirement no test could observe stops the run now (#2565), even
        # when it is the only thing the usable items found.
        [[ ${#_DESIGN_REQ_NONE[@]} -gt 0 ]] && return 0
        if [[ ${#_DESIGN_COV_FINDINGS[@]} -eq 0 ]]; then
            _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_STATUS_WRONG=(); _DESIGN_PART_WRONG=(); _DESIGN_NEW_OWNER=(); _DESIGN_REQ_NONE=()
            _DESIGN_STEP_WRONG=(); _DESIGN_DECISION_WRONG=(); _DESIGN_UNCLEAR_DROP=()
            _DESIGN_COV_OUTCOME=unusable
            return 0
        fi
        _DESIGN_COV_FINDINGS+=("the check could not judge $(_dcov_need_names "$need"): $_why_left — it is judged again on the next try")
        return 0
    fi
    # The verdict is every item's answer: the kept ones and this call's.
    _dcov_parse "$kept_raw$new_raw" "$kept_want$new_want"
    _dcov_findings_build
    return 0
}
