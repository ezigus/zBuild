#!/usr/bin/env bash
# plugins/agent/issue-acceptance/plugin.sh — does the finished change do what
# the ISSUE asked? (#1849, ADR-040 §5, ADR-054, ADR-055)
#
# Kind: agent  Tier: T2  convergence: gate (its standard is the issue, which the
# judged parties cannot re-author).
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_ISSUE_ACCEPTANCE_LOADED:-}" ]] && return 0
_ZBUILD_ISSUE_ACCEPTANCE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-summary.sh"
# #2366: the one writer of a stage's result (contract 3).
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-result.sh"
_IA_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_IA_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_IA_ROOT/core/router/route.sh"
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_IA_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true
# #2364: earlier work is found by what it contains, never by which stage made it.
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_IA_ROOT/scripts/lib/earlier-output.sh"
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_IA_ROOT/scripts/lib/test-output-sanitize.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_IA_ROOT/scripts/lib/llm-agent.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/judge.sh
source "$_IA_ROOT/scripts/lib/judge.sh"
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_IA_ROOT/scripts/lib/router-rc-classify.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/persona-resolve.sh
source "$_IA_ROOT/scripts/lib/persona-resolve.sh" 2>/dev/null || true
# shellcheck source=../../../core/plugin-registry/persona.sh
source "$_IA_ROOT/core/plugin-registry/persona.sh" 2>/dev/null || true

