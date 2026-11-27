#!/usr/bin/env bash
# plugins/agent/review-lens — ONE advisory review lens as an isolated LLM stage.
#
# ADR-040 §3 (EPIC #1129 C1). Each advisory lens becomes its own first-class
# `kind: agent` stage so lenses are add/subtract-able and run as members of the
# ADR-039 `aggregate: advisory` parallel group. This evolves ADR-038's hand-rolled
# single-stage fan-out into composable lens stages while preserving its core
# discipline: ONE isolated LLM call per lens (ADR-038 §2 — not one prompt with N
# sections), fed redacted evidence through the ADR-004 chokepoint.
#
# Advisory only: a failed/unparseable lens degrades to an empty normalized result
# and the stage still returns 0 — a lens never blocks merge (ADR-040 §4).
#
# ADR refs: ADR-001 (plugin contract), ADR-003/017 (models-as-data, per-stage
#           tier), ADR-004 (redaction chokepoint), ADR-018 (JSON envelope),
#           ADR-038 (lens content + isolated-call), ADR-040 (lens taxonomy).

[[ -n "${_ZBUILD_REVIEW_LENS_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-summary.sh"
# #2366: the one writer of a stage's result (contract 3).
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-result.sh"
_RL_DIR="$_ZBUILD_PLUGIN_DIR"
_RL_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_RL_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_RL_ROOT/core/router/route.sh"
# ADR-028: shared LLM-agent framework (schema-gated reply parser, envelope parse).
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_RL_ROOT/scripts/lib/llm-agent.sh"
# shellcheck source=../../../scripts/lib/test-paths.sh
source "$_RL_ROOT/scripts/lib/test-paths.sh"
# shellcheck source=./lib/unchecked.sh
source "${BASH_SOURCE[0]%/*}/lib/unchecked.sh"
# #896/#952: shared merge-base change-bundle resolver — the lens judges the same
# full-branch diff as `review`, not the (often empty) incremental build diff.patch.
# shellcheck source=../../../scripts/lib/merge-base.sh
source "$_RL_ROOT/scripts/lib/merge-base.sh"
# shellcheck source=../../../scripts/lib/judge.sh
source "$_RL_ROOT/scripts/lib/judge.sh"
# #721: strip stage-io banners and ANSI from input before the LLM prompt.
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_RL_ROOT/scripts/lib/test-output-sanitize.sh"
# ADR-050 (#1581): unified prior-work seam — seed from this lens's prior finding.
# shellcheck source=../../../scripts/lib/prior-output-reader.sh
source "$_RL_ROOT/scripts/lib/prior-output-reader.sh"
# #2364: earlier work is found by what it contains, never by which stage made it.
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_RL_ROOT/scripts/lib/earlier-output.sh"
# extract_acceptance_block: the SPECs a lens judges the change against.
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_RL_ROOT/scripts/lib/acceptance-block.sh"
# registry.sh is idempotent (guard flag).
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_RL_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=lib/charters.sh
source "$_RL_DIR/lib/charters.sh"
# The code its findings' ids take.
# shellcheck source=lib/codes.sh
source "$_RL_DIR/lib/codes.sh"
# shellcheck source=lib/check.sh
source "$_RL_DIR/lib/check.sh"
# shellcheck source=lib/unclear.sh
source "$_RL_DIR/lib/unclear.sh"
# #2571: split from this file to keep it under 500 lines.
# shellcheck source=lib/reply.sh
source "$_RL_DIR/lib/reply.sh"
# shellcheck source=lib/result.sh
source "$_RL_DIR/lib/result.sh"
# shellcheck source=lib/context.sh
source "$_RL_DIR/lib/context.sh"

# ─── review_lens_run ──────────────────────────────────────────────────────────
# Hook: review_lens_run(stage, state_file). Derives the lens id + artifact paths
# and delegates to the unit-testable inner function.
review_lens_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "review_lens_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/lens-${ZBUILD_REVIEW_LENS_ID}-summary.md}" "review-lens" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    local lens; lens="$(_review_lens_id)"
    if [[ -z "$lens" ]]; then
        lens="${1#review-lens-}"; lens="${lens#lens-}"; lens="${lens#lens_}"
    fi
    [[ -n "$lens" ]] || lens="correctness"

    # #896/#952: every lens judges the whole branch's change, from the commit
    # it started from (the round's diff.patch when no base resolves) — the same
    # change for every lens, as for any stage.
    _review_lens_run_inner \
        "$lens" \
        "$(earlier_scope_manifest "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)" \
        "$(earlier_change_patch "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)" \
        "$artifact_dir/lens-$lens.json" \
        "$artifact_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args: $1=lens  $2=scope_manifest  $3=the round's patch, read only when no
#       starting commit is known  $4=out lens-<name>.json
#       $5=(optional) artifact dir for the intermediate redacted prompt
_review_lens_run_inner() {
    local IFS=$' \t\n'   # item lists split on blanks, whatever the caller's IFS
    # $2 (the scope manifest) is the redaction allow-list, not the plan; there
    # is no planned scope since #2508 (design names no files).
    # Redaction of the assembled prompt is the router's, by construction (ADR-043).
    local lens="$1" evidence="$3" out="$4"
    local artifact_dir="${5:-$(dirname "$out")}"
    # #2630 (ADR-040): a suspicion sends the change round once. What this lens
    # routed earlier in this run (written after the run started) says which it
    # sent already: read by the shell, first — a try clears its outputs by topic.
    _RL_PRIOR_SENT=""
    local _rl_one _rl_pf _rl_mark="${ZBUILD_RUN_START_MARKER:-${artifact_dir%/*}/runtime/run-start}"
    if [[ -e "$_rl_mark" ]]; then
        for _rl_pf in "${out%.json}-code-result.json" "${out%.json}-test-result.json" "${out%.json}-design-result.json"; do
            [[ -s "$_rl_pf" && ! "$_rl_mark" -nt "$_rl_pf" ]] || continue
            _rl_one=""; IFS= read -r -d '' _rl_one < "$_rl_pf" || true; _RL_PRIOR_SENT+="$_rl_one"
        done
    fi

    if [[ -z "$lens" || -z "$out" ]]; then
        error "_review_lens_run_inner: requires <lens> <scope_manifest> <evidence> <out>"
        return 2
    fi
    mkdir -p "$artifact_dir"
    # #2571 (ADR-038): the questions the lens's last result carries, for this call to judge.
    _rl_unclear_carried_load "$out"
    # ADR-068 §6: last time's findings, with what was answered, are read
    # before they are cleared, to show the lens.
    local _rl_last=""
    judge_last_findings_block_v _rl_last "$artifact_dir" "lens-${lens}-code" "${out%.json}-code-result.json" \
        "lens-${lens}-test" "${out%.json}-test-result.json" \
        "lens-${lens}-design" "${out%.json}-design-result.json"
    local _rl_fc="" _rl_w
    _rl_lens_code_ok_v _rl_fc "$lens" "$out" || return 0
    # A round's routed findings are this round's only (#2433); rm only when one is there.
    local -a _rl_old=(); for _rl_w in code test design; do [[ -e "${out%.json}-$_rl_w-result.json" ]] && _rl_old+=("${out%.json}-$_rl_w-result.json"); done
    [[ ${#_rl_old[@]} -gt 0 ]] && { rm -f "${_rl_old[@]}" 2>/dev/null || true; }

    # #2507 (ADR-072 §7): the lens is pointed at the change — the commit the
    # branch started from and the files it changed — and reads it with git.
    # ADR-043: the router redacts the assembled prompt by construction.
    local _rl_change="" _rl_cfp="" _rl_patch=""
    zbuild_change_files_v _rl_change _rl_cfp "$evidence" "${ZBUILD_REPO_ROOT:-$PWD}"
    local _rl_base="$_ZB_CHANGE_BASE"
    # The round's patch is part of the change: a quote of a line it removed is
    # found there too.
    [[ -n "$evidence" && -s "$evidence" ]] && { IFS= read -r -d '' _rl_patch < "$evidence" || true; }

    # ─── Build the single-lens prompt ──────────────────────────────────────
    # #2548 (ADR-038): a lens with no job of its own reviews nothing.
    local _rl_job=""
    if ! _rl_lens_job_v _rl_job "$lens"; then
        _review_lens_write_result "$out" misconfigured "the ${lens} lens has no job text, so it reviewed nothing"
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "the ${lens} lens has no job text (plugins/agent/review-lens/lenses/${lens}.md), so it reviewed nothing" \
            "Advisory lens: no findings were produced. Absence here is not evidence of a clean change."
        return 0
    fi
    local prompt _rl_uqb=""; prompt="$(_rl_build_lens_prompt "$lens" "$_rl_change" "$(_rl_context)")"
    _rl_unclear_block_v _rl_uqb; prompt+="$_rl_uqb"
    # #2584 (ADR-072 §4 §5): a lens keeps no verdict and holds no pass — every
    # round reviews the whole change, and every finding it gives is taken.

    # ADR-067 §8: the lens's three parts and the engine's blocks — its budget
    # among the engine's rules — in the one prompt order.
    local _composed
    # #2458: it judges, so it composes fresh — no notes, and no rule to confirm earlier work.
    if ! _composed="$(stage_prompt_compose_parts --fresh "$prompt")"; then
        _review_lens_write_result "$out" misconfigured "the prompt could not be composed, so this lens reviewed nothing"
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "the prompt could not be composed, so this lens reviewed nothing" \
            "Advisory lens: no findings were produced. Absence here is not evidence of a clean change."
        return 0
    fi
    prompt="$_composed"

    # ─── ONE route_to_model call (ADR-017 per-stage tier; ADR-003 by tier) ──
    # ADR-018 Pattern 1: JSON envelope mode so reasoning turns don't leak as a
    # prose preamble that breaks the strict-JSON parse. Save/restore the env so
    # an outer caller's intent is preserved.
    local tier; tier="$(resolve_tier review-lens "$_RL_DIR")" || return 1
    local raw_response="" router_rc=0
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    export ZBUILD_ROUTER_ARTIFACT_ID="review-lens"
    # ADR-063 §3: register interrupt handler so disposition:interrupted is written
    # if the model call is cut short by SIGTERM or SIGINT (SPEC-13).
    _rl_out_ref="$out"
    _rl_interrupted=0
    stage_signal_begin _review_lens_interrupt_handler
    # ADR-060 §6: a reply that cannot be used is asked again once, at once,
    # with what was wrong and the reply. A failed call is not (ADR-040: a lens
    # that does not finish stops the run). Every reply is kept, in order.
    local _rl_ask="$prompt" _rl_problem="" _rl_try json="" _rl_salvage="" _rl_first="" _rl_bad_idx=""
    local _rl_replies="${out%.json}-reply.txt"
    : > "$_rl_replies" 2>/dev/null || true
    local _rl_repo="${ZBUILD_REPO_ROOT:-$PWD}"
    [[ -n "$_rl_last" ]] && { prompt+="$_rl_last"; _rl_ask="$prompt"; }
    for _rl_try in 1 2; do
        raw_response=""; router_rc=0; _rl_problem=""
        raw_response="$(route_to_model "$tier" "$_rl_ask")" || router_rc=$?
        printf -- '--- reply %s ---\n%s\n' "$_rl_try" "$raw_response" >> "$_rl_replies" 2>/dev/null || true
        # A signal that landed during the call ends the lens here (review on #2434).
        [[ $router_rc -eq 0 && -n "$raw_response" && "${_rl_interrupted:-0}" != "1" ]] || break
        _rl_reply_problem "$raw_response" json _rl_problem
        _rl_reask_merge
        # ADR-072 §3: every finding quotes the text that shows it.
        [[ -z "$_rl_problem" ]] && _rl_quote_problem_v _rl_problem "$json" "$_rl_base" "$_rl_repo" "$_rl_patch"
        _rl_unchecked_settle
        # #2571: each question in the one form, each carried one answered —
        # asked again once, then costing only that question: the report is kept.
        if [[ -z "$_rl_problem" && $_rl_try -eq 1 ]]; then
            _rl_unclear_problem_v _rl_problem "$json"; [[ -n "$_rl_problem" ]] && _rl_salvage="$json"
        fi
        [[ -z "$_rl_problem" ]] && break
        json=""
        _rl_ask="$(stage_prompt_reask "$prompt" "$_rl_problem" "$raw_response")"
    done
    if [[ -z "$json" && -n "$_rl_salvage" && $router_rc -eq 0 && "${_rl_interrupted:-0}" != "1" ]]; then
        json="$_rl_salvage"; raw_response="$_rl_salvage"; _rl_problem=""
    fi
    if [[ "$_prev_json_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_JSON_OUTPUT
    else
        export ZBUILD_ROUTER_JSON_OUTPUT="$_prev_json_env"
    fi
    if [[ "$_prev_artifact_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_ARTIFACT_ID
    else
        export ZBUILD_ROUTER_ARTIFACT_ID="$_prev_artifact_env"
    fi

    # rc=130 (SIGINT propagated through subshell) — distinct from advisory rc=0
    # degrade paths; write interrupted disposition and propagate the signal code.
    if [[ "$router_rc" -eq 130 || "${_rl_interrupted:-0}" == "1" ]]; then
        stage_signal_end
        [[ "${_rl_interrupted:-0}" == "1" ]] \
            || _review_lens_write_result "$out" interrupted "signal_interrupt"
        return 130
    fi
    stage_signal_end

    # rc=10 (budget/turn exhaustion — ADR-063 §3): distinct from advisory rc=0
    # degrade paths. Write disposition:out_of_turns and propagate rc=10 so the engine
    # can apply the §3 escalation (disposition.sh:97 → route.sh:749 +50% retry).
    if [[ "$router_rc" -eq 10 ]]; then
        _review_lens_write_result "$out" out_of_turns "budget_exhausted" \
            "$(_review_lens_saved_notes "$artifact_dir")"
        return 10
    fi

    # ─── Parse + normalize into {result_contract, schema_version, name, score, findings[]} ───
    # A failed or unparseable lens degrades to empty (advisory — never fatal).
    if [[ $router_rc -ne 0 || -z "$raw_response" ]]; then
        emit_event "review_lens.failed" "lens=$lens" "router_rc=$router_rc"
        local _rl_v="" _rl_r="" _rl_disp _rl_notes _rl_head _rl_body
        _router_rc_classify "$router_rc" _rl_v _rl_r 2>/dev/null || true
        _rl_disp="$(router_reason_disposition "${_rl_r:-router_rc_nonzero}")"
        _rl_notes="$(_review_lens_saved_notes "$artifact_dir")"
        _review_lens_write_result "$out" "$(router_reason_disposition "${_rl_r:-router_rc_nonzero}")" "router_error" \
            "$_rl_notes"
        _rl_head="the model call failed, so this lens reviewed nothing"
        _rl_body="Advisory lens: no findings were produced. Absence here is not evidence of a clean change."
        # A lens cut off by its time limit says so, and hands on what it noted
        # (#2270; on #1944 those notes were in its result but not its summary).
        if [[ "$_rl_disp" == timed_out ]]; then
            _rl_head="the ${lens} lens ran out of time before it finished"
            if [[ -n "$_rl_notes" ]]; then
                _rl_body="What it noted before it was stopped (partial):"$'\n\n'"$_rl_notes"$'\n\n'"$_rl_body"
            else
                _rl_body="Nothing it found is known: it saved no notes. $_rl_body"
            fi
        fi
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "$_rl_head" "$_rl_body"
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    if [[ -n "$_rl_problem" ]]; then
        emit_event "review_lens.unparseable" "lens=$lens"
        _review_lens_write_result "$out" unusable \
            "the reply could not be used, even when asked again: $_rl_problem"
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "the reply could not be used, even when asked again ($_rl_problem), so this lens reviewed nothing" \
            "No findings were produced. Absence here is not evidence of a clean change. Every reply it gave is in lens-${lens}-reply.txt."
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    # Coerce to the normalized shape; tolerate string or object findings.
    # v2 result fields (result_contract, verdict, disposition, reason) are embedded
    # in the primary output so the engine can read them from the declared primary
    # output without a separate sidecar (design decision #1840 — no sidecar).
    # #2584 (ADR-038): a finding's other places (also_at), and each suspicion
    # (an object in "unclear") that says what would confirm it — then how many
    # suspicions said nothing would, on a line of its own.
    local normalized _rl_sus_drop=0
    normalized="$(printf '%s' "$json" | jq -c --arg n "$lens" 'def word: if (tostring | ascii_downcase) as $f
            | ["code","test","design"] | index($f) then (tostring | ascii_downcase) elif . == "issue" then "design" else "code" end;
        def said: (. // "" | tostring | gsub("^\\s+|\\s+$"; "")) | length > 0;
        [(.unclear // []) | if type == "array" then .[] else empty end | objects] as $sus
        | {
          schema_version: 1,
          name: $n,
          score: ((.score // 0) | if type=="number" then floor else 0 end),
          findings: [ (.findings // [])[] |
            if type=="object" then {
              file: (.file // "unknown"),
              category: (.category // "general"),
              severity: (if (.severity|tostring|ascii_downcase) as $s
                         | ["low","medium","high","critical"] | index($s)
                         then (.severity|tostring|ascii_downcase) else "low" end),
              line: (.line // null),
              message: (.message // (.|tostring)),
              quote: (.quote // ""),
              # #2552: what makes it happen on a real run.
              trigger: (.trigger // ""),
              # #2569: what the lens would accept.
              accepted_if: (.accepted_if // ""),
              # ADR-038 amendment: whether the change introduced it. Kept here —
              # dropping it made every finding count as new (review on #2215).
              introduced: (if .introduced == false then false else true end),
              # #2433: what would fix it; a word off the list is a code fix.
              fix: (if (.fix|tostring|ascii_downcase) as $f
                    | ["code","test","design","issue"] | index($f)
                    then (.fix|tostring|ascii_downcase) else "code" end),
              also_at: [(.also_at // []) | if type == "array" then .[] else . end | strings | select(said)]
            } + (if (.unchecked // "") != "" then {unchecked: (.unchecked | tostring)} else {} end) else {
              file: "unknown", category: "general", severity: "low",
              line: null, message: (.|tostring), quote: "", trigger: "", accepted_if: "", introduced: true, fix: "code", also_at: []
            } end ],
          suspected: [$sus[] | select((.suspicion | said) and (.confirm_by | said))
            | {file: (.file // "unknown" | tostring), quote: (.quote // "" | tostring), suspicion: (.suspicion | tostring),
               confirm_by: (.confirm_by | tostring), fix: (.fix | word)}]
        }, ([$sus[] | select(((.suspicion | said) and (.confirm_by | said)) | not)] | length)' 2>/dev/null || true)"
    [[ "$normalized" == *$'\n'* ]] && { _rl_sus_drop="${normalized##*$'\n'}"; normalized="${normalized%%$'\n'*}"; }
    if [[ -z "$normalized" ]]; then
        emit_event "review_lens.unparseable" "lens=$lens"
        _review_lens_write_result "$out" unusable "normalization_failed"
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "the lens response could not be normalised, so this lens reviewed nothing" \
            "Advisory lens: no findings were produced. Absence here is not evidence of a clean change."
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    # #2584: each finding's other places, held to the change as its quote is.
    _rl_also_at_hold_v normalized "$normalized" "$_rl_base" "$_rl_repo" "$_rl_patch"
    # #2552 (ADR-038): a second call tries to knock each finding down; one it
    # does is kept under knocked_down and reaches no stage.
    _rl_check_but_unchecked
    # A check cut short ends the lens as its own call would (lens review on #2552).
    if [[ "$_RL_CHECK_RC" -eq 130 ]]; then
        [[ "${_rl_interrupted:-0}" == "1" ]] || _review_lens_write_result "$out" interrupted "signal_interrupt"
        return 130
    fi
    if [[ "$_RL_CHECK_RC" -eq 10 ]]; then
        _review_lens_write_result "$out" out_of_turns "the check of the lens's findings ran out of turns"
        return 10
    fi

    # #2571 (ADR-038): the questions the lens goes on with, those it retired,
    # and its notes, in its result.
    _rl_unclear_settle "$json"
    [[ "$_rl_sus_drop" =~ ^[1-9][0-9]*$ ]] && _RL_UQ_NOTES+="a suspicion was left out: it says nothing would confirm it ($_rl_sus_drop in all)"$'\n'
    _RL_UQ_NOTES+="$_RL_ALSO_NOTES"
    _rl_unclear_data_v normalized "$normalized"

    # Primary output (manifest provides.outputs, primary:true) is
    # lens-${ZBUILD_REVIEW_LENS_ID}.json — here "$out" resolves to
    # $artifact_dir/lens-$lens.json (same file; $lens is the resolved id). Written
    # atomically below to satisfy the #507 primary-output atomicity contract.
    # #2366: a lens is a stage like any other. #2368: when it fails is the
    # template's to say — its group's `fail_on:` lists the severities of a
    # problem the change introduced that fail it (none listed: it never fails).
    # Whether a failing lens blocks anything is the template's to say too.
    local _rl_outcome _rl_reason _rl_stage _rl_fail_var _rl_fail_on
    _rl_stage="${ZBUILD_CURRENT_STAGE:-}"; _rl_stage="${_rl_stage//[^A-Za-z0-9_]/_}"
    _rl_fail_var="_TPL_STAGE_FAIL_ON_${_rl_stage}"
    _rl_fail_on="${!_rl_fail_var:-}"
    # #2433: a finding at a fail_on severity that the change introduced sends
    # the run back; one saying the issue itself is wrong stops it (no stage can
    # fix an issue's text: `misconfigured`, the operator's to fix). Every other
    # finding the change introduced is sent on too, marked as not blocking: on
    # #1805 run 42374066107 one graded low reached no stage, and the next round
    # graded it medium and failed (ADR-071 §5).
    # #2556: one jq gives the lens's outcome and each routed result whole —
    # one output per topic, each failing only on a finding that blocks — so a
    # lens pays no jq per output (ADR-065).
    local _rl_route _rl_k _rl_v _rl_issue="" score=0 findings_count=0; _rl_outcome="pass"
    # #2574 (ADR-068 §5): each routed finding's id, from the lens's own code.
    local _rl_code="" _rl_reg="{}"; _rl_finding_code_v _rl_code "$lens"
    zb_findings_reg_v _rl_reg "$artifact_dir" "$_rl_code" || _rl_code=""
    local _rl_sent="${_RL_PRIOR_SENT:-}"
    # #2599 (ADR-071 §1): a finding about a file in the test folders is the
    # tests' to fix, whatever fix word the lens gave it — only test-author may
    # change those files (#2532 run 45231040380: three went to build, which
    # answered "not mine", round after round).
    local _rl_tre="[]"; zb_test_path_regexes_json_v _rl_tre "${ZBUILD_REPO_ROOT:-$PWD}"
    _rl_route="$(printf '%s' "$normalized" | jq -r --arg on " $_rl_fail_on " --arg n "$lens" --arg prior "$_rl_sent" --argjson c "${_ZBUILD_CONTRACT_V3:-3}" --argjson q "${_RL_UQ_NEWQ:-[]}" --argjson tre "$_rl_tre" \
        --arg reg "$_rl_reg" --arg code "$_rl_code" "$_ZB_FINDING_IDS_JQ"'
        # #2598: a finding that could not be checked always blocks: a lens never
        # passes on what it could not check.
        def at_fail_on: if (.unchecked // "") != "" then ($on | test("[a-z]")) else .severity as $s | ($on | contains(" \($s) ")) end;
        # #2506 (ADR-072 §3): shown with its quote, never a line — lines move.
        def line: (if (.unchecked // "") != "" then "this finding could not be checked (\(.unchecked | gsub("[\r\n]+"; " "))): " else "" end) + "\($n) lens, \(.severity): \(.message) (\(.file)\(if (.quote | tostring) != "" then ": \"\(.quote | tostring | gsub("[\r\n]+"; " "))\"" else "" end); happens when: \(.trigger // "" | tostring | gsub("[\r\n]+"; " ")); fix: \(.fix); ACCEPTED IF: \(.accepted_if // "" | tostring | gsub("[\r\n]+"; " ")))"
            + (if ((.also_at // []) | length) > 0 then "; the same kind of problem also at: " + ([.also_at[] | gsub("[\r\n]+"; " ")] | join("; ")) else "" end);
        # #2584, #2630 (ADR-040): a suspicion reaches the stage its fix word names,
        # which can run commands, to run what would confirm it. The first time it
        # blocks — the change goes round once; sent already in this run, it
        # blocks nothing, and a person sees it.
        def asked: ("The \($n) lens suspects, and could not confirm: \(.suspicion | gsub("[\r\n]+"; " ")) (\(.file)\(if .quote != "" then ": \"\(.quote | gsub("[\r\n]+"; " "))\"" else "" end)); what would confirm it: \(.confirm_by | gsub("[\r\n]+"; " ")). Run what would confirm it: answer done when it holds and you fixed it, or wrong with what you ran and what it showed.") as $t
            | {text: $t, blocking: ($prior | contains($t | tojson | .[1:-1]) | not), area: .file};
        # #2574 (R3): its area — the file it is about — is the item it is kept under.
        def routed: {text: line, blocking: at_fail_on, area: (.file // "unknown" | tostring)};
        # One routed result (#2433): fail with a numbered finding per item when
        # one blocks, pass otherwise.
        def result($what): . as $l
            | {result_contract: $c, outcome: (if ([$l[] | select(.blocking)] | length) > 0 then "fail" else "pass" end),
               reason: (if ($l | length) > 0 then $what else "\($what): none" end)}
              + (if ($l | length) > 0 then {data: {findings: [$l | to_entries[] | {n: (.key + 1), text: .value.text, blocking: .value.blocking}
                  + (if .value.id then {id: .value.id} else {} end) + (if .value.area then {area: .value.area} else {} end)]}} else {} end);
        .findings |= map(if (.fix | IN("code", "design")) and ((.file // "" | ltrimstr("./")) as $f | any($tre[]; . as $r | $f | test($r))) then .fix = "test" else . end)
        # An unchecked finding is an ordinary failure whatever its fix word:
        # never "the issue is wrong" (review on #2598).
        | [.findings[] | select(.fix == "issue" and (.unchecked // "") == "" and at_fail_on)] as $issue
        | [.findings[] | select((.fix != "issue" and .introduced) or (.unchecked // "") != "")] as $sent
        | (.suspected // []) as $susp
        # The score and how many findings: read here, by no jq of their own (ADR-065 §5).
        | "score\t\(.score // 0)", "count\t\(.findings | length)",
          "outcome\t" + (if ($issue | length) > 0 then "misconfigured" elif ([$sent[] | select(at_fail_on)] | length) > 0 or ([$susp[] | select(.fix | IN("code", "test", "design")) | asked | select(.blocking)] | length) > 0 then "fail" else "pass" end),
          "issue\t" + (($issue[0].message // "") | tostring | gsub("[\r\n\t]+"; " ")),
          # #2569 (ADR-071 §1): the fix: word of a finding is its topic,
          # <fix>-findings, and names its output, lens-<id>-<fix>-result.json:
          # no translation. One saying the issue is wrong goes with design.
          # #2571: so does a question it raised now, blocking nothing.
          ([["code", "test", "design"][] as $w
            | ([$sent[] | select(.fix == $w) | routed] + [(.suspected // [])[] | select(.fix == $w) | asked] + (if $w == "design" then [$issue[] | routed]
                  + [$q[] | {text: "The issue is unclear here, and the \($n) lens judged by the assumption: \(.)", blocking: false}] else [] end))[]
            | . + {w: $w}] as $rall
           | (if $code != "" and ($rall | length) > 0 then ($rall | zb_fids($reg; $code)) else {out: $rall, r: null} end) as $z
           | (["code", "test", "design"][] as $w
              | "\($w)\t" + ([$z.out[] | select(.w == $w) | del(.w)] | result("the \($n) lens'"'"'s findings the \($w) must fix")
                  # #2584 (ADR-038): its open suspicions, for the reports a person reads.
                  | [$susp[] | select(.fix == $w) | {file, quote, suspicion, confirm_by}] as $sw
                  | (if ($sw | length) > 0 then .data = ((.data // {}) + {suspected: $sw}) else . end) | tojson)),
             (if $z.r then "reg\t" + ($z.r | tojson) else empty end))' 2>/dev/null)" || _rl_route=""
    while IFS=$'\t' read -r _rl_k _rl_v; do
        case "$_rl_k" in
            outcome) _rl_outcome="$_rl_v" ;;
            score) score="$_rl_v" ;;
            count) findings_count="$_rl_v" ;;
            issue) _rl_issue="$_rl_v" ;;
            code|test|design) atomic_write "${out%.json}-${_rl_k}-result.json" <<< "$_rl_v" ;;
            reg) zb_findings_reg_put "$artifact_dir" "$_rl_code" "$_rl_v" ;;
        esac
    done <<< "$_rl_route"
    # A routing that gave nothing is no pass: the lens's findings reached no stage.
    [[ -n "$_rl_route" ]] || _rl_outcome=broken
    _rl_reason="the ${lens} lens found no ${_rl_fail_on:+${_rl_fail_on// / or } }problem the change introduced that fails it"
    [[ "$_rl_outcome" == fail ]] && _rl_reason="the ${lens} lens found a ${_rl_fail_on// / or } problem the change introduced"
    [[ "$_rl_outcome" == misconfigured ]] && _rl_reason="the ${lens} lens found that the issue itself is wrong: $_rl_issue"
    [[ "$_rl_outcome" == broken ]] && _rl_reason="the ${lens} lens's findings could not be sent on to the stages that fix them"
    printf '%s' "$normalized" | atomic_write "$out" \
        && stage_result_add "$out" "$_rl_outcome" "$_rl_reason"
    local _rl_head _rl_body
    _rl_summary_head_v _rl_head "$lens" "$normalized" _rl_body
    # #2552: what the check knocked down reaches no stage — a person sees it here.
    if [[ "$normalized" == *'"knocked_down":[{'* ]]; then
        local _rl_kd; _rl_kd="$(jq -r '.knocked_down[] | "- knocked down by the check: \(.message) — \(.why)"' <<< "$normalized" 2>/dev/null || true)"
        [[ -n "$_rl_kd" ]] && _rl_body+="${_rl_body:+$'\n'}$_rl_kd"
    fi
    # #2584 (ADR-038): a suspicion left open — a person sees it here too.
    if [[ "$normalized" == *'"suspected":[{'* ]]; then
        local _rl_su; _rl_su="$(jq -r '.suspected[] | "- suspected, not confirmed: \(.suspicion | gsub("[\r\n]+"; " ")) (\(.file)\(if .quote != "" then ": \"\(.quote | gsub("[\r\n]+"; " "))\"" else "" end)) — what would confirm it: \(.confirm_by | gsub("[\r\n]+"; " "))"' <<< "$normalized" 2>/dev/null || true)"
        [[ -n "$_rl_su" ]] && _rl_body+="${_rl_body:+$'\n'}$_rl_su"
    fi
    [[ -n "$_RL_CHECK_NOTE" ]] && _rl_body+="${_rl_body:+$'\n'}- $_RL_CHECK_NOTE"
    stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "$_rl_outcome" \
        "$_rl_head" "${_rl_body:+$_rl_body$'\n'}- score: $score"
    emit_event "plugin.result" "plugin=review-lens" \
        "lens=$lens" "score=$score" "findings_count=$findings_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── review_lens_cleanup ───────────────────────────────────────────────────────
