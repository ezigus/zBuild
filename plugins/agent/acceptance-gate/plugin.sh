#!/usr/bin/env bash
# plugins/agent/acceptance-gate — mechanical acceptance-contract gate (ADR-036, #922)
#
# Level 1: every SPEC-n id in the design ```acceptance block must have ≥1
#          [SPEC-n]-tagged assertion across the declared TESTFILES.
# Level 2: each SPEC-n's tagged test must fail at the merge-base baseline and
#          pass at HEAD (negative control — rejects tautological "green but
#          inert" tests, the #844 defect class).
# No-op pass when the acceptance block is absent (composability). No model call.

[[ -n "${_ZBUILD_ACCEPTANCE_GATE_LOADED:-}" ]] && return 0
_ZBUILD_ACCEPTANCE_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_AG_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_AG_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_AG_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../../scripts/lib/acceptance-coverage.sh
source "$_AG_ROOT/scripts/lib/acceptance-coverage.sh"
# shellcheck source=../../../scripts/lib/acceptance-negctl.sh
source "$_AG_ROOT/scripts/lib/acceptance-negctl.sh"

acceptance_gate_run() {
    # shellcheck disable=SC2034  # hook-signature positional; unused here
    local _stage_id="$1"
    local state_file="$2"
    if [[ -z "$state_file" ]]; then
        error "acceptance_gate_run: requires <stage_id> <state_file>"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"
    local result_file="$artifact_dir/acceptance-gate-result.json"
    local design_md="$artifact_dir/design.md"

    # repo_root = git toplevel of the working tree (where build's commits live);
    # fall back to PWD when not in a git tree (degraded; negctl will report).
    local repo_root; repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    eb_emit_event "acceptance.gate.start" "stage=acceptance-gate"

    # No-op pass when the acceptance block is absent (composability contract).
    if ! extract_acceptance_block "$design_md" >/dev/null 2>&1; then
        printf '{"verdict":"pass","reason":"skipped","failures":[]}\n' | atomic_write "$result_file"
        eb_emit_event "acceptance.gate.skipped" "stage=acceptance-gate" "reason=no_acceptance_block"
        eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=pass"
        return 0
    fi

    local verdict="pass"
    local -a failures=()
    local line

    # ── Level 1: SPEC-n tag-presence ─────────────────────────────────────────
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # line: "UNTAGGED SPEC-n"
        local sid="${line#UNTAGGED }"
        failures+=("untagged_spec:$sid")
        verdict="fail"
        eb_emit_event "acceptance.gate.untagged_spec" "stage=acceptance-gate" "spec_id=$sid"
    done < <(acceptance_coverage_check "$design_md" "$repo_root" || true)

    # ── Level 2: baseline negative-control (only if Level 1 clean) ───────────
    if [[ "$verdict" == "pass" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                "NEGCTL PASS "*) : ;;  # control confirmed
                "NEGCTL SKIP "*) : ;;  # no_impl_delta — legitimate skip
                "NEGCTL FAIL "*)
                    # "NEGCTL FAIL <spec_id> <reason>"
                    local rest="${line#NEGCTL FAIL }"
                    local sid="${rest%% *}" reason="${rest#* }"
                    failures+=("$reason:$sid")
                    verdict="fail"
                    eb_emit_event "acceptance.gate.tautology" "stage=acceptance-gate" \
                        "spec_id=$sid" "reason=$reason"
                    ;;
                "NEGCTL ERROR "*)
                    local detail="${line#NEGCTL ERROR }"
                    failures+=("negctl_error:$detail")
                    verdict="fail"
                    case "$detail" in
                        baseline_resolve_failed)
                            eb_emit_event "acceptance.gate.baseline_resolve_failed" "stage=acceptance-gate" ;;
                        worktree_failed*)
                            eb_emit_event "acceptance.gate.worktree_failed" "stage=acceptance-gate" "detail=$detail" ;;
                    esac
                    ;;
            esac
        done < <(acceptance_negctl_check "$design_md" "$repo_root" || true)
    fi

    # ── Write result artifact ────────────────────────────────────────────────
    local failures_json="[]"
    if [[ ${#failures[@]} -gt 0 ]]; then
        failures_json="$(printf '%s\n' "${failures[@]}" | jq -R . | jq -s .)"
    fi
    printf '{"verdict":"%s","failures":%s}\n' "$verdict" "$failures_json" | atomic_write "$result_file"

    eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=$verdict"

    [[ "$verdict" == "fail" ]] && return 1
    return 0
}
