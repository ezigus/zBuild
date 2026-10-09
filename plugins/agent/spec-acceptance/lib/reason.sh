#!/usr/bin/env bash
# plugins/agent/spec-acceptance/lib/reason.sh — the acceptance gate's reason,
# operator summary and small helpers, sourced by plugin.sh. No set -euo pipefail.

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
#   terminal    — ≥1 GENUINE, non-build-fixable violation:
#                 malformed_acceptance_block (design-authored structure / build
#                 cannot fix). OUTRANKS recoverable. An UNKNOWN class is
#                 recoverable + evented, never terminal (#1959).
#   recoverable — build-fixable classes: untagged_spec:*, tautology:*,
#                 inert_wiring:*, not_passing_at_head:* (#1585/#2097 — the
#                 assertion has a model author (test-author, #2022); the cycle
#                 re-iterates with the finding in the stage summaries, the
#                 negative control re-verifies each iteration).
#   advisory    — only infra classes: negctl_error:* / reachability_error:*
#                 (baseline/worktree resolve failures + negctl/reachability
#                 TIMEOUTS — a flaky sandbox must never hard-fail the pipeline).
# Empty failure set → "none". Echoes exactly one token.
_ag_classify_disposition() {
    local f cls had_recoverable=0 had_advisory=0
    for f in "$@"; do
        [[ -n "$f" ]] || continue
        # The table lives in scripts/lib/acceptance-disposition.sh so the lint
        # reads the same rows (#1959). Recoverable: untagged_spec, tautology,
        # inert_wiring (#1585), no_testfile(s) (#2109), not_passing_at_head
        # (#2097), wiring_not_on_path (#1686), unclaimed_code (#2304).
        # Advisory: negctl_error / reachability_error. Terminal:
        # malformed_acceptance_block. A terminal class OUTRANKS recoverable.
        cls="$(_ag_failure_class_disposition "${f%%:*}")"
        case "$cls" in
            terminal)    printf 'terminal'; return 0 ;;
            recoverable) had_recoverable=1 ;;
            advisory)    had_advisory=1 ;;
            *)
                # #1959: a class nobody named RE-ITERATES — max_iterations is
                # the backstop — and says so. The old `*) terminal` halted the
                # whole run on the fifth such class in a row.
                eb_emit_event "acceptance.gate.unknown_failure_class" \
                    "stage=acceptance-gate" "class=${f%%:*}" "failure=$f" 2>/dev/null || true
                had_recoverable=1 ;;
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

# _ag_unreached_where <ids> — "SPEC-3 (the file stopped after SPEC-2), …",
# reading the stop points the NEGCTL lines carried (_ag_unreached_after,
# dynamic scope from acceptance_gate_run).
_ag_unreached_where() {
    local _u _where="" _after
    for _u in $1; do
        _after=""
        if [[ " ${_ag_unreached_after:-} " == *" $_u="* ]]; then
            _after="${_ag_unreached_after##* $_u=}"; _after="${_after%% *}"
        fi
        _where="${_where:+$_where, }$_u${_after:+ (the file stopped after $_after)}"
    done
    printf '%s' "$_where"
}

