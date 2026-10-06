#!/usr/bin/env bash
# plugins/agent/spec-acceptance — SPEC acceptance-contract gate (ADR-036, #922/#956)
#
# Method-named plugin (id: spec-acceptance) bound to the GENERIC `acceptance_gate`
# role: it implements ONE strategy — SPEC-block negative-control + wiring
# reachability — for verifying a design's acceptance contract. A different repo
# may bind a different plugin to the same role without adopting SPEC.
#
# Level 0: a change that edits production code needs ≥1 [code] requirement
#          (ADR-069 §5, #2304) — otherwise it fails as unclaimed_code.
# Level 1: every SPEC-n id in the design ```acceptance block must have ≥1
#          [SPEC-n]-tagged assertion across the declared TESTFILES.
# Level 2: each code SPEC-n's tagged test must fail at the merge-base baseline
#          and pass at HEAD (negative control — rejects tautological "green but
#          inert" tests, the #844 defect class). Done and no-code SPECs are not
#          run (ADR-069 §4).
# Level 3: if the design declares a WIRING: section, revert each declared file
#          to merge-base (keeping all other changes at HEAD) and require ≥1
#          TESTFILE to flip pass→fail — proving the wiring is load-bearing.
#          WIRING: none exempts the check. (ADR-036 Level-3, #956)
# Preconditions (manifest `preconditions`): when any is unmet the gate NO-OPS
# (verdict=pass, reason=precondition_unmet) so it is safe to compose into repos
# that do not use the SPEC methodology. No model call.

# Size (CLAUDE.md "under 500 lines unless there is a strong reason"): over, and
# left that way. The file is one contract end to end — SPEC failure vocabulary →
# disposition → reason — and ADR-021 puts that mapping HERE
# precisely so the cycle engine stays generic and knows none of this gate's
# vocabulary. Splitting it would scatter one mapping across two files for a line
# count, which is how the engine learned a plugin's vocabulary in the first place.

