#!/usr/bin/env bash
# plugins/agent/issue-check/plugin.sh — does the issue still make sense against
# the system as it is today? (#2614, ADR-074)
#
# Kind: agent  Tier: T2. One read-only call judges each of intake's
# requirements: still needed, already true, contradicts an ADR, or about
# something that no longer exists. Any but the first ends the run
# (misconfigured: the operator rewrites the issue), saying what is wrong, with
# the line that shows it, and a better set of requirements.
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_ISSUE_CHECK_LOADED:-}" ]] && return 0
_ZBUILD_ISSUE_CHECK_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_IC_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$_IC_ROOT/scripts/lib/stage-summary.sh"
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$_IC_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_IC_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_IC_ROOT/core/router/route.sh"
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_IC_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_IC_ROOT/scripts/lib/earlier-output.sh"
# shellcheck source=../../../scripts/lib/judge.sh
source "$_IC_ROOT/scripts/lib/judge.sh"
# shellcheck source=../../../scripts/lib/stage-handoff.sh
source "$_IC_ROOT/scripts/lib/stage-handoff.sh"
# shellcheck source=../../../scripts/lib/merge-base.sh
declare -F zbuild_resolve_merge_base_v >/dev/null 2>&1 || source "$_IC_ROOT/scripts/lib/merge-base.sh"
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_IC_ROOT/scripts/lib/llm-agent.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_IC_ROOT/scripts/lib/router-rc-classify.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/persona-resolve.sh
source "$_IC_ROOT/scripts/lib/persona-resolve.sh" 2>/dev/null || true
# shellcheck source=../../../core/plugin-registry/persona.sh
source "$_IC_ROOT/core/plugin-registry/persona.sh" 2>/dev/null || true

_ic_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }
_IC_FCODE=""; zb_finding_code_v _IC_FCODE "${BASH_SOURCE[0]%/*}/manifest.yaml"
declare -gA _IC_WORDS=([DONE]="is already true today" [CONTRADICTS]="contradicts an ADR" [GONE]="is about something that no longer exists")

# _ic_prompt <issue> <requirements> <starting commit or empty> — the call's text.
_ic_prompt() {
    local start="the repository as it is now"
    [[ -n "$3" ]] && start="the repository at commit $3, where this run's branch began on the default branch. The branch's own commits after it are earlier work on this issue, not the system: read files as they are at that commit (git show $3:<path>, git log $3)"
    cat <<EOF
You are checking whether an ISSUE still makes sense against the system as it is
today, before anyone designs or builds anything for it.

## What you own
One judgement for every requirement in ISSUE REQUIREMENTS, by its id: does the
system as it is now still need it?

Write each answer as a block: its first line as shown, then each field on a
line of its own. A quote: line holds only the quote, copied as it is. A blank
line ends the answer.

NEEDED: <id>
DONE: <id>
why: <what the system already does>
accepted if: <what the issue could ask instead, or: the requirement is dropped>
quote: <file> | <the line that shows it>
CONTRADICTS: <id>
why: <what the ADR decided, and how the requirement goes against it>
accepted if: <what the issue could ask instead, or: the requirement is dropped>
quote: <file> | <the ADR's line that decides it>
GONE: <id>
why: <what no longer exists, and what took its place, if anything>
accepted if: <what the issue could ask instead, or: the requirement is dropped>
quote: <file> | <the line that shows what is there now>

- NEEDED — the system does not do it yet, and no ADR forbids it.
- DONE — the system already does what it asks.
- CONTRADICTS — a live ADR decided otherwise, and the issue does not say it
  changes that decision. A requirement that would reverse a recorded decision
  is CONTRADICTS: only the person who wrote the issue may reverse it. An issue
  that names the ADR and says it amends or supersedes that statement is
  NEEDED: its author is the one changing the decision.
- GONE — it is about code, a check, an event or a file that has been removed
  or replaced, so it cannot be built as written.

When any requirement is not NEEDED, end with a better set of requirements for
the issue — what it should ask for, given the system as it is — one line each:

SUGGEST: <a requirement>

Keep the requirements that are still needed in it, in their own words.

## What you judge against
ISSUE — what was asked for, in the requester's own words.
ISSUE REQUIREMENTS — its requirements, each with its id.
THE SYSTEM — $start. Read it yourself: its code, its tests, its ADRs
(docs/adr/, each with its amendments; a later amendment overrides an earlier
statement), and its history (git log). Read the ADRs the issue cites, and the
ones about the code it names. An issue written long ago may name files or
behaviour that later changes removed: look for them, and when they are gone,
find out with git log what removed or replaced them.

A QUOTE is <file> | <one line from it, at least three words>, copied as it
is, with no quote marks around it: it is checked, and one that is not in that
file makes the answer unusable. A CONTRADICTS quote is an ADR's line, from
docs/adr/. NEEDED needs no quote.

ISSUE:
$1

ISSUE REQUIREMENTS:
$2

## What you must not do
- Do not change any file: you read only.
- Do not judge whether the issue is a good idea: only whether it still holds
  against the system as it is.
- Do not call a requirement anything but NEEDED without a quote that shows it.
- Answer only, in the form above.
EOF
}

