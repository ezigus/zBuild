#!/usr/bin/env bash
# plugins/agent/spec-correspondence/plugin.sh — does the assertion test what the
# SPEC SAYS? (#2034, ADR-036, ADR-054)
#
# Kind: agent  Tier: T2 (config.tier_default)  Advisory (ADR-040 §5).
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_SPEC_CORRESPONDENCE_LOADED:-}" ]] && return 0
_ZBUILD_SPEC_CORRESPONDENCE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_SC_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../scripts/lib/persona-resolve.sh
source "$_SC_ROOT/scripts/lib/persona-resolve.sh" 2>/dev/null || true
# shellcheck source=../../../core/plugin-registry/persona.sh
source "$_SC_ROOT/core/plugin-registry/persona.sh" 2>/dev/null || true

# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_SC_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/acceptance-coverage.sh
source "$_SC_ROOT/scripts/lib/acceptance-coverage.sh" 2>/dev/null || true

_sc_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# _sc_prompt <requirement> <assertion>
# Deliberately specific about the task and deliberately starved of the code.
# Naming the failure mode matters: without it the judge evaluates "is this a
# good test?", and a good test that tests the wrong thing sails through.
_sc_prompt() {
    printf '%s' "You are checking ONE acceptance requirement against ONE test assertion.

You will be shown exactly two things:

REQUIREMENT — a single sentence from a design document.
ASSERTION   — the source of the test assertion tagged as covering it.

You cannot see the implementation. Do not guess what it does.
Judge only this: if the ASSERTION passes, does that establish the REQUIREMENT?

The failure you are looking for is an assertion that tests something real
and specific, but not what the requirement says — including asserting its
opposite. It will look like reasonable test code. That is expected. The
question is not whether it is a good test. The question is whether it
tests THIS requirement.

Answer in exactly two lines:

VERDICT: corresponds | partial | mismatch | uncheckable
REASON: <one sentence>

  corresponds — passing this assertion would establish the requirement.
  partial     — it tests the right thing, but establishes only part of what
                the requirement promises (one case of several, a narrower
                property, one form where the requirement names two).
  mismatch    — it tests something else, or the reverse of what is required.
  uncheckable — the requirement is too vague to say what would establish it.

Reserve the mismatch verdict for a genuine disagreement between the assertion
and the requirement. An assertion aimed at the right property but narrower in
reach is partial, not mismatch.

Do not suggest a fix. Do not rewrite the assertion. Answer only.

REQUIREMENT:
$1

ASSERTION:
$2"
}

# _sc_write_result <dir> <verdict> <reason> <counts_json>
_sc_write_result() {
    local dir="$1" v="$2" r="$3" d="${4:-{\}}"
    mkdir -p "$dir" 2>/dev/null || true
    # ADR-054 §6: `disposition` says how the STAGE stopped. This stage completed
    # whatever it concluded about the SPECs — the verdict carries that.
    if ! jq -n --arg v "$v" --arg r "$r" --argjson d "$d" \
        '{result_contract: 2, verdict: $v, disposition: "complete", reason: $r, data: $d}' \
        | atomic_write "$dir/spec-correspondence-result.json"; then
        _sc_emit "spec_correspondence.result.write_failed" "dir=$dir"
    fi
}

