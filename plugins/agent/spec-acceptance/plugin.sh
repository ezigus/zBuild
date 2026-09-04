#!/usr/bin/env bash
# plugins/agent/spec-acceptance — SPEC acceptance-contract gate (ADR-036, #922/#956)
#
# Method-named plugin (id: spec-acceptance) bound to the GENERIC `acceptance_gate`
# role: it implements ONE strategy — SPEC-block negative-control + wiring
# reachability — for verifying a design's acceptance contract. A different repo
# may bind a different plugin to the same role without adopting SPEC.
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
# Preconditions (manifest `preconditions`): when any is unmet the gate NO-OPS
# (verdict=pass, reason=precondition_unmet) so it is safe to compose into repos
# that do not use the SPEC methodology. No model call.

# Size (CLAUDE.md "under 500 lines unless there is a strong reason"): over, and
# left that way. The file is one contract end to end — SPEC failure vocabulary →
# disposition → reason → fault — and ADR-021 puts that mapping HERE
# precisely so the cycle engine stays generic and knows none of this gate's
# vocabulary. Splitting it would scatter one mapping across two files for a line
# count, which is how the engine learned a plugin's vocabulary in the first place.

[[ -n "${_ZBUILD_ACCEPTANCE_GATE_LOADED:-}" ]] && return 0
_ZBUILD_ACCEPTANCE_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_AG_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_AG_ROOT/core/event-bus/event-bus.sh"
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
#   terminal    — ≥1 GENUINE, non-build-fixable violation: not_passing_at_head,
#                 no_testfile, malformed_acceptance_block (design-authored / build
#                 cannot fix). OUTRANKS recoverable.
#   recoverable — build-fixable classes: untagged_spec:*, tautology:*,
#                 inert_wiring:* (#1585 — build owns the assertions since #1477;
#                 the cycle re-iterates and feeds these back to build via the
#                 #951 edge, the negative control re-verifies each iteration).
#   advisory    — only infra classes: negctl_error:* / reachability_error:*
#                 (baseline/worktree resolve failures + negctl/reachability
#                 TIMEOUTS — a flaky sandbox must never hard-fail the pipeline).
# Empty failure set → "none". Echoes exactly one token.
_ag_classify_disposition() {
    local f had_recoverable=0 had_advisory=0
    for f in "$@"; do
        case "$f" in
            # BUILD-FIXABLE classes → recoverable: the build_test_cycle re-iterates
            # and feeds the failure to build (which owns the assertion bodies since
            # #1477). #1585: tautology + inert_wiring join untagged_spec here — they
            # are the same "weak test" symptom (a [change] assertion that passes at
            # baseline / a WIRING file whose revert breaks no test) that BUILD fixes
            # by re-authoring the assertion (#1583). The mechanical negative control
            # re-verifies each iteration, and max_iterations bounds it — an
            # un-fixable case exhausts the budget and terminates cleanly.
            untagged_spec:* | tautology:* | inert_wiring:*)  had_recoverable=1 ;;
            # #1686: design-rooted, but NOT terminal — the cycle must reach the
            # gate-aggregator for the declared fault to drive the rewind
            # and fire the route_back edge. Terminal would halt before the rewind.
            wiring_not_on_path:*)                           had_recoverable=1 ;;
            # #1670: a guard assertion that fails at the merge-base is the same
            # "weak test" symptom as tautology (#1583) — the assertion, not the
            # design, is what is wrong — so it routes to build for re-authoring
            # rather than halting the cycle. Terminal would strand it: no rewind
            # edge exists for the class, so the run could only die at max_iterations.
            guard_regressed:*)                               had_recoverable=1 ;;
            negctl_error:* | reachability_error:*)           had_advisory=1 ;;
            "")                                              : ;;
            # Genuinely terminal (e.g. malformed_acceptance_block — design-authored,
            # build cannot fix): halt the cycle. A terminal class OUTRANKS recoverable.
            *)                                               printf 'terminal'; return 0 ;;
        esac
    done
    if [[ $had_recoverable -eq 1 ]]; then printf 'recoverable'; return 0; fi
    if [[ $had_advisory   -eq 1 ]]; then printf 'advisory';    return 0; fi
    printf 'none'
}