# A numbered, bulleted or headed first line still starts a block (#2614 review).
_ic_plain_v() {
    local -n _icp="$1"; local l out="" re='^[[:space:]]*([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+|#+[[:space:]]+)?[*_`]*(NEEDED|DONE|CONTRADICTS|GONE|SUGGEST)[*_`]*:[*_`]*(.*)$'
    while IFS= read -r l || [[ -n "$l" ]]; do
        [[ "$l" =~ $re ]] && l="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
        out+="$l"$'\n'
    done <<< "$2"
    _icp="$out"
}

# _ic_parse <reply> <requirements> <repo> — _IC_PROBLEMS ("<KIND>\t<id>\t<why>\t<quote>\t<acc>"), _IC_SUGGEST, _IC_PROBLEM.
_IC_PROBLEMS=() _IC_SUGGEST=() _IC_PROBLEM=""
_ic_parse() {
    local raw="$1" reqs="$2" repo="$3" l kind rest name why acc quote w qf qt
    local -A rtext=() seen=(); local -a order=() bad=() missing=() qw=()
    _IC_PROBLEMS=(); _IC_SUGGEST=(); _IC_PROBLEM=""
    while IFS= read -r l; do
        [[ "$l" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] || continue
        rtext["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"; order+=("${BASH_REMATCH[1]}")
    done <<< "$reqs"
    while IFS= read -r l; do
        judge_reply_line_v l "$l"
        if [[ "$l" =~ ^SUGGEST:[[:space:]]*(.+)$ ]]; then _IC_SUGGEST+=("${BASH_REMATCH[1]}"); continue; fi
        [[ "$l" =~ ^(NEEDED|DONE|CONTRADICTS|GONE):[[:space:]]*(.*)$ ]] || continue
        kind="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
        name="${rest%%|*}"; read -r name _ <<< "$name"; name="${name%:}"
        [[ -n "$name" ]] || { bad+=("a $kind: line names no requirement"); continue; }
        [[ -n "${rtext[$name]+x}" ]] || { bad+=("$kind names $name, which is not a requirement listed"); continue; }
        [[ -z "${seen[$name]+x}" ]] || { bad+=("$name has more than one line"); continue; }
        seen["$name"]=1
        [[ "$kind" == NEEDED ]] && continue
        judge_reply_field_v why "$rest" WHY; judge_reply_field_v acc "$rest" "ACCEPTED IF"; judge_reply_field_v quote "$rest" QUOTE
        [[ -n "$quote" ]] || { bad+=("$kind $name has no quote"); continue; }
        qf="${quote%%|*}"; qf="${qf//[[:space:]]/}"; qt="${quote#*|}"; read -ra qw <<< "$qt"
        [[ "$quote" == *"|"* && ${#qw[@]} -ge 3 ]] || { bad+=("$name's quote is not <file> | <a line of at least three words>"); continue; }
        [[ "$kind" != CONTRADICTS || "$qf" == docs/adr/* ]] || { bad+=("CONTRADICTS $name quotes $qf, not an ADR in docs/adr/"); continue; }
        judge_quote_check_v w "$quote" "" "$repo" || { bad+=("$name's quote $w"); continue; }
        _IC_PROBLEMS+=("$kind"$'\t'"$name"$'\t'"${why:-${_IC_WORDS[$kind]}}"$'\t'"$quote"$'\t'"${acc:-the issue is rewritten without it}")
    done <<< "$raw"
    for name in ${order[@]+"${order[@]}"}; do [[ -n "${seen[$name]+x}" ]] || missing+=("$name"); done
    [[ ${#missing[@]} -gt 0 ]] && bad=("it has no line for ${missing[*]}" ${bad[@]+"${bad[@]}"})
    [[ ${#_IC_PROBLEMS[@]} -gt 0 && ${#_IC_SUGGEST[@]} -eq 0 && ${#bad[@]} -eq 0 ]] \
        && bad+=("a requirement is not NEEDED, and there is no better set of requirements: end with SUGGEST: lines")
    [[ ${#bad[@]} -gt 0 ]] && judge_problems_join_v _IC_PROBLEM bad
    return 0
}

# _ic_write <dir> <outcome> <reason> [data_json] [body] — the result and report.
_ic_write() {
    local dir="$1" o="$2" r="$3" d="${4:-}" b="${5:-}"
    [[ -n "$d" ]] || d='{"findings":[]}'
    stage_result_write "$dir/issue-check-result.json" "$o" "$r" "$d" >/dev/null 2>&1 \
        || _ic_emit "issue_check.result.write_failed" "dir=$dir"
    stage_summary_write "$dir/issue-check-summary.md" "issue-check" "$o" "$r" "${b:-- $r}"
}

# rc 1 when the issue needs rewriting, so the runner names the stop with its reason (ADR-054 §6).
_ic_finish() {
    local dir="$1" reqs="$2" p kind id why quote acc fnd findings="" body="" ids="" sug="" n=0 text
    local -A rtext=()
    while IFS= read -r p; do
        [[ "$p" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] && rtext["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    done <<< "$reqs"
    for p in ${_IC_PROBLEMS[@]+"${_IC_PROBLEMS[@]}"}; do
        IFS=$'\t' read -r kind id why quote acc <<< "$p"
        text="$id (${rtext[$id]:-}) ${_IC_WORDS[$kind]}: $why — $quote — ACCEPTED IF: $acc"
        findings+="report"$'\t'"$text"$'\n'; body+="- $text"$'\n'
        ids+="${ids:+, }$id ${_IC_WORDS[$kind]}"; n=$(( n + 1 ))
    done
    local total=${#rtext[@]}
    if (( n == 0 )); then
        _ic_emit "issue_check.judged" "verdict=pass" "problems=0"
        _ic_write "$dir" pass "every requirement still holds against the system as it is ($total checked)" \
            '{"findings":[]}' "- every requirement the issue states is still needed by the system as it is"
        return 0
    fi
    body+=$'\n'"A better set of requirements for the issue:"$'\n'
    for p in "${_IC_SUGGEST[@]}"; do body+="- $p"$'\n'; sug+="${sug:+; }$p"; done
    # The better set is an open item too, so the run's last comment shows it.
    findings+="report"$'\t'"The issue needs rewriting — a better set of requirements for it: $sug — ACCEPTED IF: the issue is rewritten with requirements that still hold against the system as it is"$'\n'
    fnd="$(printf '%s' "$findings" | stage_findings_route_each "$dir" issue-check design-findings "$_IC_FCODE")"
    [[ "$fnd" == "["* ]] || fnd="[]"
    local data sj
    sj="$(printf '%s\n' "${_IC_SUGGEST[@]}" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null)" || sj="[]"
    data="$(jq -nc --argjson f "$fnd" --argjson s "${sj:-[]}" --argjson n "$n" '{findings: $f, suggested: $s, problems: $n}' 2>/dev/null)" || data='{"findings":[]}'
    _ic_emit "issue_check.judged" "verdict=misconfigured" "problems=$n"
    _ic_write "$dir" misconfigured \
        "the issue needs rewriting: $n of $total requirement(s) no longer hold against the system as it is — $ids; issue-check's report suggests a better set" \
        "$data" "$body"
    return 1
}

# ─── issue_check_run <stage_id> <state_file> ─────────────────────────────────
issue_check_run() {
    local IFS=$' \t\n'
    local stage_id="${1:-issue-check}" state_file="${2:-}"; : "$stage_id"
    local art="${ZBUILD_ARTIFACT_DIR:-}"
    [[ -n "$art" ]] || { [[ -n "$state_file" ]] && art="$(dirname "$state_file")/artifacts"; }
    [[ -n "$art" ]] && mkdir -p "$art" 2>/dev/null || { printf 'issue-check: no artifact directory to write to\n' >&2; return 1; }
    local issue="" req_f="" reqs=""
    issue="$(earlier_issue_text "$art" 2>/dev/null || true)"
    req_f="$(earlier_requirements "$art" 2>/dev/null || true)"
    declare -F acceptance_requirements_list >/dev/null 2>&1 && reqs="$(acceptance_requirements_list "$req_f")"
    if [[ -z "$reqs" ]]; then
        # A goal run has no issue; an issue run whose list is missing is broken.
        if [[ -n "$issue" && -z "$req_f" ]]; then
            _ic_write "$art" broken "the issue's requirements were not written by intake — the issue was not checked"
            return 1
        fi
        _ic_emit "issue_check.judged" "verdict=pass" "problems=0"
        _ic_write "$art" pass "no issue requirements to check"
        return 0
    fi
    local root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" base="" head=""
    zbuild_resolve_merge_base_v base "$root"
    head="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
    [[ "$base" == "$head" ]] && base=""
    local tier="T2"
    declare -f resolve_tier >/dev/null 2>&1 \
        && tier="$(resolve_tier issue-check "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"
    local framed
    if ! framed="$(stage_prompt_compose_parts --fresh "$(_ic_prompt "$issue" "$reqs" "$base")")"; then
        _ic_write "$art" misconfigured "the prompt could not be composed — the engine's blocks are missing; the issue was not checked"
        return 1
    fi
    # ADR-060 §6: an answer that cannot be used is asked again once, with what
    # was wrong; a failed call is not.
    local raw="" rc=0 ask="$framed" _try
    for _try in 1 2; do
        raw=""; rc=0
        if declare -f route_to_model >/dev/null 2>&1; then raw="$(route_to_model "$tier" "$ask")" || rc=$?; else rc=1; fi
        [[ $rc -eq 0 ]] || break
        _ic_plain_v raw "$raw"
        zb_reply_join_v raw "$raw"
        _ic_parse "$raw" "$reqs" "$root"
        [[ -z "$_IC_PROBLEM" ]] && break
        ask="$(stage_prompt_reask "$framed" "$_IC_PROBLEM" "$raw")"
    done
    if [[ $rc -ne 0 ]]; then
        local _v="" _reason="" _disp="broken"
        declare -f _llm_router_classify >/dev/null 2>&1 && _llm_router_classify "$rc" _v _reason 2>/dev/null
        declare -f router_reason_disposition >/dev/null 2>&1 \
            && _disp="$(router_reason_disposition "${_reason:-router_rc_nonzero}")"
        _ic_write "$art" "$_disp" "the model call failed (${_reason:-rc=$rc}) — the issue was not checked"
        return 1
    fi
    if [[ -n "$_IC_PROBLEM" ]]; then
        # ADR-054 §6a: the stage ran but its answer cannot be used — retry.
        _ic_write "$art" unusable "the answer could not be used, even when asked again: $_IC_PROBLEM — the issue was not checked"
        return 0
    fi
    _ic_finish "$art" "$reqs"
}

issue_check_cleanup() { return 0; }