# ─── spec_correspondence_run <stage_id> <state_file> [resolved_inputs] ───────
spec_correspondence_run() {
    local stage_id="${1:-spec-correspondence}"; : "$stage_id"
    local state_file="${2:-}"

    local art
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        art="$(dirname "$state_file")/artifacts"
    else
        art="${ZBUILD_ARTIFACT_DIR:-}"
    fi
    [[ -n "$art" ]] || return 1
    mkdir -p "$art" 2>/dev/null || true

    local repo="${ZBUILD_REPO_ROOT:-$_SC_ROOT}"
    local design="$art/design.md"

    if [[ ! -f "$design" ]] || ! declare -f acceptance_list_spec_ids >/dev/null 2>&1; then
        _sc_emit "spec_correspondence.no_contract" "reason=no_design"
        _sc_write_result "$art" "corresponds" "no acceptance block — nothing to judge" '{}'
        stage_summary_write "$art/spec-correspondence-summary.md" "spec-correspondence" \
            "corresponds" "no acceptance block — nothing to judge" ""
        return 0
    fi

    local tier="T2"
    declare -f resolve_tier >/dev/null 2>&1 \
        && tier="$(resolve_tier spec-correspondence "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"

    local sid n=0 n_corr=0 n_part=0 n_mis=0 n_unch=0 findings="" worst="corresponds"
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        local _txt _src _tfs _raw _v _r
        _txt="$(acceptance_spec_text "$design" "$sid" 2>/dev/null || true)"
        [[ -n "$_txt" ]] || continue
        _tfs="$(acceptance_list_testfiles_for_spec "$design" "$sid" 2>/dev/null || true)"
        # The whole assertion with its enclosing predicate, comments stripped:
        # a bare tagged line reads as a vacuous test, and a pasted SPEC sentence
        # in a comment would buy a false `corresponds`.
        _src=""
        declare -f acceptance_find_assertion_sources >/dev/null 2>&1 && _src="$(
            # shellcheck disable=SC2086
            acceptance_find_assertion_sources "$repo" "$sid" $_tfs 2>/dev/null || true)"
        [[ -n "$_src" ]] || continue
        n=$(( n + 1 ))

        _raw=""
        # #1627/#1628: a persona manifest nothing resolves is decoration. Frame
        # the task through the registry rather than inlining the words, so
        # editing plugins/persona/quality-assurance/ actually changes behaviour.
        # persona_stage_framing emits "{perspective}\n\n{task}" and returns 1
        # when the persona is absent, in which case the task stands alone rather
        # than carrying an identity-less preamble.
        local _task _framed
        _task="$(_sc_prompt "$_txt" "$_src")"
        _framed="$_task"
        if declare -f persona_stage_framing >/dev/null 2>&1; then
            # resolve_persona returns the persona DIRECTORY, not the id;
            # persona_stage_framing wants the id. Passing the path through
            # silently yields no framing at all — the inert shape again.
            local _pid="quality-assurance" _pdir=""
            if declare -f resolve_persona >/dev/null 2>&1; then
                _pdir="$(resolve_persona spec-correspondence 2>/dev/null || true)"
                [[ -n "$_pdir" ]] && _pid="$(basename "$_pdir")"
            fi
            local _f
            if _f="$(persona_stage_framing "$_pid" "$_task" 2>/dev/null)" && [[ -n "$_f" ]]; then
                _framed="$_f"
                # ADR-015: stage-io stamps the persona on the banner.
                export ZBUILD_STAGE_IO_PERSONA="$_pid"
            fi
        fi
        # No 2>/dev/null here: the stage-io input banner writes to fd 2, and
        # suppressing it drops the banner and breaks ADR-015 §v4's
        # input-before-action ordering — the #491 defect.
        if declare -f route_to_model >/dev/null 2>&1; then
            _raw="$(route_to_model "$tier" "$_framed" || true)"
        fi
        # No `| head`: the reader exits early, the writer takes SIGPIPE, and
        # under errexit the surrounding function dies for a reason nothing logs
        # (#1886). Capture in full, trim in bash.
        _v="$(grep -oE 'VERDICT:[[:space:]]*(corresponds|partial|mismatch|uncheckable)' <<< "$_raw" || true)"
        _v="${_v%%$'\n'*}"; _v="${_v##*[[:space:]]}"
        _r="$(grep -E '^REASON:' <<< "$_raw" || true)"
        _r="${_r%%$'\n'*}"; _r="${_r#REASON:}"; _r="${_r#"${_r%%[![:space:]]*}"}"
        case "${_v:-}" in
            corresponds) n_corr=$(( n_corr + 1 )) ;;
            partial)     n_part=$(( n_part + 1 ))
                         findings="${findings}- ${sid} partial: ${_r}"$'\n' ;;
            mismatch)    n_mis=$(( n_mis + 1 ))
                         findings="${findings}- ${sid} MISMATCH: ${_r}"$'\n' ;;
            uncheckable) n_unch=$(( n_unch + 1 ))
                         findings="${findings}- ${sid} uncheckable: ${_r}"$'\n' ;;
            *)           # An unparseable reply is not a finding about the SPEC.
                         findings="${findings}- ${sid} not judged (no parseable verdict)"$'\n' ;;
        esac
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)

    # Worst-wins, in the vocabulary's own order of seriousness.
    if   [[ "$n_mis"  -gt 0 ]]; then worst="mismatch"
    elif [[ "$n_unch" -gt 0 ]]; then worst="uncheckable"
    elif [[ "$n_part" -gt 0 ]]; then worst="partial"
    fi

    local reason="judged $n SPEC(s): $n_corr correspond, $n_part partial, $n_mis mismatch, $n_unch uncheckable"
    _sc_emit "spec_correspondence.judged" "specs=$n" "mismatch=$n_mis" "partial=$n_part"
    _sc_write_result "$art" "$worst" "$reason" \
        "$(jq -nc --argjson c "$n_corr" --argjson p "$n_part" --argjson m "$n_mis" --argjson u "$n_unch" \
            '{corresponds:$c, partial:$p, mismatch:$m, uncheckable:$u}')"
    stage_summary_write "$art/spec-correspondence-summary.md" "spec-correspondence" "$worst" \
        "$reason" \
        "${findings:-- every judged assertion tests the SPEC it claims to cover}"
    return 0
}

spec_correspondence_cleanup() { return 0; }