_ia_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# intake writes the literal "GitHub issue #<N>" when the fetch fails (#1804);
# judging a change against that must not read as satisfied (spec-coverage's rule).
_ia_issue_is_placeholder() {
    local t="${1-}"
    t="${t//[[:space:]]/}"
    [[ -z "$t" ]] && return 0
    [[ "$t" =~ ^GitHubissue#[0-9]+$ ]]
}

_ia_prompt() {
    cat <<EOF
You are checking whether a finished CHANGE does what an ISSUE asked for.

## What you own
One verdict on the whole issue: does the DIFF meet every requirement the issue
states, in full — including what its tests must catch?

Answer with one line for every requirement in ISSUE REQUIREMENTS, by its id:

MET: <id>
UNMET: [fix-code] <id> | WHY: <what the change does not do> | QUOTE: <quote>
UNMET: [fix-design] <id> | WHY: <what the requirements miss or get wrong> | QUOTE: <quote>
UNSURE: <id> | WHY: <what you cannot tell, and what would settle it> | QUOTE: <quote>

When none are listed under ISSUE REQUIREMENTS, write one of these lines for
each requirement the ISSUE states, naming it in a few words where the id would
go.

Start each UNMET: line with what would fix it:
- [fix-code] — the change does not do it yet: the code or its tests must change.
- [fix-design] — the REQUIREMENTS miss it or get it wrong, or the issue itself is
  wrong: the design must change.

A QUOTE is either the requirement's own words — "<the exact words>", from ISSUE
REQUIREMENTS or the ISSUE — or the code that shows it — <file>:"<its exact
text>". Copy it exactly: it is checked, and one that is not there makes the
answer unusable.

## What you judge against
Five things, shown at the end of this part:

ISSUE — what was asked for, in the requester's own words. This is the standard.
ISSUE REQUIREMENTS — the issue's requirements, each with its id.
REQUIREMENTS — what the design committed to, each with what was done about it.
DIFF — the change as built.
TEST VERDICT — whether the test suite passed.

Judge every requirement in ISSUE REQUIREMENTS: decide whether the DIFF meets it
IN FULL, and name an unmet one by its id and words (<its id>: <its words>). Read the
ISSUE for what a requirement means. When none are listed under ISSUE REQUIREMENTS,
judge every requirement the ISSUE states.
Judge against the issue's own words, not the SPECs: a SPEC that narrowed a
requirement does not make the narrowed version enough. A requirement met only
partly — a subset of the cases, a weaker condition, some of the files — is unmet.

An issue contains more than requirements — context, rationale, links, history.
Those are not requirements. Judge every requirement the issue states, including
what its tests must catch (for example "putting the old code back turns the test
red"). The pipeline does not check those for you. For each one, ask: if the
change were broken, would its tests catch it? If they would not, it is unmet.

Some REQUIREMENTS were not run against the old code: those that need work but
no code, and those design says are already done. Nothing but you checks them.
For one already done, open the file its evidence names and check the claim
against the code. If you cannot
tell whether such a requirement is met, say so rather than guess: the run then
reports it as open, with what would settle it.

ISSUE:
$1

ISSUE REQUIREMENTS:
${5:-<none listed>}

REQUIREMENTS:
$2

DIFF:
$3

TEST VERDICT: $4
${6:-}
## What you must not do
- Do not suggest code.
- Do not guess whether a requirement is met: say you are unsure instead.
- Answer only, in the form above.
EOF
}

# _ia_write <dir> <outcome> <reason> [unmet_json] [unsure_json] [judgement]
# #2366 (ADR-054 §6, contract 3): one outcome — pass when every requirement is
# met, fail when one is not, is unsure, or the issue cannot be read; otherwise
# how the stage failed to finish. `judgement` keeps "unreadable" as detail.
_ia_write() {
    local dir="$1" o="$2" r="$3" u="${4:-[]}" s="${5:-[]}" j="${6:-}"
    mkdir -p "$dir" 2>/dev/null || true
    # #2271 (ADR-068): each unmet acceptance item is a numbered finding. #2304
    # (ADR-069 §7): so is each requirement the judge is not sure of — nothing
    # else checks it. #2330: each says what would settle it, never who must.
    # #2452 (ADR-071 §1): an unmet line's [fix-code] / [fix-design] mark is the
    # finding's topic — it reaches the stages that can fix it — never its text.
    local _fnd; _fnd="$(jq -r --argjson s "$s" '(.[]? | tostring
            | (if test("^\\[fix-code\\]") then "code-findings\t" elif test("^\\[fix-design\\]") then "requirement-findings\t" else "" end)
              + "The issue requires this and the change does not meet it: " + sub("^\\[fix-(code|design)\\][[:space:]]*"; "")
              + ". What would settle it: a change that meets this requirement in full."),
        ($s[] | "Not sure this requirement is met: " + tostring
            + ". What would settle it: a test that fails when this requirement is not met, or the code or document that shows it is met.")' \
        <<< "$u" 2>/dev/null | stage_findings_json)"
    u="$(jq -c 'map(tostring | sub("^\\[fix-(code|design)\\][[:space:]]*"; ""))' <<< "$u" 2>/dev/null || printf '%s' "$u")"
    local _data
    _data="$(jq -nc --argjson u "$u" --argjson s "$s" --argjson fnd "${_fnd:-[]}" --arg j "$j" \
        '{unmet: $u, unsure: $s, findings: $fnd} + (if $j == "" then {} else {judgement: $j} end)' 2>/dev/null)"
    [[ -n "$_data" ]] || _data='{}'
    if ! stage_result_write "$dir/issue-acceptance-result.json" "$o" "$r" "$_data"; then
        _ia_emit "issue_acceptance.result.write_failed" "dir=$dir"
    fi
    local _body="- every requirement the issue states is met by the change"
    # #2452: the unmet requirements are findings, each sent to the stages that
    # can fix it; listed here they would reach every stage that reads this.
    [[ "$u" != "[]" || "$s" != "[]" ]] && _body="$(jq -r --argjson s "$s" '(if length > 0 then "- \(length) requirement(s) not met — each is a finding, sent to the stages that can fix it" else empty end), ($s[] | "- NOT SURE: " + . + " — what would settle it: a test that fails when it is not met, or the code or document that shows it is met")' <<< "$u" 2>/dev/null || printf -- '- see result')"
    if [[ "$j" == unreadable ]] || [[ "$o" != pass && "$o" != fail ]]; then
        _body="- the change was not judged against the issue"
    fi
    stage_summary_write "$dir/issue-acceptance-summary.md" "issue-acceptance" "$o" "$r" "$_body"
}

# ─── issue_acceptance_run <stage_id> <state_file> ────────────────────────────
# ADR-054 §4: rc is binary; the verdict lives in the result.
issue_acceptance_run() {
    local stage_id="${1:-issue-acceptance}"; : "$stage_id"
    local state_file="${2:-}"
    local art="${ZBUILD_ARTIFACT_DIR:-}"
    [[ -n "$art" ]] || { [[ -n "$state_file" ]] && art="$(dirname "$state_file")/artifacts"; }
    [[ -n "$art" ]] || return 1
    mkdir -p "$art" 2>/dev/null || true

    # #2364: each piece of earlier work found by what it contains.
    local design_f diff_f tests_f issue="" acc="" diff="" test_verdict=""
    issue="$(earlier_issue_text "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    design_f="$(earlier_acceptance_contract "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    diff_f="$(earlier_change_patch "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    tests_f="$(earlier_test_run "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"

    if _ia_issue_is_placeholder "$issue"; then
        _ia_emit "issue_acceptance.unreadable_issue" "stage=$stage_id"
        _ia_write "$art" fail \
            "the issue text is absent or a placeholder — the change was not judged against anything" \
            "[]" "[]" unreadable
        return 0
    fi

    # #2304 (ADR-069 §7): the requirements in plain words, by status — never the
    # raw block's tags — with a done one's evidence, cleaned for the model.
    local _root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    [[ -n "$design_f" && -f "$design_f" ]] && declare -f acceptance_requirements_for_judge >/dev/null 2>&1 \
        && acc="$(acceptance_requirements_for_judge "$design_f" "$_root" 2>/dev/null || true)"
    declare -F _zbuild_sanitize_for_llm >/dev/null 2>&1 && [[ -n "$acc" ]] \
        && acc="$(printf '%s\n' "$acc" | _zbuild_sanitize_for_llm)"
    [[ -n "$diff_f" && -f "$diff_f" ]] && diff="$(cat "$diff_f" 2>/dev/null || true)"
    [[ -n "$tests_f" && -f "$tests_f" ]] && test_verdict="$(jq -r '.outcome // empty' "$tests_f" 2>/dev/null || true)"

    local tier="T2"
    declare -f resolve_tier >/dev/null 2>&1 \
        && tier="$(resolve_tier issue-acceptance "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"

    local _task _framed
    # #2306 (ADR-070 §4): the issue's requirements as intake numbered them.
    local _reqs=""; declare -F acceptance_requirements_list >/dev/null 2>&1 \
        && _reqs="$(acceptance_requirements_list "$(earlier_requirements "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)")"
    # #2464 (ADR-072 §4 §5): the answer is kept while what it judged is
    # unchanged; a stage's "nothing to do" answer to one of its findings is
    # judged again, shown to the judge.
    local _ans=""; judge_answers_to_v _ans "$art" issue-acceptance
    local kf="${art%/}/issue-acceptance-judged.json" eng fp kept="" _root_q="$_root"
    judge_engine_v eng
    judge_fp_v fp "$eng"$'\n'"$issue"$'\n'"$_reqs"$'\n'"$acc"$'\n'"$diff"$'\n'"$test_verdict"$'\n'"$_ans"
    judge_kept_get_v kept "$kf" issue "$fp"
    if [[ -n "$kept" ]]; then
        _ia_parse "$kept" "$_reqs" "$issue" "$_root_q"
        if [[ -z "$_IA_PROBLEM" ]]; then
            _ia_emit "judge.kept" "check=issue-acceptance"
            _ia_finish "$art"
            return 0
        fi
    fi

    _task="$(_ia_prompt "$issue" "${acc:-<none>}" "${diff:-<no diff>}" "${test_verdict:-unknown}" "$_reqs" "$(judge_disputes_block "$_ans")")"
    _framed="$_task"
    # ADR-067 §8: the stage's three parts and the engine's blocks, in the one
    # prompt order. A prompt that cannot be composed is not sent.
    local _composed
    # #2458: it judges, so it composes fresh — no notes, and no rule to confirm earlier work.
    if ! _composed="$(stage_prompt_compose_parts --fresh "$_framed")"; then
        _ia_write "$art" misconfigured \
            "the prompt could not be composed — the engine's blocks are missing; the change was not judged"
        return 1
    fi
    _framed="$_composed"
    local _raw="" rc=0 _ask="$_framed" _try _opened
    _opened="$(mktemp 2>/dev/null)" || _opened=""
    local -x ZBUILD_ROUTER_OPENED_FILE="$_opened"
    # ADR-060 §6: an answer that cannot be used is asked again once, at once,
    # with what was wrong and the answer. A failed call is not asked again.
    for _try in 1 2; do
        _raw=""
        # No 2>/dev/null: the stage-io banner writes to fd 2 (ADR-015 §v4).
        if declare -f route_to_model >/dev/null 2>&1; then
            _raw="$(route_to_model "$tier" "$_ask")" || rc=$?
        else
            rc=1
        fi
        [[ $rc -eq 0 ]] || break
        # No `| head` (#1886): capture in full, trim in bash. #2460: a wrapped
        # line is read whole.
        zb_reply_join_v _raw "$_raw"
        _ia_parse "$_raw" "$_reqs" "$issue" "$_root_q"
        [[ -z "$_IA_PROBLEM" ]] && break
        _ask="$(stage_prompt_reask "$_framed" "$_IA_PROBLEM" "$_raw")"
    done
    local -a _deps=()
    judge_opened_v _deps "$_opened"; rm -f "$_opened" 2>/dev/null
    if [[ $rc -ne 0 ]]; then
        local _v="" _reason="" _disp="broken"
        declare -f _llm_router_classify >/dev/null 2>&1 && _llm_router_classify "$rc" _v _reason 2>/dev/null
        declare -f router_reason_disposition >/dev/null 2>&1 \
            && _disp="$(router_reason_disposition "${_reason:-router_rc_nonzero}")"
        _ia_write "$art" "$_disp" \
            "the model call failed (${_reason:-rc=$rc}) — the change was not judged"
        return 1
    fi
    if [[ -n "$_IA_PROBLEM" ]]; then
        # ADR-054 §6a: the stage ran but its output cannot be used — retry.
        _ia_write "$art" unusable \
            "the answer could not be used, even when asked again: $_IA_PROBLEM — the change was not judged"
        return 0
    fi
    local _q
    for _q in ${_IA_QUOTED[@]+"${_IA_QUOTED[@]}"}; do _deps+=("$_root_q/$_q"); done
    judge_kept_put_one "$kf" issue "$fp" "$_raw" ${_deps[@]+"${_deps[@]}"}
    _ia_finish "$art"
    return 0
}

# _ia_finish <dir> — the judged answer as the stage's result: fail when any
# requirement is unmet or unsure (#2304, ADR-069 §7: one the judge is not sure
# of is never a pass, and is reported as open), pass otherwise.
_ia_finish() {
    local _v=pass _u_json _s_json
    _u_json="$(_ia_json_list "${_IA_UNMET[@]+"${_IA_UNMET[@]}"}")"
    _s_json="$(_ia_json_list "${_IA_UNSURE[@]+"${_IA_UNSURE[@]}"}")"
    [[ ${#_IA_UNMET[@]} -gt 0 ]] && _v=fail
    if [[ ${#_IA_UNSURE[@]} -gt 0 ]]; then
        _v=fail
        _ia_emit "issue_acceptance.unsure" "count=${#_IA_UNSURE[@]}"
    fi
    _ia_emit "issue_acceptance.judged" "verdict=$_v"
    local _r="judged the change against the issue: every requirement is met"
    [[ "$_v" == fail ]] && _r="judged the change against the issue: $(( ${#_IA_UNMET[@]} + ${#_IA_UNSURE[@]} )) requirement(s) not met or not sure"
    _ia_write "$1" "$_v" "$_r" "$_u_json" "$_s_json"
}

# _ia_json_list <item>... — the items as a JSON array of strings.
_ia_json_list() {
    [[ $# -gt 0 ]] || { printf '[]'; return 0; }
    printf '%s\n' "$@" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null || printf '[]'
}

# _ia_parse <reply> <requirements> <issue> <repo> — each MET:/UNMET:/UNSURE:
# line (ADR-072 §3) into _IA_UNMET ("[fix-code] <id>: <why> — <quote>"; an
# unmarked line keeps no mark, #2452) and
# _IA_UNSURE. _IA_PROBLEM says what makes the answer unusable: a requirement
# with no line, a line naming none of them, a complaint with no quote or a
# quote that is not there. A line that names nothing ("none") is no line.
_ia_parse() {
    local raw="$1" reqs="$2" issue="$3" repo="$4"
    _IA_UNMET=(); _IA_UNSURE=(); _IA_PROBLEM=""; _IA_QUOTED=()
    local -A rtext=() seen=()
    local -a order=() bad=()
    local l kind rest fix name why quote w qp own
    while IFS= read -r l; do
        [[ "$l" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] || continue
        rtext["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"; order+=("${BASH_REMATCH[1]}")
    done <<< "$reqs"
    while IFS= read -r l; do
        l="${l#"${l%%[![:space:]>*\`_-]*}"}"
        [[ "$l" =~ ^(MET|UNMET|UNSURE):[[:space:]]*(.*)$ ]] || continue
        kind="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; fix=""
        [[ "$kind" == UNMET && "$rest" =~ ^(\[fix-(code|design)\])[[:space:]]*(.*)$ ]] && { fix="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[3]}"; }
        name="${rest%%|*}"; name="${name%"${name##*[![:space:]]}"}"; name="${name%:}"
        shopt -q nocasematch; local _ncm=$?
        shopt -s nocasematch
        [[ -z "$name" || "$name" =~ ^\(?(none|omitted|n/a|nothing)\)?\.?$ ]] && { (( _ncm )) && shopt -u nocasematch; continue; }
        (( _ncm )) && shopt -u nocasematch
        if [[ ${#order[@]} -gt 0 && -z "${rtext[$name]+x}" ]]; then
            bad+=("$kind names $name, which is not a requirement listed"); continue
        fi
        seen["$name"]=1
        [[ "$kind" == MET ]] && continue
        why=""; quote=""
        if [[ "$rest" == *"| WHY:"* ]]; then why="${rest#*| WHY:}"; why="${why%%| QUOTE:*}"; fi
        why="${why#"${why%%[![:space:]]*}"}"; why="${why%"${why##*[![:space:]]}"}"
        [[ "$rest" == *"| QUOTE:"* ]] && { quote="${rest#*| QUOTE:}"; quote="${quote#"${quote%%[![:space:]]*}"}"; }
        if [[ -z "$quote" ]]; then bad+=("$name has no QUOTE"); continue; fi
        own="${rtext[$name]:-}"$'\n'"$issue"
        judge_quote_check_v w "$quote" "$own" "$repo" || { bad+=("$name's quote $w"); continue; }
        judge_quote_path_v qp "$quote" "$repo"; [[ -n "$qp" ]] && _IA_QUOTED+=("$qp")
        if [[ "$kind" == UNMET ]]; then _IA_UNMET+=("${fix:+$fix }$name: ${why:-it is not met} — $quote")
        else _IA_UNSURE+=("$name: ${why:-it cannot be told} — $quote"); fi
    done <<< "$raw"
    local -a missing=()
    for name in ${order[@]+"${order[@]}"}; do [[ -n "${seen[$name]+x}" ]] || missing+=("$name"); done
    [[ ${#missing[@]} -gt 0 ]] && bad=("it has no line for ${missing[*]}" ${bad[@]+"${bad[@]}"})
    # With no list, an answer must still judge something: no line is no answer.
    [[ ${#order[@]} -eq 0 && ${#seen[@]} -eq 0 && ${#bad[@]} -eq 0 ]] \
        && bad=("it has no MET:, UNMET: or UNSURE: line")
    if [[ ${#bad[@]} -gt 0 ]]; then
        local IFS=';'; _IA_PROBLEM="${bad[*]}"; _IA_PROBLEM="${_IA_PROBLEM//;/; }"
    fi
    return 0
}

issue_acceptance_cleanup() { return 0; }
