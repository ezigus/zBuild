#!/usr/bin/env bash
# plugins/agent/design/lib/coverage.sh — design's second model call: do the
# SPECs cover what the issue asks? (#2369, ADR-040 §5, ADR-070 §4; was the
# spec-coverage stage, #1683.)
#
# Its standard is the issue, which design cannot re-author, so the only way to
# pass is to cover it. The issue reaches the call the way it reaches every
# stage: under Previous work. This file never reads another stage's output.
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

# The call's three parts, composed with the engine's blocks in the one prompt
# order (ADR-067 §8).
_dcov_prompt_own() {
    cat <<'EOF2'
You are checking whether a DESIGN covers what an ISSUE asked for.

Check EVERY requirement, and find EVERY one that no SPEC fully covers — not
only the first you find. The design is revised once per round and fixes only
what you list; a gap left out of this answer costs a whole round.

Then look the other way: find EVERY SPEC or scope entry that commits to
something that the issue does not ask for, or that contradicts it.

Then, for every SPEC marked [done], read the code its evidence names, as it was
before this change: find each one whose code does not do what the SPEC says.

Answer with one line for every requirement and one line for every SPEC, each
starting with its id, in exactly this form:

<requirement id>: covered
<requirement id>: uncovered | WHY: <what no SPEC covers> | QUOTE: "<the requirement's own words that no SPEC covers>"
<SPEC id>: ok
<SPEC id>: outside | WHY: <what the issue does not ask for, or how it contradicts it> | QUOTE: "<the SPEC's own words that do>"
<SPEC id>: done_wrong | WHY: <what the code does instead> | QUOTE: <file>:"<the exact text of the code that shows it>"

done_wrong is only for a SPEC marked [done]. A scope entry the issue does not
ask for, or that contradicts it, has a line of its own:

SCOPE: <the scope entry, as listed> | WHY: <why>

Copy each QUOTE exactly from what it names. It is checked: a quote that is not
there makes the answer unusable.
EOF2
}
# _dcov_done_evidence <design_md> <base_dir> — each [done] SPEC's evidence, by
# file and text: the check opens the code itself, in the copy of the code from
# before the change (#2464, ADR-069 §2), never a window of it.
_dcov_done_evidence() {
    local design="$1" base="$2" sid item path
    # shellcheck disable=SC2034  # the split's text and line, not needed here
    local _t _n
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        [[ "$(acceptance_spec_status "$design" "$sid" 2>/dev/null)" == "done" ]] || continue
        while IFS= read -r item; do
            [[ -n "$item" ]] || continue
            acceptance_evidence_split "$item" path _t _n
            printf -- '- %s: %s — open %s\n' "$sid" "$item" "${base:+$base/}$path"
        done < <(acceptance_spec_evidence "$design" "$sid" 2>/dev/null)
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
}

# _dcov_ev_items_v <var> <done_evidence> <base> — the evidence as its
# fingerprint takes it: without the copy's path, which differs every run; with
# no copy, unchanged (review on #2465: an empty base stripped every `/`).
_dcov_ev_items_v() {
    local -n _dei="$1"
    if [[ -n "$3" ]]; then _dei="${2//"$3/"/}"; else _dei="$2"; fi
}

# _dcov_prompt_judge <acceptance> <requirements> [scope] [done_evidence] [base]
_dcov_prompt_judge() {
    cat <<EOF2
Two things, shown at the end of this part, and the issue:

REQUIREMENTS — the issue's requirements, each with its id.
ACCEPTANCE — the SPEC sentences the design commits to.
The issue itself, in the requester's own words, is under Previous work.

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
$2

ACCEPTANCE:
$1

SCOPE — the files the design plans to change:
${3:-(none named)}

THE [done] SPECS' EVIDENCE — a file and a piece of its text. Open the file
and read the code around that text, as much as you need:
${4:-(no SPEC is marked [done])}
${5:+
The code from before this change is a copy at $5 — read the code of each
[done] SPEC there. The repository as it is now is the current directory.}
EOF2
}
_dcov_prompt_limits() {
    cat <<'EOF2'
- Do not suggest SPEC text.
- Do not rewrite the design.
- Answer only, in the form above.
EOF2
}

