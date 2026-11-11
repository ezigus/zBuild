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
# kept while nothing it judged has changed.
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

# The call's three parts, composed with the engine's blocks in the one prompt
# order (ADR-067 §8). #2470: requirement coverage is asked only when a SPEC
# changed or a requirement's finding was answered; with [reqs] it is.
_dcov_prompt_own() {
    local reqs="${1:-}"
    printf 'You are checking whether a DESIGN covers what an ISSUE asked for, SPEC by SPEC.\n'
    [[ -n "$reqs" ]] && cat <<'EOF2'

Check EVERY requirement, and find EVERY one that no SPEC fully covers — not
only the first you find. The design is revised once per round and fixes only
what you list; a gap left out of this answer costs a whole round.
EOF2
    cat <<'EOF2'

Look at every SPEC shown in full: find EVERY one that commits to
something that the issue does not ask for, or that contradicts it. For every
one marked [done], read the code its evidence names, as it was before this
change: find each one whose code does not do what it says. Then judge each of
its parts.

Answer in exactly this form, each line starting with its id.
EOF2
    [[ -n "$reqs" ]] && cat <<'EOF2'

One line for every requirement:

<requirement id>: covered
<requirement id>: uncovered | WHY: <what no SPEC covers> | QUOTE: <the requirement's own words that no SPEC covers>
EOF2
    cat <<'EOF2'

At least one line for every SPEC shown in full. When nothing is wrong with it,
one line:

<SPEC id>: ok

When something is wrong with it, one line for each thing wrong, and no ok line:

<SPEC id>: outside | WHY: <what the issue does not ask for, or how it contradicts it> | QUOTE: <the SPEC's own words that do>
<SPEC id>: done_wrong | WHY: <what the code does instead> | QUOTE: <file> | <one line of the code that shows it>
<SPEC id>: needs_cleanup | WHY: <what the Given or a Then leaves behind> | QUOTE: <the words of the part that leaves it>
<SPEC id> <part>: untestable | WHY: <why a test cannot observe it> | QUOTE: <that part's own words>
<SPEC id> <part>: how | WHY: <what it says about how it is built> | QUOTE: <that part's own words>
<SPEC id> <part>: contradicts | WHY: <what it cannot be true together with, and where that is> | QUOTE: <that part's own words>
<SPEC id> <part>: duplicate | WHY: <which SPEC already has this action> | QUOTE: <that part's own words>

<part> is the word the part's line starts with: Given, When, Then, And or
Cleanup. The QUOTE is copied from that line, and says which line it is when the
SPEC has several.

done_wrong is only for a SPEC marked [done]. untestable is only for a Then, or
an And under a Then: it must be something a test can observe after the When —
an output, a result, a file the code writes, an event — never what a file or a
test contains, and never "it works". duplicate is only for the When.
needs_cleanup is for a SPEC whose Given sets up, or whose Then says the code
leaves, something that outlives the test — an exported variable, a file outside
the test's own folder, global config or git state — when no Cleanup part puts
it back.
EOF2
    cat <<'EOF2'

Copy each QUOTE as it is from what it names, with no quote marks around it. It
is checked: a quote that is not there makes the answer unusable.
EOF2
}