# _ag_join_ids <ids...> — compact "/"-join of a whitespace-separated id list,
# e.g. " SPEC-1 SPEC-8 " → "SPEC-1/SPEC-8" (word-splitting collapses spacing).
_ag_join_ids() {
    local out="" id
    for id in $1; do
        [[ -z "$id" ]] && continue
        if [[ -z "$out" ]]; then out="$id"; else out="$out/$id"; fi
    done
    printf '%s' "$out"
}

# _ag_build_reason <failure...> — compose the human-readable operator reason
# (#1220) that NAMES the offending SPEC ids grouped by violation class, so the
# operator sees the FULL scope in one message instead of the opaque
# member_terminal_failure. Repo-agnostic: ids come verbatim from the design's
# acceptance block. Genuine violations lead; infra classes trail.
_ag_build_reason() {
    local f untagged="" taut="" nohead="" notf="" inert="" notpath="" infra="" malformed=0 grd=""
    for f in "$@"; do
        case "$f" in
            tautology:*)            taut="$taut ${f#tautology:}" ;;
            not_passing_at_head:*)  nohead="$nohead ${f#not_passing_at_head:}" ;;
            untagged_spec:*)        untagged="$untagged ${f#untagged_spec:}" ;;
            no_testfile:*)          notf="$notf ${f#no_testfile:}" ;;
            inert_wiring:*)         inert="$inert ${f#inert_wiring:}" ;;
            wiring_not_on_path:*)   notpath="$notpath ${f#wiring_not_on_path:}" ;;
            guard_regressed:*)      grd="$grd ${f#guard_regressed:}" ;;
            malformed_acceptance_block) malformed=1 ;;
            negctl_error:* | reachability_error:*) infra="$infra $f" ;;
        esac
    done
    local -a clauses=()
    [[ -n "$taut"     ]] && clauses+=("$(_ag_join_ids "$taut") tautological (pass at baseline) — re-author the assertions")
    [[ -n "$nohead"   ]] && clauses+=("$(_ag_join_ids "$nohead") not passing at HEAD — fix the implementation or the assertion")
    [[ -n "$untagged" ]] && clauses+=("$(_ag_join_ids "$untagged") untagged — add a matching [SPEC-n] assertion in TESTFILES")
    [[ -n "$notf"     ]] && clauses+=("$(_ag_join_ids "$notf") missing a tagged TESTFILE")
    [[ -n "$inert"    ]] && clauses+=("WIRING $(_ag_join_ids "$inert") inert — reverting it breaks no TESTFILE")
    [[ -n "$notpath"  ]] && clauses+=("WIRING $(_ag_join_ids "$notpath") not in this commit's diff — declare WIRING: none or name a file this change actually touches")
    [[ -n "$grd"      ]] && clauses+=("$(_ag_join_ids "$grd") tagged as [guard] but the assertion FAILS at the merge-base — a guard must hold there by definition, so either the assertion contradicts its SPEC text or the SPEC is a mislabelled [change]")
    [[ "$malformed" -eq 1 ]] && clauses+=("acceptance block malformed")
    [[ -n "$infra"    ]] && clauses+=("infra: $(_ag_join_ids "$infra")")
    local out="" c
    for c in ${clauses[@]+"${clauses[@]}"}; do
        if [[ -z "$out" ]]; then out="$c"; else out="$out; $c"; fi
    done
    printf 'acceptance SPEC violations — %s' "$out"
}