[[ -n "${_ZBUILD_ACCEPTANCE_GATE_LOADED:-}" ]] && return 0
_ZBUILD_ACCEPTANCE_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_AG_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../scripts/lib/acceptance-disposition.sh
source "$_AG_ROOT/scripts/lib/acceptance-disposition.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_AG_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$_AG_ROOT/scripts/lib/stage-summary.sh"
# #1241: mechanical gates open no router/command span, so this plugin sources the
# stage-io chokepoint directly (router plugins get it via route.sh) to frame its
# operator summary. Load-once sentinel makes this a no-op when the runner already
# sourced it; a standalone/subprocess dispatch still gets stage_io_begin/end.
# shellcheck source=../../../core/output/stage-io.sh
source "$_AG_ROOT/core/output/stage-io.sh"
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
# merge-base.sh (zbuild_resolve_merge_base) — needed by the precondition check;
# also sourced transitively by negctl/reachability. Load-once sentinel = no-op.
# shellcheck source=../../../scripts/lib/merge-base.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/merge-base.sh"
# The gate's reason, operator summary and small helpers (#2304: keeps this file under 500 lines).
# shellcheck source=lib/reason.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/reason.sh"

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
    local design_md=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        design_md="$(jq -r '.inputs.design // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi
    if [[ -z "$design_md" ]]; then
        design_md="${artifact_dir}/design.md"
    fi

    # ADR-036 #1188: plumb the per-test timeout knob and a diagnostic-log dir to
    # the negctl/reachability libs (they read these two env vars).
    export ZBUILD_NEGCTL_TIMEOUT; ZBUILD_NEGCTL_TIMEOUT="$(_ag_resolve_negctl_timeout "${_stage_id:-acceptance-gate}")"
    export ZBUILD_NEGCTL_ARTIFACT_DIR="$artifact_dir"
    # #2110: the measured per-file bound reads the declared `test_timing` input
    # (name-matched, ADR-055 §1); the libs never construct the path.
    local _timing_log=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        _timing_log="$(jq -r '.inputs.test_timing // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi
    export ZBUILD_NEGCTL_TIMING_LOG="$_timing_log"
    # One event per declared TESTFILE naming the bound each of its runs gets
    # and where it came from — how a run proves the measured path fired.
    local _ft_tf _ft_s
    while IFS= read -r _ft_tf; do
        [[ -n "$_ft_tf" ]] || continue
        _ft_s="$(_acceptance_file_timeout "$_ft_tf" "$ZBUILD_NEGCTL_TIMEOUT")"
        eb_emit_event "acceptance.gate.file_timeout" "stage=acceptance-gate" "testfile=$_ft_tf" \
            "timeout_s=$_ft_s" "source=$([[ "$_ft_s" != "$ZBUILD_NEGCTL_TIMEOUT" ]] && echo measured || echo stage)"
    done < <(acceptance_list_testfiles "$design_md" 2>/dev/null || true)
    export ZBUILD_ACCEPTANCE_RUN_CMD

    # repo_root = git toplevel of the working tree (where build's commits live);
    # fall back to PWD when not in a git tree (degraded; negctl will report).
    local repo_root; repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    eb_emit_event "acceptance.gate.start" "stage=acceptance-gate"

    # ── Precondition 1: design acceptance block present ──────────────────────
    # The methodology-adoption discriminator (generalizes the historical no-block
    # skip). Distinguish ABSENT from MALFORMED: extract_acceptance_block returns
    # non-zero for both, so check for the fence first. No fence → no-op.
    if [[ ! -f "$design_md" ]] || ! grep -q '^```acceptance' "$design_md" 2>/dev/null; then
        _ag_noop_precondition_unmet "$result_file" "design_acceptance_block"
        return 0
    fi
    # Fence present but unparseable → fail closed (a malformed contract must NOT
    # bypass the gate; this is a genuine violation, NOT an applicability no-op).
    if ! extract_acceptance_block "$design_md" >/dev/null 2>&1; then
        printf '{"result_contract":2,"verdict":"fail","reason":"malformed_acceptance_block","disposition":"complete","severity":"terminal","failures":["malformed_acceptance_block"]}\n' \
            | atomic_write "$result_file"
        printf 'verdict=fail\nreason=malformed_acceptance_block\n' \
            | atomic_write "$artifact_dir/acceptance-summary.txt"
        eb_emit_event "acceptance.gate.untagged_spec" "stage=acceptance-gate" "reason=malformed_acceptance_block"
        eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=fail"
        return 1
    fi

    # ── Precondition 2: git merge-base resolvable ────────────────────────────
    # The negative control and reachability revert need a baseline: a merge-base
    # against the RESOLVED trunk (origin/HEAD → known names → local, #1655). A
    # shallow/non-git checkout resolves none, and since #1655 that is reported as
    # empty rather than papered over with a HEAD~1 guess; no-op rather than
    # hard-fail (a baseline-resolve miss is already an advisory disposition).
    if [[ -z "$(zbuild_resolve_merge_base "$repo_root" 2>/dev/null)" ]]; then
        _ag_noop_precondition_unmet "$result_file" "merge_base_resolvable"
        return 0
    fi

    # ── Precondition 3: block declares a contract to check ───────────────────
    # An empty/placeholder block (no SPEC ids AND no TESTFILES) is not adopted
    # methodology → no-op. A block that declares SPEC ids but omits TESTFILES is
    # a genuine misuse and falls through to Level 1 (untagged_spec fail) — teeth
    # preserved, NOT a no-op.
    if [[ -z "$(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)" \
        && -z "$(acceptance_list_testfiles "$design_md" 2>/dev/null || true)" ]]; then
        _ag_noop_precondition_unmet "$result_file" "tagged_testfiles"
        return 0
    fi

    local verdict="pass"
    local -a failures=()
    # #2304: what the pass reason counts (ADR-069) — requirements checked on the
    # old and new code, already done, and needing no code.
    local _ag_n_checked=0 _ag_n_done=0 _ag_n_nocode=0
    # #1835: "<spec>=<last SPEC the file printed>" for each unreached SPEC;
    # read by _ag_build_reason (dynamic scope) to say where the file stopped.
    local _ag_unreached_after=""
    # #1211: one concise verdict line per SPEC (negctl) / per WIRING target
    # (reachability), surfaced to the operator after the checks run.
    local -a summary_lines=()
    local line
    # #1220: SPEC ids flagged untagged at Level 1, so Level 2 can suppress the
    # redundant no_testfile it would emit for the SAME id (one root cause, one
    # report). Space-delimited set (" SPEC-1 SPEC-2 ") — membership via glob
    # pattern `*" $sid "*`; simpler than declare -A for a small id set.
    local untagged_ids=" "

    # ── Level 0: code nobody claims (#2304, ADR-069 §5) ──────────────────────
    # A [no-code] or [done] requirement is never run against the old code, so
    # a change that edits production code needs at least one [code]
    # requirement — or nothing shows its tests fail without it. Reported with
    # the other levels in the same pass (#1220), not as an early exit.
    local _uc_path _uc_n=0 _uc_first=""
    while IFS= read -r line; do
        [[ "$line" == "UNCLAIMED_CODE "* ]] || continue
        _uc_path="${line#UNCLAIMED_CODE }"
        failures+=("unclaimed_code:$_uc_path")
        [[ -z "$_uc_first" ]] && _uc_first="$_uc_path"
        _uc_n=$((_uc_n + 1))
        verdict="fail"
    done < <(acceptance_unclaimed_code_check "$design_md" "$repo_root" || true)
    if [[ "$_uc_n" -gt 0 ]]; then
        eb_emit_event "acceptance.gate.unclaimed_code" "stage=acceptance-gate" \
            "files=$_uc_n" "first=$_uc_first"
    fi

    # ── Level 1: SPEC-n tag-presence ─────────────────────────────────────────
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # line: "UNTAGGED SPEC-n"
        local sid="${line#UNTAGGED }"
        failures+=("untagged_spec:$sid")
        untagged_ids="$untagged_ids$sid "
        verdict="fail"
        eb_emit_event "acceptance.gate.untagged_spec" "stage=acceptance-gate" "spec_id=$sid"
    done < <(acceptance_coverage_check "$design_md" "$repo_root" || true)

    # ── Level 2: baseline negative-control ───────────────────────────────────
    # #1220: runs REGARDLESS of Level 1's outcome so every violation class (e.g.
    # a tautological [code] SPEC) is reported in the SAME pass — no whack-a-mole.
    {
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Enrich NEGCTL PASS/FAIL/SKIP lines with SPEC desc and assertion label (#1684)
            local _e_enriched="$line" _e_eid=""
            if [[ "$line" =~ ^NEGCTL\ (PASS|FAIL|SKIP)\ (SPEC-[0-9]+) ]]; then
                _e_eid="${BASH_REMATCH[2]}"
            # #1715: the SPEC id rides in the detail token after the colon, not
            # as a standalone word, so the leading regex cannot capture it.
            elif [[ "$line" =~ ^NEGCTL\ ERROR\ (timeout|sigkill):(SPEC-[0-9]+) ]]; then
                _e_eid="${BASH_REMATCH[2]}"
            fi
            if [[ -n "$_e_eid" ]]; then
                local _e_desc _e_label _e_tf_line
                _e_desc="$(acceptance_spec_desc "$design_md" "$_e_eid")"
                local -a _e_tf=()
                while IFS= read -r _e_tf_line; do
                    [[ -n "$_e_tf_line" ]] && _e_tf+=("$_e_tf_line")
                done < <(acceptance_list_testfiles_for_spec "$design_md" "$_e_eid")
                [[ -z "$_e_desc" ]] && _e_desc="<no description>"
                _e_label="$(acceptance_find_assertion_label "$repo_root" "$_e_eid" "${_e_tf[@]+"${_e_tf[@]}"}")"
                [[ -z "$_e_label" ]] && _e_label="<none found>"
                # #1684: the design's claim and the asserted label go on their
                # own lines, aligned. A mismatch between them is the failure this
                # readout exists to expose, and it is only legible side by side —
                # appended to the verdict line the pair runs past the terminal
                # edge and wraps, which is where the #1662 mismatch hid.
                _e_enriched="${line}"$'\n'"      design : ${_e_desc}"$'\n'"      asserts: ${_e_label}"
            fi
            summary_lines+=("$_e_enriched")  # #1211: one operator line per SPEC (enriched)
            case "$line" in
                "NEGCTL PASS "*) _ag_n_checked=$((_ag_n_checked + 1)) ;;  # control confirmed
                "NEGCTL SKIP "*" already_done") _ag_n_done=$((_ag_n_done + 1)) ;;
                "NEGCTL SKIP "*" no_code")      _ag_n_nocode=$((_ag_n_nocode + 1)) ;;
                "NEGCTL SKIP "*) : ;;  # no_impl_delta — legitimate skip
                "NEGCTL FAIL "*)
                    # "NEGCTL FAIL <spec_id> <reason>"
                    local rest="${line#NEGCTL FAIL }"
                    local sid="${rest%% *}" reason="${rest#* }"
                    # #1835: an unreached line carries where the file stopped
                    # (`after=SPEC-n`) — detail, not part of the class.
                    if [[ "$reason" == *" "* ]]; then
                        [[ "$reason" == *" after="* ]] \
                            && _ag_unreached_after="$_ag_unreached_after $sid=${reason##* after=}"
                        reason="${reason%% *}"
                    fi
                    # #1220: an untagged SPEC necessarily has no tagged testfile;
                    # negctl reports no_testfile for it, but Level 1 already flagged
                    # it as untagged_spec — suppress the duplicate.
                    if [[ "$reason" == "no_testfile" && "$untagged_ids" == *" $sid "* ]]; then
                        continue
                    fi
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
                        sigkill:*)
                            # Review #2220: a SIGKILL the timer did not send (OOM,
                            # operator) — infra, observable like a timeout.
                            eb_emit_event "acceptance.gate.negctl_sigkill" "stage=acceptance-gate" \
                                "spec_id=${detail#sigkill:}" ;;
                        harness:*)
                            # #1670: the baseline run never reached an assertion,
                            # so it is evidence of nothing. Advisory, like timeout.
                            eb_emit_event "acceptance.gate.negctl_harness_error" "stage=acceptance-gate" \
                                "spec_id=${detail#harness:}" ;;
                    esac
                    ;;
            esac
        done < <(acceptance_negctl_check "$design_md" "$repo_root" || true)
    }

    # ── Level 3: reachability (WIRING load-bearing check) ────────────────────
    # #1220: runs REGARDLESS of Level 1/2 outcome (still gated on a WIRING:
    # section being present) so an inert-wiring violation surfaces in the SAME
    # pass as any Level-1/2 violation.
    local wiring_present=0
    acceptance_list_wiring "$design_md" >/dev/null 2>&1 && wiring_present=1
    if [[ "$wiring_present" -eq 1 ]]; then
        {
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                summary_lines+=("$line")  # #1211: one operator line per WIRING target
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
                    "REACHABILITY FAIL not_passing_at_head "*)
                        # #2109: "<target> <tf>" — the file is red at HEAD, so
                        # no revert can flip it. Same class negctl reports per
                        # SPEC (#2097: recoverable, escalates on iter≥2).
                        local _rest="${line#REACHABILITY FAIL not_passing_at_head }"
                        local _tgt="${_rest%% *}" _tf="${_rest#* }"
                        failures+=("not_passing_at_head:$_tf")
                        verdict="fail"
                        eb_emit_event "acceptance.gate.not_passing_at_head" "stage=acceptance-gate" \
                            "target=$_tgt" "testfile=$_tf" "source=reachability"
                        ;;
                    "REACHABILITY FAIL no_testfiles "*)
                        local _tgt="${line#REACHABILITY FAIL no_testfiles }"
                        failures+=("no_testfiles:$_tgt")
                        verdict="fail"
                        eb_emit_event "acceptance.gate.no_testfiles" "stage=acceptance-gate" \
                            "target=$_tgt"
                        ;;
                    "REACHABILITY FAIL wiring_not_on_path "*)
                        local target="${line#REACHABILITY FAIL wiring_not_on_path }"
                        failures+=("wiring_not_on_path:$target")
                        verdict="fail"
                        eb_emit_event "acceptance.gate.wiring_not_on_path" "stage=acceptance-gate" \
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
                            harness:*)
                                # #2109: the runner could not execute the file
                                # (126/127) — evidence of nothing; advisory.
                                local _h="${detail#harness:}"
                                eb_emit_event "acceptance.gate.reachability_harness_error" "stage=acceptance-gate" \
                                    "target=${_h%% *}" "testfile=${_h#* }" ;;
                        esac
                        ;;
                esac
            done < <(acceptance_reachability_check "$design_md" "$repo_root" || true)
        }
    fi

    # ── Classify + compose operator reason ───────────────────────────────────
    # `disposition` is the GENERIC contract the cycle engine reads (ADR-021): the
    # engine no longer knows this gate's failure vocabulary — it only halts on an
    # explicit disposition==terminal. `reason` (#1220) is the human-readable
    # message that NAMES the offending SPEC ids + class, replacing the opaque
    # member_terminal_failure the cycle otherwise surfaces.
    local failures_json="[]" disposition reason_msg=""
    # The diagnosis reaches the next prompts as this stage's numbered findings
    # and `summary: true` output (ADR-055 §9, #2271).
    # SPEC-vocabulary → generic-field mapping stays HERE (ADR-021). verdict /
    # disposition / rc UNCHANGED.
    # #2161: two words, two fields. `disposition` is ADR-054's closed set —
    # how THIS stage stopped — and the gate reached a conclusion on every one
    # of these paths, so it is `complete` whatever the verdict. The cycle-policy
    # word (`none`/`recoverable`/`advisory`/`terminal`, ADR-021) is `severity`:
    # the orchestrator halts on terminal and the aggregator demotes advisory
    # from there. #1840 run 6 passed all 19 SPECs and the run ended blocked —
    # the pass path wrote `disposition: none` and no `reason`, and the v2
    # reader (verdict.sh) refused it. The fail paths carried the same wrong
    # words and were only ever tolerated because rc≠0 skips the reader.
    local severity="none"
    disposition="complete"
    if [[ ${#failures[@]} -gt 0 ]]; then
        failures_json="$(printf '%s\n' "${failures[@]}" | jq -R . | jq -s .)"
        severity="$(_ag_classify_disposition "${failures[@]}")"
        reason_msg="$(_ag_build_reason "${failures[@]}")"
    fi
    # ADR-054: reason is mandatory; a pass says what it verified. Kept apart
    # from reason_msg, which is the VIOLATION prose the operator summary leads
    # with (#1220) — a pass must not read as a finding there. #2304: it counts
    # each status, so a pass that checked nothing on the old code says so.
    local _pass_reason="the acceptance check passed — ${_ag_n_checked} checked on the old and new code, ${_ag_n_done} already done, ${_ag_n_nocode} no code"
    # #2271 (ADR-068): the gate states its findings; it never decides who fixes
    # them. Every stage answers each finding, and the loops carry what nobody in
    # the build loop owns back to design.

    # ── Operator summary (#1211) ─────────────────────────────────────────────
    # Surface the concise per-check verdict lines the operator actually needs;
    # the raw nested-test replay stays in the negctl/reachability diagnostic logs.
    # #1220: lead with the human reason so the full violation scope is visible.
    if [[ -n "$reason_msg" ]]; then
        if [[ ${#summary_lines[@]} -gt 0 ]]; then
            summary_lines=("$reason_msg" "${summary_lines[@]}")
        else
            summary_lines=("$reason_msg")
        fi
    fi
    # #2124: ADR-055 §9 — written on EVERY path. A block with TESTFILES and no
    # SPEC ids yields no per-check line, and a `summary: true` output is not
    # cleared per iteration, so the previous iteration's file shipped as
    # this one's.
    if [[ ${#summary_lines[@]} -eq 0 ]]; then
        summary_lines=("verdict=$verdict reason=${reason_msg:-no_spec_lines}")
    fi
    if [[ ${#summary_lines[@]} -gt 0 ]]; then
        # #1684: persist BEFORE emitting. The emit above is a write to a terminal
        # fd and is gated on this stage having a stdout destination — on a
        # file-only install it produces nothing at all, and even when it fires it
        # survives only as long as the scrollback. The review lenses and any
        # post-hoc audit of a finished run read artifacts, so without this file
        # the design-vs-assertion pairing is visible to nobody after the run ends.
        mkdir -p "$state_dir/artifacts" 2>/dev/null || true
        printf '%s\n' "${summary_lines[@]}" \
            | atomic_write "$state_dir/artifacts/acceptance-summary.txt"
        _ag_emit_operator_summary "${_stage_id:-acceptance-gate}" "${summary_lines[@]}"
    fi

    # ── Write result artifact ────────────────────────────────────────────────
    # #2271 (ADR-068): each clause of the plain reason — one kind of problem and
    # the SPECs it concerns — is a numbered finding.
    local _ag_fnd="[]"
    if [[ "$verdict" == "fail" && -n "${reason_msg:-}" ]]; then
        local _ag_cl="${reason_msg#the acceptance check failed — }"
        _ag_fnd="$(printf '%s\n' "${_ag_cl//; /$'\n'}" | stage_findings_json)"
    fi
    jq -cn --arg v "$verdict" --arg d "$disposition" --arg sv "$severity" --arg r "${reason_msg:-$_pass_reason}" \
        --argjson f "$failures_json" --argjson fnd "${_ag_fnd:-[]}" \
        '{result_contract:2,verdict:$v,disposition:$d,severity:$sv,reason:$r,failures:$f,data:{findings:$fnd}}' \
        | atomic_write "$result_file"

    eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=$verdict"

    [[ "$verdict" == "fail" ]] && return 1
    return 0
}