# _dcov_prompt_judge <draft> <shown> [requirements] [others] [done_evidence] [base] [issue]
# — <shown> the SPECs to judge, in full; [others] the rest, by their first line,
# given only with [requirements], for what they cover (#2470, ADR-072 §4).
_dcov_prompt_judge() {
    cat <<EOF2
The design you judge is the file at $1 — read it there for anything you need
that is not shown here. Do not open design.md: it is an earlier design, not the
one you judge.
EOF2
    [[ -n "${7:-}" ]] && printf '\nISSUE — the issue itself, in the requester'"'"'s own words:\n%s\n' "$7"
    [[ -n "${3:-}" ]] && cat <<EOF2

REQUIREMENTS — the issue's requirements, each with its id.

Judge every requirement in REQUIREMENTS by its words. Read the issue for what a
requirement means. A SPEC may say which requirements it covers; check its
words, not only the ids it names.

An issue contains more than requirements — context, rationale, links, history.
Those are not requirements and their absence from the SPECs is not a gap. Judge
what the issue REQUIRES, not everything it mentions.

Several SPECs may cover one requirement together, one thing each: judge every
SPEC that names it, together.

Mapping is not enough: those SPECs together must demand ALL of the requirement.
A set of SPECs that demands less than the requirement — a subset of the cases,
a weaker condition, some of the files, a narrower scope — leaves it uncovered. Name the
requirement as uncovered and say what the SPECs leave out.

You judge the design before any code exists, so your part of each requirement
is the BEHAVIOUR it asks of the software. A requirement about how the change is
verified — that the tests fail on the code from before the change, that the
full suite is green, that the mutation tests run, that the tree is committed
first — can only be judged once the change and its tests exist, and the check
that compares the finished change with the issue judges it there. It is not
uncovered.

A SPEC tagged [done] says the code already does it. A requirement it covers
counts as covered: the claim is judged against the code once the change is
built.

REQUIREMENTS:
$3
EOF2
    printf '\nACCEPTANCE — the SPECs to judge, each with its parts:\n'
    printf 'ACCEPTANCE:\n%s\n' "${2:-(none)}"
    [[ -n "${3:-}" && -n "${4:-}" ]] && printf '\nOTHER SPECS — judged before and unchanged, shown by their first line for what they cover. Do not answer for them.\n%s\n' "$4"
    [[ -n "${5:-}" ]] && printf "\nTHE [done] SPECS' EVIDENCE — a file and a piece of its text. Open the file\nand read the code around that text, as much as you need:\n%s\n" "$5"
    [[ -n "${5:-}" && -n "${6:-}" ]] && printf '\nThe code from before this change is a copy at %s — read the code of each\n[done] SPEC there. The repository as it is now is the current directory.\n' "$6"
    return 0
}
_dcov_prompt_limits() {
    cat <<'EOF2'
- Do not suggest SPEC text.
- Do not rewrite the design.
- Answer only, in the form above.
EOF2
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

# _dcov_disputes_v <assoc_var> <answers> <verdict_json> — each `wrong` answer
# (zb_answer_kind_v) by the item its finding is about: a SPEC id, or
# `requirements` for a requirement's. A finding's first word names it, as
# _design_coverage_findings writes it; one that names nothing known disputes
# every item (#2470, ADR-072 §5).
_dcov_disputes_v() {
    local -n _ddv="$1"; local _ddv_a _ddv_n _ddv_t _ddv_id _ddv_k
    local -A _ddv_txt=()
    [[ "$2" == *wrong* ]] || return 0
    if [[ -s "$3" ]]; then
        while IFS=$'\t' read -r _ddv_n _ddv_t; do _ddv_txt["$_ddv_n"]="$_ddv_t"; done \
            < <(jq -r '(.data.findings // [])[]? | "\(.n)\t\(.text | tostring | split("\n")[0])"' "$3" 2>/dev/null)
    fi
    while IFS= read -r _ddv_a; do
        [[ "$_ddv_a" =~ ^design\ finding\ ([0-9]+)[[:space:]]*: ]] || continue
        _ddv_n="${BASH_REMATCH[1]}"; zb_answer_kind_v _ddv_k "$_ddv_a"; [[ "$_ddv_k" == wrong ]] || continue
        _ddv_t="${_ddv_txt[$_ddv_n]:-}"; _ddv_id="${_ddv_t%%[: ]*}"
        if [[ -n "${first[$_ddv_id]+x}" ]]; then _ddv["$_ddv_id"]+="$_ddv_a"$'\n'
        elif [[ -n "${req_text[$_ddv_id]+x}" ]]; then _ddv["requirements"]+="$_ddv_a"$'\n'
        else
            for _ddv_k in ${ids[@]+"${ids[@]}"} requirements; do _ddv["$_ddv_k"]+="$_ddv_a"$'\n'; done
        fi
    done <<< "$2"
}

# _design_coverage <design_md> <requirements_text> [tier] [answers]
# Sets _DESIGN_UNCOVERED, _DESIGN_OUTSIDE, _DESIGN_DONE_WRONG,
# _DESIGN_NEEDS_CLEANUP, _DESIGN_PART_WRONG and _DESIGN_COV_OUTCOME: empty when
# the call judged the design, otherwise the outcome word for how the call failed
# (rate_limited, unavailable, unusable, misconfigured, broken). [answers]:
# design's own answers to findings of this check, one per line (ADR-072 §5).
#
# #2470 (ADR-072 §4): the answer is kept per SPEC, and requirement coverage as
# one more item. A SPEC is judged again only when it, its evidence or an answer
# to its finding changed; requirement coverage whenever any SPEC changed. The
# call is given the draft by its path and, in full, only the SPECs it judges.
# rc 0 always.
_design_coverage() {
    local design_md="$1" reqs="$2" tier="${3:-T2}" answers="${4:-}"
    _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_DONE_WRONG=(); _DESIGN_COV_OUTCOME=""
    _DESIGN_PART_WRONG=(); _DESIGN_NEEDS_CLEANUP=(); _DESIGN_COV_FINDINGS=()
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
    local -A disp=() fps=() kept=()
    _dcov_disputes_v disp "$answers" "${_kd:+${_kd%/}/design-verdict.json}"
    local _all="" _ev_all="" _evi _fpv
    for id in ${ids[@]+"${ids[@]}"}; do
        _dcov_ev_items_v _evi "${ev[$id]:-}" "$base"
        _ev_all+="$_evi"; _all+="${render[$id]}"$'\n'
        judge_fp_v _fpv "$eng"$'\n'"$id"$'\n'"${render[$id]}"$'\n'"$_evi"$'\n'"$base_sha"$'\n'"${disp[$id]:-}"
        fps["$id"]="$_fpv"
    done
    judge_fp_v _fpv "$eng"$'\n'"$reqs"$'\n'"$_all"$'\n'"$_ev_all"$'\n'"$base_sha"$'\n'"${disp[requirements]:-}"
    fps["requirements"]="$_fpv"
    [[ -n "$kf" ]] && judge_kept_get_all_v kept "$kf" fps disp

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
    if [[ -z "$want" ]]; then
        _dcov_parse "$kept_raw" "$kept_want"
        _dcov_findings_build
        return 0
    fi

    local framed _disp_shown="" issue=""
    [[ -n "$reqs_asked" ]] && issue="$(earlier_issue_text "${artifact_dir:-${ZBUILD_ARTIFACT_DIR:-}}" "${state_dir:-}" 2>/dev/null || true)"
    for k in "${!disp[@]}"; do [[ $'\n'"$want" == *$'\n'"$k"$'\n'* ]] && _disp_shown+="${disp[$k]}"; done
    # #2458: it judges, so it composes fresh — no notes, and no rule to confirm earlier work.
    if ! framed="$(stage_prompt_compose_text --fresh "$(_dcov_prompt_own "$reqs_asked")" "$(_dcov_prompt_judge "$design_md" "${shown%$'\n'}" "$reqs_asked" "${others%$'\n'}" "$done_ev" "$base" "$issue")$(judge_disputes_block "$_disp_shown")" "$(_dcov_prompt_limits)")"; then
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
    local -A put=() putfp=() deps=()
    local _opened_all="" f q
    for f in ${files[@]+"${files[@]}"}; do _opened_all+="$f"$'\n'; done
    local new_raw="" new_want=""
    while IFS= read -r k; do
        [[ -n "$k" && -n "${got[$k]+x}" ]] || continue
        # shellcheck disable=SC2034  # passed by name to judge_kept_put_all
        { put["$k"]="${got[$k]}"; putfp["$k"]="${fps[$k]}"; deps["$k"]="$_opened_all"; }
        while IFS= read -r q; do [[ -n "$q" ]] && deps["$k"]+="$repo/$q"$'\n'; done <<< "${gotq[$k]:-}"
        new_raw+="${got[$k]}"; new_want+="$k"$'\n'
    done <<< "$want"
    [[ -n "$kf" ]] && judge_kept_put_all "$kf" put putfp deps
    if [[ -n "$need" ]]; then
        _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_DONE_WRONG=(); _DESIGN_PART_WRONG=(); _DESIGN_NEEDS_CLEANUP=()
        _DESIGN_COV_OUTCOME=unusable
        return 0
    fi
    # The verdict is every item's answer: the kept ones and this call's.
    _dcov_parse "$kept_raw$new_raw" "$kept_want$new_want"
    _dcov_findings_build
    return 0
}
