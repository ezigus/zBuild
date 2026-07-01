#!/usr/bin/env bash
# plugins/agent/acceptance-gate — mechanical acceptance-contract gate (ADR-036, #922/#956)
#
# Level 1: every SPEC-n id in the design ```acceptance block must have ≥1
#          [SPEC-n]-tagged assertion across the declared TESTFILES.
# Level 2: each SPEC-n's tagged test must fail at the merge-base baseline and
#          pass at HEAD (negative control — rejects tautological "green but
#          inert" tests, the #844 defect class).
# Level 3: if the design declares a WIRING: section, revert each declared file
#          to merge-base (keeping all other changes at HEAD) and require ≥1
#          TESTFILE to flip pass→fail — proving the wiring is load-bearing.
#          WIRING: none exempts the check. (ADR-036 Level-3, #956)
# No-op pass when the acceptance block is absent (composability). No model call.

[[ -n "${_ZBUILD_ACCEPTANCE_GATE_LOADED:-}" ]] && return 0
_ZBUILD_ACCEPTANCE_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_AG_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_AG_ROOT/core/event-bus/event-bus.sh"
# #963: source the read-only grammar libs from _ZBUILD_CONTRACT_LIB_DIR (set by
# zbuild_plugin_bootstrap above) so a self-host run reads the working-tree grammar.
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-block.sh"
# shellcheck source=../../../scripts/lib/acceptance-coverage.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-coverage.sh"
# shellcheck source=../../../scripts/lib/acceptance-negctl.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-negctl.sh"
# shellcheck source=../../../scripts/lib/acceptance-reachability.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-reachability.sh"

# _ag_resolve_negctl_timeout <stage_id> — per-test negctl/reachability timeout (s).
# Precedence (ADR-036 #1188): explicit ZBUILD_NEGCTL_TIMEOUT env > per-stage
# template `negctl_timeout_s:` > 60s default. Env wins so CI/operators (and the
# timeout test) can force a value regardless of the template default.
_ag_resolve_negctl_timeout() {
    local stage_id="${1:-acceptance-gate}"
    if [[ "${ZBUILD_NEGCTL_TIMEOUT:-}" =~ ^[0-9]+$ ]]; then
        printf '%s' "$ZBUILD_NEGCTL_TIMEOUT"; return 0
    fi
    if declare -F template_stage_negctl_timeout >/dev/null 2>&1; then
        local v; v="$(template_stage_negctl_timeout "$stage_id" 2>/dev/null || true)"
        if [[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 ]]; then printf '%s' "$v"; return 0; fi
    fi
    printf '60'
}

# _ag_classify_disposition <failure...> — map this gate's failure classes to the
# GENERIC member-disposition contract (ADR-021 / ADR-036 §-Disposition) the cycle
# engine reads. The engine knows NO acceptance-gate failure vocabulary; it only
# reads the disposition field this function computes. Precedence (highest wins):
#   terminal    — ≥1 GENUINE violation: tautology, not_passing_at_head,
#                 inert_wiring, no_testfile, malformed_acceptance_block.
#   recoverable — only untagged_spec:* (fed back to build via the #951 edge).
#   advisory    — only infra classes: negctl_error:* / reachability_error:*
#                 (baseline/worktree resolve failures + negctl/reachability
#                 TIMEOUTS — a flaky sandbox must never hard-fail the pipeline).
# Empty failure set → "none". Echoes exactly one token.
_ag_classify_disposition() {
    local f had_recoverable=0 had_advisory=0
    for f in "$@"; do
        case "$f" in
            untagged_spec:*)                         had_recoverable=1 ;;
            negctl_error:* | reachability_error:*)   had_advisory=1 ;;
            "")                                      : ;;
            *)                                       printf 'terminal'; return 0 ;;  # genuine violation
        esac
    done
    if [[ $had_recoverable -eq 1 ]]; then printf 'recoverable'; return 0; fi
    if [[ $had_advisory   -eq 1 ]]; then printf 'advisory';    return 0; fi
    printf 'none'
}

