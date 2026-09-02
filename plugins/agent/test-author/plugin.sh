#!/usr/bin/env bash
# plugins/agent/test-author/plugin.sh — authors acceptance assertions from the
# SPEC, before build implements against them (#2022, ADR-036, ADR-054).
#
# Kind: agent  Tier: T2 (config.tier_default)
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TEST_AUTHOR_LOADED:-}" ]] && return 0
_ZBUILD_TEST_AUTHOR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_TA_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_TA_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_TA_ROOT/scripts/lib/llm-agent.sh" 2>/dev/null || true
# shellcheck source=../../../plugins/tool/assertion-integrity/plugin.sh
source "$_TA_ROOT/plugins/tool/assertion-integrity/plugin.sh" 2>/dev/null || true

_ta_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# _ta_write_result <dir> <verdict> <disposition> <reason> <n_specs>
# ADR-054 §5: one result file, every mandatory key. §6: `disposition` says how
# the STAGE stopped; `verdict` says what it produced. A router timeout is not a
# poor authoring pass, it is no authoring pass at all.
_ta_write_result() {
    local dir="$1" v="$2" d="$3" r="$4" n="${5:-0}"
    mkdir -p "$dir" 2>/dev/null || true
    if ! jq -n --arg v "$v" --arg d "$d" --arg r "$r" --argjson n "${n:-0}" \
        '{result_contract: 2, verdict: $v, disposition: $d, reason: $r,
          data: {specs_covered: $n}}' \
        | atomic_write "$dir/test-author-result.json"; then
        _ta_emit "test_author.result.write_failed" "dir=$dir"
    fi
    stage_summary_write "$dir/test-author-summary.md" "test-author" "$v" "$r" \
        "$(printf -- '- SPECs in the contract: %s\n- assertions are authored from the SPEC text, never from the implementation' "${n:-0}")"
}

# ─── test_author_run <stage_id> <state_file> [resolved_inputs] ───────────────
# ADR-054 §4: rc is binary. rc=0 = "my result file is on disk"; rc=1 = "I
# failed". Nothing else.
test_author_run() {
    local stage_id="${1:-test-author}"; : "$stage_id"
    local state_file="${2:-}"

    local art
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        art="$(dirname "$state_file")/artifacts"
    else
        art="${ZBUILD_ARTIFACT_DIR:-}"
    fi
    [[ -n "$art" ]] || return 1
    mkdir -p "$art" 2>/dev/null || true

    local repo="${ZBUILD_REPO_ROOT:-$_TA_ROOT}"
    local design="$art/design.md"

    if [[ ! -f "$design" ]] || ! declare -f acceptance_list_spec_ids >/dev/null 2>&1; then
        _ta_emit "test_author.no_contract" "reason=no_design"
        _ta_write_result "$art" "complete" "complete" \
            "no design.md acceptance block — there is no contract to author against" 0
        return 0
    fi

    # ── The contract, and ONLY the contract ─────────────────────────────────
    # #1978: naming a SPEC by id while its requirement sits 130 lines away is
    # how an assertion comes to test something else. The text travels with the id.
    local sid n=0 spec_block=""
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        local _txt _cls _tfs
        _txt="$(acceptance_spec_text "$design" "$sid" 2>/dev/null || true)"
        _cls="$(acceptance_spec_classifier "$design" "$sid" 2>/dev/null || true)"
        _tfs="$(acceptance_list_testfiles_for_spec "$design" "$sid" 2>/dev/null | tr '\n' ' ')"
        spec_block="${spec_block}- ${sid} [${_cls:-change}] ${_txt}"$'\n'
        spec_block="${spec_block}    testfile(s): ${_tfs}"$'\n'
        n=$(( n + 1 ))
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)

    if [[ "$n" -eq 0 ]]; then
        _ta_emit "test_author.no_contract" "reason=no_specs"
        _ta_write_result "$art" "complete" "complete" \
            "the acceptance block declares no SPECs — nothing to author" 0
        return 0
    fi

    # The prompt is the SPEC text and the target paths. It carries NO diff, no
    # build summary, no implementation of any kind: an author that can read the
    # code will describe the code, which is the very defect this stage exists to
    # remove. The omission is the mechanism, and it is asserted in the test.
    local prompt
    prompt="You are the test author. Write the acceptance assertions for the requirements below, in the language and idiom the target repository already uses.

You cannot see the implementation, and you must not guess at it. Write what the requirement DEMANDS, not what some implementation might do. Each assertion must be able to FAIL: if the requirement were not met, your assertion must not pass.

Tag each assertion with its SPEC id in square brackets, exactly as shown.

REQUIREMENTS:
${spec_block}
Write or amend only the testfile(s) named above. Do not write, modify or stub any implementation file."

    local tier="T2" rc=0
    declare -f resolve_tier >/dev/null 2>&1 && tier="$(resolve_tier test-author "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"

    if ! declare -f route_to_model >/dev/null 2>&1; then
        _ta_write_result "$art" "degraded" "unavailable" \
            "no router available to author assertions" "$n"
        return 1
    fi
    route_to_model "$tier" "$prompt" >/dev/null 2>&1 || rc=$?

    if [[ $rc -ne 0 ]]; then
        # ADR-054 §6: the engine's closed set decides what happens next; this
        # stage only says HOW it stopped. _llm_router_classify owns the mapping
        # so a new rc does not need a new opinion here.
        local _v="" _reason="" _disp="broken"
        if declare -f _llm_router_classify >/dev/null 2>&1; then
            _llm_router_classify "$rc" _v _reason 2>/dev/null || true
        fi
        case "${_reason:-}" in
            router_timeout|*interrupt*) _disp="interrupted" ;;
            *throttl*|*rate*)           _disp="throttled" ;;
            *unavailable*)              _disp="unavailable" ;;
            *budget*|*exhaust*)         _disp="exhausted" ;;
        esac
        _ta_write_result "$art" "degraded" "$_disp" \
            "the model call failed (${_reason:-rc=$rc}) — no assertions were authored" "$n"
        return 1
    fi

    # The digests are recorded HERE, by the author, immediately after authoring.
    # Recording anywhere else would baseline someone else's edit as if it were
    # the author's — which is precisely what the guard exists to catch.
    declare -f assertion_integrity_record >/dev/null 2>&1 \
        && assertion_integrity_record "$art" "$repo"

    _ta_emit "test_author.authored" "specs=$n"
    _ta_write_result "$art" "complete" "complete" \
        "authored acceptance assertions for $n SPEC(s) from the design contract" "$n"
    return 0
}

test_author_cleanup() { return 0; }