# _dcov_parse <reply> <requirements> <acceptance> <scope> <repo> <base> — the
# reply's line for each item into _DESIGN_UNCOVERED, _DESIGN_OUTSIDE and
# _DESIGN_DONE_WRONG. _DCOV_PROBLEM says what makes the answer unusable (an item
# with no line, a word that is not its kind's, a quote that is not there), and
# _DCOV_QUOTED lists the files its quotes name.
_dcov_parse() {
    local raw="$1" reqs="$2" acc="$3" scope="$4" repo="$5" base="$6"
    _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_DONE_WRONG=(); _DCOV_PROBLEM=""; _DCOV_QUOTED=()
    local -A req_text=() spec_text=() spec_st=() seen=()
    local -a order=() bad=()
    local l id rest word why quote w qp
    while IFS= read -r l; do
        [[ "$l" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] || continue
        req_text["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"; order+=("${BASH_REMATCH[1]}")
    done <<< "$reqs"
    while IFS= read -r l; do
        [[ "$l" == "TESTFILES:" ]] && break
        [[ "$l" =~ $_ACCEPTANCE_SPEC_RE ]] || continue
        id="${BASH_REMATCH[1]}"
        _acceptance_spec_line "$acc" "$id" || continue
        spec_text["$id"]="$_ACC_SPEC_TEXT"; spec_st["$id"]="$_ACC_SPEC_STATUS"; order+=("$id")
    done <<< "$acc"
    while IFS= read -r l; do
        l="${l#"${l%%[![:space:]>*\`_-]*}"}"
        if [[ "$l" =~ ^SCOPE:[[:space:]]*(.*)$ ]]; then
            rest="${BASH_REMATCH[1]}"; w="${rest%%|*}"; w="${w%"${w##*[![:space:]]}"}"
            why=""; [[ "$rest" == *"| WHY:"* ]] && { why="${rest#*| WHY:}"; why="${why#"${why%%[![:space:]]*}"}"; }
            if [[ $'\n'"$scope"$'\n' == *$'\n'"$w"$'\n'* ]]; then
                _DESIGN_OUTSIDE+=("$w: ${why:-the issue does not ask for it}")
            else
                bad+=("SCOPE names $w, which is not in the design's scope")
            fi
            continue
        fi
        [[ "$l" =~ ^([A-Za-z0-9]+-[0-9]+)[*\`_]*:[[:space:]]*([a-z_]+)(.*)$ ]] || continue
        id="${BASH_REMATCH[1]}"; word="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
        [[ -n "${req_text[$id]+x}" || -n "${spec_text[$id]+x}" ]] || continue
        seen["$id"]=1
        why=""; quote=""
        if [[ "$rest" == *"| WHY:"* ]]; then why="${rest#*| WHY:}"; why="${why%%| QUOTE:*}"; fi
        why="${why#"${why%%[![:space:]]*}"}"; why="${why%"${why##*[![:space:]]}"}"
        [[ "$rest" == *"| QUOTE:"* ]] && quote="${rest#*| QUOTE:}"
        if [[ -n "${req_text[$id]+x}" ]]; then
            case "$word" in
                covered) continue ;;
                uncovered)
                    if [[ -z "$quote" ]]; then bad+=("$id has no QUOTE"); continue; fi
                    judge_quote_check_v w "$quote" "${req_text[$id]}" "$repo" "$base" || { bad+=("$id's quote $w"); continue; }
                    judge_quote_path_v qp "$quote" "$repo" "$base"; [[ -n "$qp" ]] && _DCOV_QUOTED+=("$qp")
                    _DESIGN_UNCOVERED+=("$id: ${why:-no SPEC covers it} — ${quote#"${quote%%[![:space:]]*}"}") ;;
                *) bad+=("$id is a requirement: it is covered or uncovered, not $word") ;;
            esac
            continue
        fi
        case "$word" in
            ok) ;;
            outside|done_wrong)
                if [[ "$word" == done_wrong && "${spec_st[$id]}" != "done" ]]; then
                    bad+=("$id is not marked [done]: done_wrong is only for a SPEC that is"); continue
                fi
                if [[ -z "$quote" ]]; then bad+=("$id has no QUOTE"); continue; fi
                judge_quote_check_v w "$quote" "${spec_text[$id]}" "$repo" "$base" || { bad+=("$id's quote $w"); continue; }
                judge_quote_path_v qp "$quote" "$repo" "$base"; [[ -n "$qp" ]] && _DCOV_QUOTED+=("$qp")
                quote="${quote#"${quote%%[![:space:]]*}"}"
                if [[ "$word" == outside ]]; then _DESIGN_OUTSIDE+=("$id: ${why:-the issue does not ask for it} — $quote")
                else _DESIGN_DONE_WRONG+=("$id: ${why:-the code does not do it} — $quote"); fi ;;
            *) bad+=("$id is a SPEC: it is ok, outside or done_wrong, not $word") ;;
        esac
    done <<< "$raw"
    local -a missing=()
    for id in ${order[@]+"${order[@]}"}; do [[ -n "${seen[$id]+x}" ]] || missing+=("$id"); done
    [[ ${#missing[@]} -gt 0 ]] && bad=("it has no line for ${missing[*]}" ${bad[@]+"${bad[@]}"})
    if [[ ${#bad[@]} -gt 0 ]]; then
        local IFS=';'; _DCOV_PROBLEM="${bad[*]}"; _DCOV_PROBLEM="${_DCOV_PROBLEM//;/; }"
    fi
    return 0
}

# _design_coverage <design_md> <requirements_text> [tier] [answers]
# Sets _DESIGN_UNCOVERED, _DESIGN_OUTSIDE, _DESIGN_DONE_WRONG (one entry each)
# and _DESIGN_COV_OUTCOME: empty when the call judged the design, otherwise the
# outcome word for how the call failed (rate_limited, unavailable, unusable,
# misconfigured, broken). [answers]: design's own answers disputing findings of
# this check, one per line (ADR-072 §5). rc 0 always.
_design_coverage() {
    local design_md="$1" reqs="$2" tier="${3:-T2}" answers="${4:-}"
    _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_DONE_WRONG=(); _DESIGN_COV_OUTCOME=""
    local acc; acc="$(extract_acceptance_block "$design_md" 2>/dev/null || true)"
    [[ -n "$acc" ]] || return 0

    local repo="${ZBUILD_REPO_ROOT:-$PWD}" base="" base_sha="" _scope _done_ev _ev_items
    judge_base_dir_v base "$repo" || base=""
    [[ -n "$base" && -f "$base.sha" ]] && base_sha="$(<"$base.sha")"
    _scope="$(acceptance_list_scope "$design_md" 2>/dev/null || true)"
    _done_ev="$(_dcov_done_evidence "$design_md" "$base")"
    _dcov_ev_items_v _ev_items "$_done_ev" "$base"

    # ADR-072 §4: the answer is kept while what it judged is unchanged.
    local kf="" fp="" eng kept=""
    local _kd="${artifact_dir:-${ZBUILD_ARTIFACT_DIR:-}}"
    [[ -n "$_kd" ]] && kf="${_kd%/}/design-judged.json"
    judge_engine_v eng
    judge_fp_v fp "$eng"$'\n'"$acc"$'\n'"$reqs"$'\n'"$_scope"$'\n'"$_ev_items"$'\n'"$base_sha"$'\n'"$answers"
    [[ -n "$kf" ]] && judge_kept_get_v kept "$kf" coverage "$fp"
    if [[ -n "$kept" ]]; then
        _dcov_parse "$kept" "$reqs" "$acc" "$_scope" "$repo" "$base"
        if [[ -z "$_DCOV_PROBLEM" ]]; then
            declare -F emit_event >/dev/null 2>&1 && emit_event "judge.kept" "check=design-coverage" 2>/dev/null
            return 0
        fi
    fi

    local framed
    # #2458: it judges, so it composes fresh — no notes, and no rule to confirm earlier work.
    if ! framed="$(stage_prompt_compose_text --fresh "$(_dcov_prompt_own)" "$(_dcov_prompt_judge "$acc" "$reqs" "$_scope" "$_done_ev" "$base")$(judge_disputes_block "$answers")" "$(_dcov_prompt_limits)")"; then
        _DESIGN_COV_OUTCOME=misconfigured
        return 0
    fi
    local raw="" rc=0 rc_file ask="$framed" _try opened=""
    # ADR-072 §1: this call reads and searches files, and nothing else.
    local -x ZBUILD_ROUTE_TOOLS=read ZBUILD_ROUTER_OPENED_FILE=""
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
        _dcov_parse "$raw" "$reqs" "$acc" "$_scope" "$repo" "$base"
        [[ -z "$_DCOV_PROBLEM" ]] && break
        ask="$(stage_prompt_reask "$framed" "$_DCOV_PROBLEM" "$raw")"
    done
    local -a files=()
    judge_opened_v files "$opened"; rm -f "$opened" 2>/dev/null
    if [[ -n "$_DCOV_PROBLEM" ]]; then
        _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_DONE_WRONG=()
        _DESIGN_COV_OUTCOME=unusable
        return 0
    fi
    local q
    for q in ${_DCOV_QUOTED[@]+"${_DCOV_QUOTED[@]}"}; do files+=("$repo/$q"); done
    [[ -n "$kf" ]] && judge_kept_put_one "$kf" coverage "$fp" "$raw" ${files[@]+"${files[@]}"}
    return 0
}

# _design_coverage_findings — the check's answer as design's findings, one per line.
_design_coverage_findings() {
    local x
    for x in ${_DESIGN_UNCOVERED[@]+"${_DESIGN_UNCOVERED[@]}"}; do printf 'The issue asks for this and no SPEC covers it: %s\n' "$x"; done
    for x in ${_DESIGN_OUTSIDE[@]+"${_DESIGN_OUTSIDE[@]}"}; do printf 'the issue does not ask for this, or the design gets it wrong: %s\n' "$x"; done
    for x in ${_DESIGN_DONE_WRONG[@]+"${_DESIGN_DONE_WRONG[@]}"}; do printf 'marked [done], but the code its evidence points at does not do it: %s\n' "$x"; done
    return 0
}