acceptance_gate_run() {
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

    # ADR-036 #1188: plumb the per-test timeout knob and a diagnostic-log dir to
    # the negctl/reachability libs (they read these two env vars).
    export ZBUILD_NEGCTL_TIMEOUT; ZBUILD_NEGCTL_TIMEOUT="$(_ag_resolve_negctl_timeout "${_stage_id:-acceptance-gate}")"
    export ZBUILD_NEGCTL_ARTIFACT_DIR="$artifact_dir"

    # repo_root = git toplevel of the working tree (where build's commits live);
    # fall back to PWD when not in a git tree (degraded; negctl will report).
    local repo_root; repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    eb_emit_event "acceptance.gate.start" "stage=acceptance-gate"

    # Distinguish ABSENT from MALFORMED: extract_acceptance_block returns
    # non-zero for both, so check for the fence first. No fence → no-op pass
    # (composability). Fence present but unparseable → fail closed (a malformed
    # contract must NOT bypass the gate).
    if [[ ! -f "$design_md" ]] || ! grep -q '^```acceptance' "$design_md" 2>/dev/null; then
        printf '{"verdict":"pass","reason":"skipped","failures":[]}\n' | atomic_write "$result_file"
        eb_emit_event "acceptance.gate.skipped" "stage=acceptance-gate" "reason=no_acceptance_block"
        eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=pass"
        return 0
    fi
    if ! extract_acceptance_block "$design_md" >/dev/null 2>&1; then
        printf '{"verdict":"fail","reason":"malformed_acceptance_block","disposition":"terminal","failures":["malformed_acceptance_block"]}\n' \
            | atomic_write "$result_file"
        eb_emit_event "acceptance.gate.untagged_spec" "stage=acceptance-gate" "reason=malformed_acceptance_block"
        eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=fail"
        return 1
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
                        timeout:*)
                            # INFRA (ADR-036 #1188): non-terminal, distinct from a violation.
                            eb_emit_event "acceptance.gate.negctl_timeout" "stage=acceptance-gate" \
                                "spec_id=${detail#timeout:}" "timeout_s=${ZBUILD_NEGCTL_TIMEOUT:-60}" ;;
                    esac
                    ;;
            esac
        done < <(acceptance_negctl_check "$design_md" "$repo_root" || true)
    fi

    # ── Level 3: reachability (only if Level 1 and Level 2 clean) ────────────
    if [[ "$verdict" == "pass" ]]; then
        # Only run Level-3 when a WIRING: section is present.
        local wiring_present=0
        acceptance_list_wiring "$design_md" >/dev/null 2>&1 && wiring_present=1
        if [[ "$wiring_present" -eq 1 ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                case "$line" in
                    "REACHABILITY PASS "*) : ;;  # wiring is load-bearing
                    "REACHABILITY EXEMPT none")
                        eb_emit_event "acceptance.gate.wiring_exempt" "stage=acceptance-gate" ;;
                    "REACHABILITY SKIP "*)   : ;;  # no_impl_delta
                    "REACHABILITY FAIL inert_wiring "*)
                        local target="${line#REACHABILITY FAIL inert_wiring }"
                        failures+=("inert_wiring:$target")
                        verdict="fail"
                        eb_emit_event "acceptance.gate.inert_wiring" "stage=acceptance-gate" \
                            "target=$target"
                        ;;
                    "REACHABILITY ERROR "*)
                        local detail="${line#REACHABILITY ERROR }"
                        failures+=("reachability_error:$detail")
                        verdict="fail"
                        case "$detail" in
                            timeout:*)
                                # INFRA (ADR-036 #1188): non-terminal.
                                eb_emit_event "acceptance.gate.reachability_timeout" "stage=acceptance-gate" \
                                    "target=${detail#timeout:}" "timeout_s=${ZBUILD_NEGCTL_TIMEOUT:-60}" ;;
                        esac
                        ;;
                esac
            done < <(acceptance_reachability_check "$design_md" "$repo_root" || true)
        fi
    fi

    # ── Write result artifact ────────────────────────────────────────────────
    # `disposition` is the GENERIC contract the cycle engine reads (ADR-021): the
    # engine no longer knows this gate's failure vocabulary — it only halts on an
    # explicit disposition==terminal. Computed from the failure classes here.
    local failures_json="[]" disposition
    if [[ ${#failures[@]} -gt 0 ]]; then
        failures_json="$(printf '%s\n' "${failures[@]}" | jq -R . | jq -s .)"
        disposition="$(_ag_classify_disposition "${failures[@]}")"
    else
        disposition="none"
    fi
    printf '{"verdict":"%s","disposition":"%s","failures":%s}\n' \
        "$verdict" "$disposition" "$failures_json" | atomic_write "$result_file"

    eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=$verdict"

    [[ "$verdict" == "fail" ]] && return 1
    return 0
}
