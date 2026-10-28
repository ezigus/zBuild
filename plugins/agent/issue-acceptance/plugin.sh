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

Answer in this form:

VERDICT: pass | fail | unsure
REASON: <one sentence>
UNMET: <one issue requirement the diff does not meet, and why>
UNSURE: <one requirement you cannot tell is met, named as listed, and why>

Write one UNMET: line for each requirement the diff does not meet (none on a
pass), and one UNSURE: line for each you cannot tell is met (none when sure).

## What you judge against
Five things, shown at the end of this part:

ISSUE — what was asked for, in the requester's own words. This is the standard.
ISSUE REQUIREMENTS — the issue's requirements, numbered R-1, R-2, … by the pipeline.
REQUIREMENTS — what the design committed to, each with what was done about it.
DIFF — the change as built.
TEST VERDICT — whether the test suite passed.

Judge every requirement in ISSUE REQUIREMENTS: decide whether the DIFF meets it
IN FULL, and name an unmet one by its id and words (R-2: <its words>). Read the
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
For one already done, check the claim against the evidence shown. If you cannot
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
    local _fnd; _fnd="$(jq -r --argjson s "$s" '(.[]? | "The issue requires this and the change does not meet it: " + tostring
            + ". What would settle it: a change that meets this requirement in full."),
        ($s[] | "Not sure this requirement is met: " + tostring
            + ". What would settle it: a test that fails when this requirement is not met, or the code or document that shows it is met.")' \
        <<< "$u" 2>/dev/null | stage_findings_json)"
    local _data
    _data="$(jq -nc --argjson u "$u" --argjson s "$s" --argjson fnd "${_fnd:-[]}" --arg j "$j" \
        '{unmet: $u, unsure: $s, findings: $fnd} + (if $j == "" then {} else {judgement: $j} end)' 2>/dev/null)"
    [[ -n "$_data" ]] || _data='{}'
    if ! stage_result_write "$dir/issue-acceptance-result.json" "$o" "$r" "$_data"; then
        _ia_emit "issue_acceptance.result.write_failed" "dir=$dir"
    fi
    local _body="- every requirement the issue states is met by the change"
    [[ "$u" != "[]" || "$s" != "[]" ]] && _body="$(jq -r --argjson s "$s" '(.[] | "- NOT MET: " + .), ($s[] | "- NOT SURE: " + . + " — what would settle it: a test that fails when it is not met, or the code or document that shows it is met")' <<< "$u" 2>/dev/null || printf -- '- see result')"
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
    _task="$(_ia_prompt "$issue" "${acc:-<none>}" "${diff:-<no diff>}" "${test_verdict:-unknown}" "$_reqs")"
    _framed="$_task"
    # ADR-067 §8: the stage's three parts and the engine's blocks, in the one
    # prompt order. A prompt that cannot be composed is not sent.
    local _composed
    if ! _composed="$(stage_prompt_compose_parts "$_framed")"; then
        _ia_write "$art" misconfigured \
            "the prompt could not be composed — the engine's blocks are missing; the change was not judged"
        return 1
    fi
    _framed="$_composed"
    local _raw="" rc=0
    # No 2>/dev/null: the stage-io banner writes to fd 2 (ADR-015 §v4).
    if declare -f route_to_model >/dev/null 2>&1; then
        _raw="$(route_to_model "$tier" "$_framed")" || rc=$?
    else
        rc=1
    fi
    if [[ $rc -ne 0 ]]; then
        local _v="" _reason="" _disp="broken"
        declare -f _llm_router_classify >/dev/null 2>&1 && _llm_router_classify "$rc" _v _reason 2>/dev/null
        declare -f router_reason_disposition >/dev/null 2>&1 \
            && _disp="$(router_reason_disposition "${_reason:-router_rc_nonzero}")"
        _ia_write "$art" "$_disp" \
            "the model call failed (${_reason:-rc=$rc}) — the change was not judged"
        return 1
    fi

    # No `| head` (#1886): capture in full, trim in bash.
    local _v _r _u_line _s_line
    _v="$(grep -oE 'VERDICT:[[:space:]]*(pass|fail|unsure)' <<< "$_raw" || true)"
    _v="${_v%%$'\n'*}"; _v="${_v##*[[:space:]]}"
    _r="$(grep -E '^REASON:' <<< "$_raw" || true)"
    _r="${_r%%$'\n'*}"; _r="${_r#REASON:}"; _r="${_r#"${_r%%[![:space:]]*}"}"
    # Every UNMET:/UNSURE: line, each one whole finding (ADR-068 §5).
    _u_line="$(grep -E '^UNMET:' <<< "$_raw" || true)"
    _s_line="$(grep -E '^UNSURE:' <<< "$_raw" || true)"

    if [[ -z "$_v" ]]; then
        # ADR-054 §6a: the stage ran but its output cannot be used — retry.
        _ia_write "$art" unusable \
            "no parseable verdict from the model — the change was not judged"
        return 0
    fi

    local _u_json='[]' _s_json
    [[ "$_v" == "pass" ]] || _u_json="$(_ia_list "$_u_line")"
    # #2304 (ADR-069 §7): a requirement the judge is not sure of is never a
    # pass — whatever the verdict line says — and is reported as open.
    _s_json="$(_ia_list "$_s_line")"
    if [[ "$_s_json" != "[]" || "$_v" == "unsure" ]]; then
        _v="fail"
        _ia_emit "issue_acceptance.unsure" "count=$(jq 'length' <<< "$_s_json" 2>/dev/null || printf 0)"
    fi

    _ia_emit "issue_acceptance.judged" "verdict=$_v"
    _ia_write "$art" "$_v" "${_r:-judged the change against the issue}" "$_u_json" "$_s_json"
    return 0
}

# _ia_list <lines> — a JSON array with one item per `KEY: text` line, the key
# and surrounding blanks dropped; "none" (any case) and blanks are dropped. A
# line is never split: a `;` in its prose is part of the finding (#1944).
_ia_list() {
    local _j=""
    [[ -n "${1// }" ]] && _j="$(jq -Rsc 'split("\n") | map(sub("^[A-Z]+:";"") | sub("^[[:space:]]+";"") | sub("[[:space:]]+$";"")) | map(select(length > 0 and ascii_downcase != "none"))' <<< "$1" 2>/dev/null || true)"
    printf '%s' "${_j:-[]}"
}

issue_acceptance_cleanup() { return 0; }
