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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_IA_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_IA_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_IA_ROOT/core/router/route.sh"
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_IA_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_IA_ROOT/scripts/lib/llm-agent.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_IA_ROOT/scripts/lib/router-rc-classify.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/persona-resolve.sh
source "$_IA_ROOT/scripts/lib/persona-resolve.sh" 2>/dev/null || true
# shellcheck source=../../../core/plugin-registry/persona.sh
source "$_IA_ROOT/core/plugin-registry/persona.sh" 2>/dev/null || true

_ia_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# _ia_input <id> — the path the engine's index names for a declared input, or
# empty. ADR-055 §1: the index is the only way an input reaches this stage.
_ia_input() {
    [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -f "${ZBUILD_STAGE_INPUTS:-}" ]] || return 0
    jq -r --arg id "$1" '.inputs[$id] // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true
}

# intake writes the literal "GitHub issue #<N>" when the fetch fails (#1804);
# judging a change against that must not read as satisfied (spec-coverage's rule).
_ia_issue_is_placeholder() {
    local t="${1-}"
    t="${t//[[:space:]]/}"
    [[ -z "$t" ]] && return 0
    [[ "$t" =~ ^GitHubissue#[0-9]+$ ]]
}

_ia_prompt() {
    printf '%s' "You are checking whether a finished CHANGE does what an ISSUE asked for.

You will be shown:

ISSUE — what was asked for, in the requester's own words. This is the standard.
ACCEPTANCE — the SPEC sentences the design committed to.
DIFF — the change as built.
TEST VERDICT — whether the test suite passed.

For every requirement the ISSUE states, decide whether the DIFF meets it IN FULL.
Judge against the issue's own words, not the SPECs: a SPEC that narrowed a
requirement does not make the narrowed version enough. A requirement met only
partly — a subset of the cases, a weaker condition, some of the files — is unmet.

An issue contains more than requirements — context, rationale, links, history.
Those are not requirements. A requirement about HOW the change is verified (tests
fail at the merge base, the suite is green, the tree is committed first) is proven
by the pipeline itself; never judge it here.

If a requirement is unmet, name its fault:
  specification — no SPEC captures the requirement (the contract missed it)
  implementation — a SPEC captures it, but the code does not do it
If both kinds occur, answer specification.

Answer in at most four lines:

VERDICT: pass | fail
FAULT: specification | implementation   (omit on pass)
REASON: <one sentence>
UNMET: <semicolon-separated issue requirements the diff does not meet; omit on pass>

Do not suggest code. Answer only.

ISSUE:
$1

ACCEPTANCE:
$2

DIFF:
$3

TEST VERDICT: $4"
}

# _ia_write <dir> <verdict> <disposition> <reason> [fault] [unmet_json]
_ia_write() {
    local dir="$1" v="$2" d="$3" r="$4" f="${5:-}" u="${6:-[]}"
    mkdir -p "$dir" 2>/dev/null || true
    if ! jq -n --arg v "$v" --arg d "$d" --arg r "$r" --arg f "$f" --argjson u "$u" \
        '{result_contract: 2, verdict: $v, disposition: $d, reason: $r, data: {unmet: $u}}
         + (if $f != "" then {fault: $f} else {} end)' \
        | atomic_write "$dir/issue-acceptance-result.json"; then
        _ia_emit "issue_acceptance.result.write_failed" "dir=$dir"
    fi
    local _body="- every requirement the issue states is met by the change"
    [[ "$u" != "[]" ]] && _body="$(jq -r '.[] | "- NOT MET: " + .' <<< "$u" 2>/dev/null || printf -- '- see result')"
    [[ "$v" == "unreadable" ]] && _body="- the change was not judged against the issue"
    stage_summary_write "$dir/issue-acceptance-summary.md" "issue-acceptance" "$v" "$r" "$_body"
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

    local issue_f design_f diff_f tests_f issue="" acc="" diff="" test_verdict=""
    issue_f="$(_ia_input intake_goal)"; design_f="$(_ia_input design)"
    diff_f="$(_ia_input diff_patch)"; tests_f="$(_ia_input test_results)"
    [[ -n "$issue_f" && -f "$issue_f" ]] && issue="$(cat "$issue_f" 2>/dev/null || true)"

    if _ia_issue_is_placeholder "$issue"; then
        _ia_emit "issue_acceptance.unreadable_issue" "stage=$stage_id"
        _ia_write "$art" "unreadable" "complete" \
            "the issue text is absent or a placeholder — the change was not judged against anything"
        return 0
    fi

    [[ -n "$design_f" && -f "$design_f" ]] && declare -f extract_acceptance_block >/dev/null 2>&1 \
        && acc="$(extract_acceptance_block "$design_f" 2>/dev/null || true)"
    [[ -n "$diff_f" && -f "$diff_f" ]] && diff="$(cat "$diff_f" 2>/dev/null || true)"
    [[ -n "$tests_f" && -f "$tests_f" ]] && test_verdict="$(jq -r '.verdict // empty' "$tests_f" 2>/dev/null || true)"

    local tier="T2"
    declare -f resolve_tier >/dev/null 2>&1 \
        && tier="$(resolve_tier issue-acceptance "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"

    local _task _framed _pid="product-owner" _pdir _f
    _task="$(_ia_prompt "$issue" "${acc:-<none>}" "${diff:-<no diff>}" "${test_verdict:-unknown}")"
    _framed="$_task"
    if declare -f persona_stage_framing >/dev/null 2>&1; then
        if declare -f resolve_persona >/dev/null 2>&1; then
            _pdir="$(resolve_persona issue-acceptance 2>/dev/null || true)"
            [[ -n "$_pdir" ]] && _pid="$(basename "$_pdir")"
        fi
        if _f="$(persona_stage_framing "$_pid" "$_task" 2>/dev/null)" && [[ -n "$_f" ]]; then
            _framed="$_f"
            export ZBUILD_STAGE_IO_PERSONA="$_pid"
        fi
    fi

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
        _ia_write "$art" "unreadable" "$_disp" \
            "the model call failed (${_reason:-rc=$rc}) — the change was not judged"
        return 1
    fi

    # No `| head` (#1886): capture in full, trim in bash.
    local _v _fault _r _u_line
    _v="$(grep -oE 'VERDICT:[[:space:]]*(pass|fail)' <<< "$_raw" || true)"
    _v="${_v%%$'\n'*}"; _v="${_v##*[[:space:]]}"
    _fault="$(grep -oE 'FAULT:[[:space:]]*(specification|implementation)' <<< "$_raw" || true)"
    _fault="${_fault%%$'\n'*}"; _fault="${_fault##*[[:space:]]}"
    _r="$(grep -E '^REASON:' <<< "$_raw" || true)"
    _r="${_r%%$'\n'*}"; _r="${_r#REASON:}"; _r="${_r#"${_r%%[![:space:]]*}"}"
    _u_line="$(grep -E '^UNMET:' <<< "$_raw" || true)"
    _u_line="${_u_line%%$'\n'*}"; _u_line="${_u_line#UNMET:}"

    if [[ -z "$_v" ]]; then
        # ADR-054 §6a: the stage ran but its output cannot be used — retry.
        _ia_write "$art" "unreadable" "unusable" \
            "no parseable verdict from the model — the change was not judged"
        return 0
    fi

    local _u_json='[]'
    if [[ "$_v" == "fail" ]]; then
        # A fail with no class is still a code problem to fix in the cycle.
        _fault="${_fault:-implementation}"
        if [[ -n "${_u_line// }" ]]; then
            _u_json="$(tr ';' '\n' <<< "$_u_line" \
                | jq -Rsc 'split("\n") | map(sub("^[[:space:]]+";"") | sub("[[:space:]]+$";"")) | map(select(length > 0))' 2>/dev/null || true)"
            [[ -n "$_u_json" ]] || _u_json='[]'
        fi
    else
        _fault=""
    fi

    _ia_emit "issue_acceptance.judged" "verdict=$_v" "fault=${_fault:-none}"
    _ia_write "$art" "$_v" "complete" "${_r:-judged the change against the issue}" "$_fault" "$_u_json"
    return 0
}

issue_acceptance_cleanup() { return 0; }
