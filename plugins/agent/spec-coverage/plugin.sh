#!/usr/bin/env bash
# plugins/agent/spec-coverage/plugin.sh — does the design cover the ISSUE?
# (#1683, ADR-040 §5, ADR-054, ADR-060)
#
# Kind: agent  Tier: T2  convergence: gate (its standard is the issue, which the
# judged party cannot re-author — ADR-040 §5 as amended by #2040).
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_SPEC_COVERAGE_LOADED:-}" ]] && return 0
_ZBUILD_SPEC_COVERAGE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_SCV_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_SCV_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/persona-resolve.sh
source "$_SCV_ROOT/scripts/lib/persona-resolve.sh" 2>/dev/null || true
# shellcheck source=../../../core/plugin-registry/persona.sh
source "$_SCV_ROOT/core/plugin-registry/persona.sh" 2>/dev/null || true

_scv_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# _scv_issue_is_placeholder <text>
# intake writes the literal "GitHub issue #<N>" when `gh issue view` fails
# (intake/plugin.sh:81-86). The warning goes to stderr only and NOTHING in the
# artifact marks it, so a consumer cannot tell a failed fetch from a real issue
# whose entire body is that string (#1804). Detecting the shape is the only
# signal available — and it must not be conflated with "covered", which is the
# #1947 defect: one branch serving "nothing to check" and "the check did not
# happen".
_scv_issue_is_placeholder() {
    local t="${1-}"
    t="$(printf '%s' "$t" | tr -d '[:space:]')"
    [[ -z "$t" ]] && return 0
    [[ "$t" =~ ^GitHubissue#[0-9]+$ ]]
}

_scv_prompt() {
    printf '%s' "You are checking whether a DESIGN covers what an ISSUE asked for.

You will be shown two things:

ISSUE — what was asked for, in the requester's own words.
ACCEPTANCE — the SPEC sentences the design commits to.

Judge only this: is there anything the ISSUE requires that no SPEC covers?

An issue contains more than requirements — context, rationale, links, history.
Those are not requirements and their absence from the SPECs is not a gap. Judge
what the issue REQUIRES, not everything it mentions.

If the issue enumerates expectations explicitly (checkboxes, a numbered list),
each one is a requirement and must map to a SPEC.

Answer in at most three lines:

VERDICT: covered | uncovered
REASON: <one sentence>
UNCOVERED: <semicolon-separated requirements no SPEC covers; omit when covered>

Do not suggest SPEC text. Do not rewrite the design. Answer only.

ISSUE:
$1

ACCEPTANCE:
$2"
}

# _scv_write <dir> <verdict> <reason> <uncovered_json>
_scv_write() {
    local dir="$1" v="$2" r="$3" u="${4:-[]}"
    mkdir -p "$dir" 2>/dev/null || true
    # ADR-054 §6: `disposition` says how the STAGE stopped, not what it
    # concluded — this stage completed either way. ADR-060 §1/§2: the finding is
    # structured, never a prose document.
    if ! jq -n --arg v "$v" --arg r "$r" --argjson u "$u" \
        '{result_contract: 2, verdict: $v, disposition: "complete", reason: $r,
          data: {uncovered: $u}}' \
        | atomic_write "$dir/spec-coverage-result.json"; then
        _scv_emit "spec_coverage.result.write_failed" "dir=$dir"
    fi
    local _body="- every requirement the issue states maps to a declared SPEC"
    [[ "$u" != "[]" ]] && _body="$(jq -r '.[] | "- NOT COVERED: " + .' <<< "$u" 2>/dev/null || printf -- '- see result')"
    stage_summary_write "$dir/spec-coverage-summary.md" "spec-coverage" "$v" "$r" "$_body"
}

# ─── spec_coverage_run <stage_id> <state_file> [resolved_inputs] ─────────────
# ADR-054 §4: rc is binary.
spec_coverage_run() {
    local stage_id="${1:-spec-coverage}"; : "$stage_id"
    local state_file="${2:-}"

    local state_dir art
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        state_dir="$(dirname "$state_file")"
    else
        state_dir="${ZBUILD_STATE_DIR:-}"
    fi
    art="${ZBUILD_ARTIFACT_DIR:-$state_dir/artifacts}"
    [[ -n "$art" ]] || return 1
    mkdir -p "$art" 2>/dev/null || true

    local issue="" design="$art/design.md"
    [[ -f "$state_dir/intake.md" ]] && issue="$(cat "$state_dir/intake.md" 2>/dev/null || true)"

    # Fail loudly, never vacuously: a design judged against a placeholder must
    # not read as satisfied.
    if _scv_issue_is_placeholder "$issue"; then
        _scv_emit "spec_coverage.unreadable_issue" "stage=$stage_id"
        _scv_write "$art" "unreadable" \
            "the issue text is absent or a placeholder — the design was not judged against anything" "[]"
        return 0
    fi

    local acc=""
    declare -f extract_acceptance_block >/dev/null 2>&1 \
        && acc="$(extract_acceptance_block "$design" 2>/dev/null || true)"
    if [[ -z "$acc" ]]; then
        _scv_write "$art" "unreadable" \
            "no acceptance block in design.md — there is no contract to compare against" "[]"
        return 0
    fi

    local tier="T2"
    declare -f resolve_tier >/dev/null 2>&1 \
        && tier="$(resolve_tier spec-coverage "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"

    # #1627/#1628: resolve the persona rather than inlining it, so editing
    # plugins/persona/product-owner/ actually changes behaviour. resolve_persona
    # returns the DIRECTORY; persona_stage_framing wants the id.
    local _task _framed _pid="product-owner" _pdir
    _task="$(_scv_prompt "$issue" "$acc")"
    _framed="$_task"
    if declare -f persona_stage_framing >/dev/null 2>&1; then
        if declare -f resolve_persona >/dev/null 2>&1; then
            _pdir="$(resolve_persona spec-coverage 2>/dev/null || true)"
            [[ -n "$_pdir" ]] && _pid="$(basename "$_pdir")"
        fi
        local _f
        if _f="$(persona_stage_framing "$_pid" "$_task" 2>/dev/null)" && [[ -n "$_f" ]]; then
            _framed="$_f"
            export ZBUILD_STAGE_IO_PERSONA="$_pid"
        fi
    fi

    local _raw=""
    # No 2>/dev/null on this call: the stage-io input banner writes to fd 2 and
    # suppressing it breaks ADR-015 §v4's ordering (the #491 defect).
    if declare -f route_to_model >/dev/null 2>&1; then
        _raw="$(route_to_model "$tier" "$_framed" || true)"
    fi

    # No `| head`: SIGPIPE kills the writer under errexit for a reason nothing
    # logs (#1886). Capture in full, trim in bash.
    local _v _r _u_line
    _v="$(grep -oE 'VERDICT:[[:space:]]*(covered|uncovered)' <<< "$_raw" || true)"
    _v="${_v%%$'\n'*}"; _v="${_v##*[[:space:]]}"
    _r="$(grep -E '^REASON:' <<< "$_raw" || true)"
    _r="${_r%%$'\n'*}"; _r="${_r#REASON:}"; _r="${_r#"${_r%%[![:space:]]*}"}"
    _u_line="$(grep -E '^UNCOVERED:' <<< "$_raw" || true)"
    _u_line="${_u_line%%$'\n'*}"; _u_line="${_u_line#UNCOVERED:}"

    if [[ -z "$_v" ]]; then
        _scv_write "$art" "unreadable" \
            "no parseable verdict from the model — the design was not judged" "[]"
        return 0
    fi

    local _u_json='[]'
    if [[ "$_v" == "uncovered" && -n "${_u_line// }" ]]; then
        _u_json="$(printf '%s' "$_u_line" | tr ';' '\n' \
            | jq -R 'sub("^[[:space:]]+";"") | sub("[[:space:]]+$";"") | select(length > 0)' \
            | jq -sc . 2>/dev/null || printf '[]')"
    fi

    _scv_emit "spec_coverage.judged" "verdict=$_v"
    _scv_write "$art" "$_v" "${_r:-judged the design against the issue}" "$_u_json"
    return 0
}

spec_coverage_cleanup() { return 0; }