# _ag_build_reason <failure...> — compose the human-readable operator reason
# (#1220) that NAMES the offending SPEC ids grouped by violation class, so the
# operator sees the FULL scope in one message instead of the opaque
# member_terminal_failure. Repo-agnostic: ids come verbatim from the design's
# acceptance block. Genuine violations lead; infra classes trail.
_ag_build_reason() {
    local f untagged="" taut="" nohead="" notf="" inert="" notpath="" infra="" malformed=0 nofiles="" sig="" unb="" unh=""
    local loadfail="" nothing=""
    local -a unclaimed=()
    for f in "$@"; do
        case "$f" in
            unclaimed_code:*)       unclaimed+=("${f#unclaimed_code:}") ;;
            tautology:*)            taut="$taut ${f#tautology:}" ;;
            not_passing_at_head:*)  nohead="$nohead ${f#not_passing_at_head:}" ;;
            untagged_spec:*)        untagged="$untagged ${f#untagged_spec:}" ;;
            no_testfile:*)          notf="$notf ${f#no_testfile:}" ;;
            no_testfiles:*)         nofiles="$nofiles ${f#no_testfiles:}" ;;
            inert_wiring:*)         inert="$inert ${f#inert_wiring:}" ;;
            wiring_not_on_path:*)   notpath="$notpath ${f#wiring_not_on_path:}" ;;
            unreached_at_base:*)    unb="$unb ${f#unreached_at_base:}" ;;
            unreached_at_head:*)    unh="$unh ${f#unreached_at_head:}" ;;
            killed_by_signal:*)     sig="$sig ${f#killed_by_signal:}" ;;
            malformed_acceptance_block) malformed=1 ;;
            gate_load_failed:*)     loadfail="${f#gate_load_failed:}" ;;
            nothing_checked:*)      nothing="${f#nothing_checked:}" ;;
            negctl_error:* | reachability_error:*) infra="$infra $f" ;;
        esac
    done
    local -a clauses=()
    # #1752: nothing below was checked, so these lead.
    [[ -n "$loadfail" ]] && clauses+=("its own code did not load ($loadfail), so no requirement was checked — this is not a pass")
    [[ -n "$nothing" ]] && clauses+=("the acceptance block lists $nothing requirement(s) and none of them was checked — the check stopped before reporting on any, so this is not a pass")
    # #2163: state the finding, never a remedy addressed to another stage.
    # #2269: each clause says what was tried, what happened, and what to change,
    # in words the reader was given — never the name of the check.
    # #2304 (ADR-069 §5): leads — nothing else matters while code ships with
    # no requirement saying what it must do. At most three files are named.
    if [[ ${#unclaimed[@]} -gt 0 ]]; then
        local _uc_names="${unclaimed[0]}" _uc_i
        for ((_uc_i = 1; _uc_i < ${#unclaimed[@]} && _uc_i < 3; _uc_i++)); do
            _uc_names="$_uc_names, ${unclaimed[$_uc_i]}"
        done
        [[ ${#unclaimed[@]} -gt 3 ]] && _uc_names="$_uc_names and $(( ${#unclaimed[@]} - 3 )) more"
        clauses+=("this change edits code ($_uc_names) but no requirement says what that code must now do — add a [code] requirement with a test")
    fi
    [[ -n "$taut"     ]] && clauses+=("$(_ag_join_ids "$taut"): its test already passes on the code from before this change, so it cannot tell whether the change was made — make it check something the old code gets wrong")
    [[ -n "$nohead"   ]] && clauses+=("$(_ag_join_ids "$nohead"): its test does not pass on the new code — the code or the test is wrong")
    [[ -n "$untagged" ]] && clauses+=("$(_ag_join_ids "$untagged"): no assertion in the test files carries its tag — add one labelled with it")
    [[ -n "$notf"     ]] && clauses+=("$(_ag_join_ids "$notf"): no test file is listed for it under TESTFILES:")
    [[ -n "$inert"    ]] && clauses+=("$(_ag_join_ids "$inert") was put back to its old version and every test still passed, so it is not what runs the new behaviour — name the file whose code calls it, or write WIRING: none")
    [[ -n "$nofiles"  ]] && clauses+=("$(_ag_join_ids "$nofiles"): none of the listed test files exist, so putting it back could not be checked")
    [[ -n "$notpath"  ]] && clauses+=("$(_ag_join_ids "$notpath") is not changed by this change — name a file the change touches, or write WIRING: none")
    [[ -n "$unb" ]] && clauses+=("$(_ag_unreached_where "$unb"): its test never ran on the code from before this change — an earlier step in its test file stops the file there, so it is not shown to fail on the old code")
    [[ -n "$unh" ]] && clauses+=("$(_ag_unreached_where "$unh"): its test never ran on the new code — an earlier step in its test file stops the file before the assertion, so it was not checked")
    [[ -n "$sig"      ]] && clauses+=("$(_ag_join_ids "$sig"): its test file died on a signal before the assertion ran (not a timeout) — usually a test that signals its own process (\$\$) where no handler exists yet; signal a child process instead")
    [[ "$malformed" -eq 1 ]] && clauses+=("the acceptance block could not be read")
    if [[ -n "$infra" ]]; then
        local _i _ib="" _ir=""
        for _i in $infra; do
            case "$_i" in
                negctl_error:*)       _ib="$_ib ${_i#negctl_error:}" ;;
                reachability_error:*) _ir="$_ir ${_i#reachability_error:}" ;;
            esac
        done
        [[ -n "$_ib" ]] && clauses+=("the run of $(_ag_join_ids "$_ib")'s test on the code from before this change could not be done (a problem in the pipeline, not in your change)")
        [[ -n "$_ir" ]] && clauses+=("putting $(_ag_join_ids "$_ir") back to its old version could not be done (a problem in the pipeline, not in your change)")
    fi
    local out="" c
    for c in ${clauses[@]+"${clauses[@]}"}; do
        if [[ -z "$out" ]]; then out="$c"; else out="$out; $c"; fi
    done
    printf 'the acceptance check failed — %s' "$out"
}

# The lib functions acceptance_gate_run calls. One undefined after loading means
# a lib did not load whole; the gate must not grade with what is left (#1752).
_AG_REQUIRED_FNS=(
    extract_acceptance_block acceptance_list_spec_ids acceptance_list_testfiles
    acceptance_list_testfiles_for_spec acceptance_spec_desc
    acceptance_find_assertion_label acceptance_list_wiring
    acceptance_unclaimed_code_check acceptance_coverage_check
    acceptance_negctl_check acceptance_reachability_check
    zbuild_resolve_merge_base _acceptance_file_timeout
)

# _ag_load_problems — print what of the gate's code did not load: the files a
# `source` failed on (recorded in _ZBUILD_CONTRACT_LOAD_ERRORS by plugin.sh and
# the libs) and the required functions that are undefined. Empty = all loaded.
_ag_load_problems() {
    local out="" f
    for f in ${_ZBUILD_CONTRACT_LOAD_ERRORS:-}; do
        [[ " $out " == *" $f "* ]] || out="${out:+$out }$f"
    done
    for f in "${_AG_REQUIRED_FNS[@]}"; do
        declare -F "$f" >/dev/null 2>&1 || out="${out:+$out }$f()"
    done
    printf '%s' "$out"
}

# _ag_fail_load <result_file> <problems> — the gate could not load its code:
# write a failing result that says so (ADR-036 amendment 2026-10-09). `broken`:
# the gate could not do its work, whatever the change is.
_ag_fail_load() {
    local result_file="$1" problems="$2"
    local failures_json reason fnd
    failures_json="$(printf 'gate_load_failed:%s\n' $problems | jq -R . | jq -sc .)"
    reason="$(_ag_build_reason "gate_load_failed:${problems// /, }")"
    fnd="$(printf '%s\n' "${reason#the acceptance check failed — }" | stage_findings_json)"
    jq -cn --arg r "$reason" --argjson f "$failures_json" --argjson fnd "${fnd:-[]}" \
        '{result_contract:2,verdict:"fail",disposition:"broken",severity:"terminal",reason:$r,failures:$f,data:{findings:$fnd}}' \
        | atomic_write "$result_file"
    printf 'verdict=fail\nreason=%s\n' "$reason" \
        | atomic_write "$(dirname "$result_file")/acceptance-summary.txt"
    eb_emit_event "acceptance.gate.load_failed" "stage=acceptance-gate" "missing=$problems"
    eb_emit_event "acceptance.gate.complete" "stage=acceptance-gate" "verdict=fail"
}

# _ag_noop_precondition_unmet <result_file> <precondition_id> — write the no-op
# pass artifact + emit the skip/complete events. reason=precondition_unmet
# generalizes the historical no-acceptance-block skip: when a declared
# `preconditions` (manifest) is unmet, the SPEC methodology does not apply, so
# the gate no-ops instead of hard-failing — this is what makes it safe to
# compose into repos that do not use SPEC.
_ag_noop_precondition_unmet() {
    local result_file="$1" pc="$2"
    printf '{"result_contract":2,"verdict":"pass","reason":"precondition_unmet","precondition":"%s","disposition":"complete","severity":"none","failures":[]}\n' \
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
