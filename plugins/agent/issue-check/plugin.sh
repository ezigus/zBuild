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
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_IC_ROOT/scripts/lib/llm-agent.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_IC_ROOT/scripts/lib/router-rc-classify.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/persona-resolve.sh
source "$_IC_ROOT/scripts/lib/persona-resolve.sh" 2>/dev/null || true
# shellcheck source=../../../core/plugin-registry/persona.sh
source "$_IC_ROOT/core/plugin-registry/persona.sh" 2>/dev/null || true

_ic_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }
# The code its findings' ids take (ICFND).
_IC_FCODE=""; zb_finding_code_v _IC_FCODE "${BASH_SOURCE[0]%/*}/manifest.yaml"

# What each judgement says, in the finding and the report.
declare -gA _IC_WORDS=([DONE]="is already true today" [CONTRADICTS]="contradicts an ADR" [GONE]="is about something that no longer exists")

# _ic_prompt <issue> <requirements> — the call's text, in the stage's three parts.
_ic_prompt() {
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
- CONTRADICTS — a live ADR decided otherwise. A requirement that would amend
  an ADR's decision is CONTRADICTS: only the person who wrote the issue may
  reverse a recorded decision.
- GONE — it is about code, a check, an event or a file that has been removed
  or replaced, so it cannot be built as written.

When any requirement is not NEEDED, end with a better set of requirements for
the issue — what it should ask for, given the system as it is — one line each:

SUGGEST: <a requirement>

Keep the requirements that are still needed in it, in their own words.

## What you judge against
ISSUE — what was asked for, in the requester's own words.
ISSUE REQUIREMENTS — its requirements, each with its id.
THE SYSTEM — the repository as it is now, which you read yourself: its code,
its tests, its ADRs (docs/adr/, each with its amendments; a later amendment
overrides an earlier statement), and its history (git log). Read the ADRs the
issue cites, and the ones about the code it names. An issue written long ago
may name files or behaviour that later changes removed: look for them, and
when they are gone, find out with git log what removed or replaced them.

A QUOTE is <file> | <one line from it>, copied as it is, with no quote marks
around it: it is checked, and one that is not in that file makes the answer
unusable. NEEDED needs no quote.

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

# _ic_parse <reply> <requirements> <repo> — each judgement line into
# _IC_PROBLEMS ("<KIND>\t<id>\t<why>\t<quote>\t<accepted if>") and each SUGGEST
# into _IC_SUGGEST. _IC_PROBLEM says what makes the answer unusable: a
# requirement with no line, one named that is not listed, a judgement with no
# quote or a quote that is not there, a problem with no better set.
_IC_PROBLEMS=() _IC_SUGGEST=() _IC_PROBLEM=""
_ic_parse() {
    local raw="$1" reqs="$2" repo="$3" l kind rest name why acc quote w
    local -A rtext=() seen=(); local -a order=() bad=() missing=()
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
        name="${rest%%|*}"; name="${name%"${name##*[![:space:]]}"}"; name="${name%:}"
        [[ -n "$name" ]] || { bad+=("a $kind: line names no requirement"); continue; }
        [[ -n "${rtext[$name]+x}" ]] || { bad+=("$kind names $name, which is not a requirement listed"); continue; }
        seen["$name"]=1
        [[ "$kind" == NEEDED ]] && continue
        judge_reply_field_v why "$rest" WHY; judge_reply_field_v acc "$rest" "ACCEPTED IF"; judge_reply_field_v quote "$rest" QUOTE
        [[ -n "$quote" ]] || { bad+=("$kind $name has no quote"); continue; }
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

# _ic_write <dir> <outcome> <reason> [data_json] [body] — the stage's result and report.
_ic_write() {
    local dir="$1" o="$2" r="$3" d="${4:-}" b="${5:-}"
    mkdir -p "$dir" 2>/dev/null || true
    [[ -n "$d" ]] || d='{"findings":[]}'
    stage_result_write "$dir/issue-check-result.json" "$o" "$r" "$d" >/dev/null 2>&1 || true
    stage_summary_write "$dir/issue-check-summary.md" "issue-check" "$o" "$r" "${b:-- $r}"
}

# _ic_finish <dir> <requirements> — the usable answer as the stage's result.
_ic_finish() {
    local dir="$1" reqs="$2" p kind id why quote acc fnd="[]" findings="" body="" ids="" sug_json="[]" n=0 text
    local -A rtext=()
    while IFS= read -r p; do
        [[ "$p" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] && rtext["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    done <<< "$reqs"
    for p in ${_IC_PROBLEMS[@]+"${_IC_PROBLEMS[@]}"}; do
        IFS=$'\t' read -r kind id why quote acc <<< "$p"
        text="$id (${rtext[$id]:-}) ${_IC_WORDS[$kind]}: $why — $quote — ACCEPTED IF: $acc"
        findings+="report"$'\t'"$text"$'\n'
        body+="- $text"$'\n'
        ids+="${ids:+, }$id ${_IC_WORDS[$kind]}"; n=$(( n + 1 ))
    done
    local total=${#rtext[@]}
    if (( n == 0 )); then
        _ic_emit "issue_check.judged" "verdict=pass" "problems=0"
        _ic_write "$dir" pass "every requirement still holds against the system as it is ($total checked)" \
            '{"findings":[]}' "- every requirement the issue states is still needed by the system as it is"
        return 0
    fi
    fnd="$(printf '%s' "$findings" | stage_findings_route_each "$dir" issue-check design-findings "$_IC_FCODE")"
    [[ "$fnd" == "["* ]] || fnd="[]"
    [[ ${#_IC_SUGGEST[@]} -gt 0 ]] && sug_json="$(printf '%s\n' "${_IC_SUGGEST[@]}" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null || printf '[]')"
    body+=$'\n'"A better set of requirements for the issue:"$'\n'
    for p in "${_IC_SUGGEST[@]}"; do body+="- $p"$'\n'; done
    local data; data="$(jq -nc --argjson f "$fnd" --argjson s "$sug_json" '{findings: $f, suggested: $s}' 2>/dev/null)" || data='{"findings":[]}'
    _ic_emit "issue_check.judged" "verdict=misconfigured" "problems=$n"
    _ic_write "$dir" misconfigured \
        "the issue needs rewriting: $n of $total requirement(s) no longer hold against the system as it is — $ids; issue-check's report suggests a better set" \
        "$data" "$body"
}

# ─── issue_check_run <stage_id> <state_file> ─────────────────────────────────
# ADR-054 §4: rc is binary; the verdict lives in the result.
issue_check_run() {
    local IFS=$' \t\n'
    local stage_id="${1:-issue-check}" state_file="${2:-}"; : "$stage_id"
    local art="${ZBUILD_ARTIFACT_DIR:-}"
    [[ -n "$art" ]] || { [[ -n "$state_file" ]] && art="$(dirname "$state_file")/artifacts"; }
    [[ -n "$art" ]] || return 1
    mkdir -p "$art" 2>/dev/null || true
    local issue="" req_f="" reqs=""
    issue="$(earlier_issue_text "${art:-}" "${state_dir:-}" 2>/dev/null || true)"
    req_f="$(earlier_requirements "${art:-}" "${state_dir:-}" 2>/dev/null || true)"
    declare -F acceptance_requirements_list >/dev/null 2>&1 && reqs="$(acceptance_requirements_list "$req_f")"
    if [[ -z "$reqs" ]]; then
        _ic_emit "issue_check.judged" "verdict=pass" "problems=0"
        _ic_write "$art" pass "no issue requirements to check"
        return 0
    fi
    local root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier="T2"
    declare -f resolve_tier >/dev/null 2>&1 \
        && tier="$(resolve_tier issue-check "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"
    local framed
    if ! framed="$(stage_prompt_compose_parts --fresh "$(_ic_prompt "$issue" "$reqs")")"; then
        _ic_write "$art" misconfigured "the prompt could not be composed — the engine's blocks are missing; the issue was not checked"
        return 1
    fi
    # ADR-060 §6: an answer that cannot be used is asked again once, with what
    # was wrong; a failed call is not.
    local raw="" rc=0 ask="$framed" _try
    for _try in 1 2; do
        : "$_try"
        raw=""; rc=0
        if declare -f route_to_model >/dev/null 2>&1; then raw="$(route_to_model "$tier" "$ask")" || rc=$?; else rc=1; fi
        [[ $rc -eq 0 ]] || break
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
    return 0
}

issue_check_cleanup() { return 0; }