# _ag_noop_precondition_unmet <result_file> <precondition_id> — write the no-op
# pass artifact + emit the skip/complete events. reason=precondition_unmet
# generalizes the historical no-acceptance-block skip: when a declared
# `preconditions` (manifest) is unmet, the SPEC methodology does not apply, so
# the gate no-ops instead of hard-failing — this is what makes it safe to
# compose into repos that do not use SPEC.
_ag_noop_precondition_unmet() {
    local result_file="$1" pc="$2"
    printf '{"result_contract":2,"verdict":"pass","reason":"precondition_unmet","precondition":"%s","disposition":"none","failures":[]}\n' \
        "$pc" | atomic_write "$result_file"
    local _summary_dir; _summary_dir="$(dirname "$result_file")"
    printf 'verdict=pass\nreason=precondition_unmet\nprecondition=%s\n' "$pc" \
        | atomic_write "${_summary_dir}/acceptance-summary.txt"
    eb_emit_event "acceptance.gate.skipped" "stage=acceptance-gate" "reason=precondition_unmet" "precondition=$pc"
    eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=pass"
}

# _ag_emit_operator_summary <stage_id> <verdict_line>... — surface the concise
# per-check verdict lines (NEGCTL/REACHABILITY PASS/FAIL/…, one per SPEC and per
# WIRING target) to the operator via this stage's own stage-io stdout channel
# (ADR-039 file-only-child + summary; ADR-036 §Operator-summary, #1211). The
# nested TESTFILE replay is captured to the negctl/reachability diagnostic logs
# (off the terminal, #1211); the operator sees ONLY this one-line-per-check
# readout. io-gated on this stage's destinations so a file-only install stays
# quiet, and routed to ZBUILD_STAGE_IO_FD (default fd 2) — never fd 1 (would
# collide with the action's $() capture).
_ag_emit_operator_summary() {
    local stage_id="$1"; shift
    [[ $# -eq 0 ]] && return 0
    declare -F template_stage_io_dests >/dev/null 2>&1 || return 0
    local dests; dests="$(template_stage_io_dests "$stage_id" 2>/dev/null || true)"
    grep -qx stdout <<< "$dests" || return 0
    local io_fd="${ZBUILD_STAGE_IO_FD:-2}"
    # #1241: mechanical-gate stages open no router/command stage-io span, so this
    # summary otherwise dangled after the preceding stage's ── end stage-io ──.
    # Wrap it in a real stage-io span (kind=computed) so it renders inside its own
    # ── stage-io: <stage> ── / ── end stage-io: <stage> ── frame. begin/end are
    # called DIRECTLY (not via $()) so the pending-state mutation persists in this
    # shell — `>/dev/null` suppresses only the seq on fd 1 (which would collide
    # with the action's $() capture); the banner stays on ZBUILD_STAGE_IO_FD.
    local _framed=0 _seq=""
    if declare -F stage_io_begin >/dev/null 2>&1 && declare -F stage_io_end >/dev/null 2>&1; then
        stage_io_begin --stage "$stage_id" --kind computed \
            --input "contract summary ($# checks)" >/dev/null || true
        _seq="${_STAGE_IO_LAST_SEQ:-}"
        [[ -n "$_seq" ]] && _framed=1
    fi
    # shellcheck disable=SC2261
    {
        printf 'acceptance-gate — contract summary:\n'
        printf '  %s\n' "$@"
    } >&"$io_fd" 2>/dev/null || true
    if [[ "$_framed" == "1" ]]; then
        stage_io_end --stage "$stage_id" --kind computed --seq "$_seq" \
            --output "contract summary: $# checks" --exit-code 0 >/dev/null || true
    fi
    return 0
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
        printf '{"result_contract":2,"verdict":"fail","reason":"malformed_acceptance_block","disposition":"terminal","failures":["malformed_acceptance_block"]}\n' \
            | atomic_write "$result_file"
        printf 'verdict=fail\nreason=malformed_acceptance_block\n' \
            | atomic_write "$artifact_dir/acceptance-summary.txt"
        eb_emit_event "acceptance.gate.untagged_spec" "stage=acceptance-gate" "reason=malformed_acceptance_block"
        eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=fail"
        return 1
    fi

    # ── Precondition 2: git merge-base resolvable ────────────────────────────
    # The negative control and reachability revert need a baseline (origin/main |
    # main | HEAD~1). A shallow/non-git checkout cannot support them; no-op rather
    # than hard-fail (a baseline-resolve miss is already an advisory disposition).
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
    # #1211: one concise verdict line per SPEC (negctl) / per WIRING target
    # (reachability), surfaced to the operator after the checks run.
    local -a summary_lines=()
    local line
    # #1220: SPEC ids flagged untagged at Level 1, so Level 2 can suppress the
    # redundant no_testfile it would emit for the SAME id (one root cause, one
    # report). Space-delimited set (" SPEC-1 SPEC-2 ") — membership via glob
    # pattern `*" $sid "*`; simpler than declare -A for a small id set.
    local untagged_ids=" "

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
    # a tautological [change] SPEC) is reported in the SAME pass — no whack-a-mole.
    {
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Enrich NEGCTL PASS/FAIL/SKIP lines with SPEC desc and assertion label (#1684)
            local _e_enriched="$line" _e_eid=""
            if [[ "$line" =~ ^NEGCTL\ (PASS|FAIL|SKIP)\ (SPEC-[0-9]+) ]]; then
                _e_eid="${BASH_REMATCH[2]}"
            # #1715: the SPEC id rides in the detail token after the colon, not
            # as a standalone word, so the leading regex cannot capture it.
            elif [[ "$line" =~ ^NEGCTL\ ERROR\ timeout:(SPEC-[0-9]+) ]]; then
                _e_eid="${BASH_REMATCH[1]}"
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
                "NEGCTL PASS "*) : ;;  # control confirmed
                "NEGCTL SKIP "*) : ;;  # no_impl_delta — legitimate skip
                "NEGCTL FAIL "*)
                    # "NEGCTL FAIL <spec_id> <reason>"
                    local rest="${line#NEGCTL FAIL }"
                    local sid="${rest%% *}" reason="${rest#* }"
                    # #1220: an untagged SPEC necessarily has no tagged testfile;
                    # negctl reports no_testfile for it, but Level 1 already flagged
                    # it as untagged_spec — suppress the duplicate.
                    if [[ "$reason" == "no_testfile" && "$untagged_ids" == *" $sid "* ]]; then
                        continue
                    fi
                    failures+=("$reason:$sid")
                    verdict="fail"
                    # #1670: guard verdicts ride the same "<spec_id> <reason>"
                    # shape as every other FAIL line, so only the event differs.
                    if [[ "$reason" == "guard_regressed" ]]; then
                        eb_emit_event "acceptance.gate.guard_regressed" "stage=acceptance-gate" \
                            "spec_id=$sid"
                    else
                        eb_emit_event "acceptance.gate.tautology" "stage=acceptance-gate" \
                            "spec_id=$sid" "reason=$reason"
                    fi
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
    # #1583 (supersedes #1219): tautology is now BUILD-FIXABLE, NOT design-rooted.
    # Since #1477 removed design's stub-writer, BUILD authors every test assertion
    # body — so a tautological [change] SPEC (assertion passes at the merge-base
    # baseline) can only be fixed by build re-authoring its own assertion. The gate
    # therefore declares NO specification fault for tautology: it flows through the existing
    # gate_feedback → build edge and stays in build_test_cycle, with the gate-
    # aggregator surfacing the per-SPEC negctl diagnosis so build knows precisely
    # what to fix. Re-authoring is safe by construction — the mechanical negative
    # control re-runs next iteration and rejects a still-tautological result. NO
    # terminal class currently declares a fault; the carrier is
    # retained (absent-when-empty) for any future genuinely design-rooted class.
    # SPEC-vocabulary → generic-field mapping stays HERE (ADR-021). verdict /
    # disposition / rc UNCHANGED.
    local fault=""
    if [[ ${#failures[@]} -gt 0 ]]; then
        failures_json="$(printf '%s\n' "${failures[@]}" | jq -R . | jq -s .)"
        disposition="$(_ag_classify_disposition "${failures[@]}")"
        reason_msg="$(_ag_build_reason "${failures[@]}")"
    else
        disposition="none"
    fi
    # #1987: these three classes are all "the SPECIFICATION is wrong" — the
    # declaration, the classification, or the wiring the design asserted. The
    # gate knows THAT much about its own failure; it does not name the stage
    # that fixes it (ADR-055's rule for data, applied to control).
    #
    # ADR-036 #1583: only design can fix a WIRING declaration, so the failure
    # must not be blamed on build.
    local f
    for f in "${failures[@]:-}"; do
        [[ "$f" == wiring_not_on_path:* ]] && fault="specification" && break
    done
    # #1777: guard_regressed is design-rooted by construction. Build cannot fix a
    # SPEC tagged [guard] whose assertion asserts a change — the correction is
    # the tag (or the assertion), and both live in the design. Without a
    # declared fault the failure landed in the gate-aggregator's residual[]
    # partition and was written to the BUILD-facing gate-feedback.md, so on #1809
    # the run rewound to design carrying a design-feedback.md that named only
    # shape-floor and never mentioned the offending SPEC. Design re-authored
    # nothing, build re-ran, and the same guard failed again.
    #
    # Disposition stays recoverable: terminal would halt the cycle before the
    # aggregator reads the fault and routes on it (same rationale as
    # #1686/#1711 above).
    if [[ -z "$fault" ]]; then
        for f in "${failures[@]:-}"; do
            if [[ "$f" == guard_regressed:* ]]; then
                fault="specification"
                break
            fi
        done
    fi
    # #1711: inert_wiring on iter≥2 is a specification fault. The first build
    # attempt (iter=1) is preserved as a real try; a still-inert target on
    # iter≥2 is unreachable by build and the declaration itself is wrong.
    # Disposition stays recoverable — terminal would halt before the aggregator
    # reads the fault (same rationale as #1686).
    if [[ -z "$fault" && "${ZBUILD_CYCLE_ITER:-1}" -ge 2 ]]; then
        for f in "${failures[@]:-}"; do
            if [[ "$f" == inert_wiring:* ]]; then
                fault="specification"
                eb_emit_event "acceptance.gate.inert_wiring_escalated" \
                    "stage=acceptance-gate" \
                    "target=${f#inert_wiring:}" "iter=${ZBUILD_CYCLE_ITER:-1}"
                break
            fi
        done
    fi

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
    # #1219/#1987: add the declared fault class ONLY when set. An absent fault
    # on a failing gate means "fixed where it was found" is not yet declared —
    # the lint refuses that, so absence here is never silently a routing answer.
    # `--arg rt ""` + a `(if $rt=="" ...)` conditional keeps it absent otherwise,
    # so a build-fixable failure's artifact is byte-shape-identical to today.
    if [[ -n "$reason_msg" ]]; then
        jq -cn --arg v "$verdict" --arg d "$disposition" --arg r "$reason_msg" \
            --arg ft "$fault" --argjson f "$failures_json" \
            '{result_contract:2,verdict:$v,disposition:$d,reason:$r,failures:$f}
             + (if $ft=="" then {} else {fault:$ft} end)' | atomic_write "$result_file"
    else
        jq -cn --arg v "$verdict" --arg d "$disposition" \
            --arg ft "$fault" --argjson f "$failures_json" \
            '{result_contract:2,verdict:$v,disposition:$d,failures:$f}
             + (if $ft=="" then {} else {fault:$ft} end)' | atomic_write "$result_file"
    fi

    eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=$verdict"

    [[ "$verdict" == "fail" ]] && return 1
    return 0
}
