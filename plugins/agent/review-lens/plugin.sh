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
# #896/#952: shared merge-base change-bundle resolver — the lens judges the same
# full-branch diff as `review`, not the (often empty) incremental build diff.patch.
# shellcheck source=../../../scripts/lib/merge-base.sh
source "$_RL_ROOT/scripts/lib/merge-base.sh"
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
# zb_is_test_path: which changed files are tests (ADR-069 §10).
# shellcheck source=../../../scripts/lib/test-paths.sh
source "$_RL_ROOT/scripts/lib/test-paths.sh"

# _rl_lens_evidence <diff_file> — what a lens is given of the change: every
# file's diff in full except the tests', which are named with their lines added
# and removed. On #1944 the test diffs were 68 KB of a 98 KB diff, read by
# every lens before it could start; a test a lens wants, it opens itself.
_rl_lens_evidence() {
    local f="$1" line path="" block="" add=0 del=0 out="" tests=""
    _rl_flush() {
        [[ -n "$path" ]] || return 0
        if zb_is_test_path "$path"; then tests+="- ${path} (+${add} -${del})"$'\n'
        else out+="$block"; fi
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "diff --git a/"* ]]; then
            _rl_flush
            path="${line##* b/}"; block=""; add=0; del=0
        elif [[ -n "$path" && "$line" != "+++ "* && "$line" != "--- "* ]]; then
            [[ "$line" == +* ]] && add=$((add + 1))
            [[ "$line" == -* ]] && del=$((del + 1))
        fi
        block+="$line"$'\n'
    done < "$f"
    _rl_flush
    unset -f _rl_flush
    printf '%s' "$out"
    [[ -n "$tests" ]] && printf '\nCHANGED TEST FILES (not shown above; open any of them in the worktree when your lens needs it):\n%s' "$tests"
    return 0
}

# ─── _review_lens_envelope_schema_ok <json> ──────────────────────────────────
# Schema gate for _llm_envelope_parse: accepts an object with a .findings array.
# Mirrors _security_lens_envelope_schema_ok (ADR-028 §Migration, #2035).
_review_lens_envelope_schema_ok() {
    local _json="${1:-}"
    [[ -n "$_json" ]] || return 1
    printf '%s' "$_json" | jq -e '(type == "object") and (.findings | type == "array")' >/dev/null 2>&1
}

# ─── _review_lens_write_result <out> <verdict> <disposition> <reason> ────────
# Write a v2-compliant lens result file atomically. The output path is derived
# entirely from the $out parameter (no literal artifact filename strings inside).
# Called on every terminal exit path (degrade + success) so the file is always
# on disk — ADR-055 §3. Verdict appears here as a jq field, not a coercion token.
# _review_lens_saved_notes <artifact_dir> — what this lens saved as it went
# (#2270), capped; empty when nothing was saved. A call cut off by time, turns
# or a signal returns nothing; this is all it leaves.
_review_lens_saved_notes() {
    local cp
    declare -F stage_notes_path >/dev/null 2>&1 || return 0
    # The lens's notes file (ADR-067 §8), found in the artifacts folder it was
    # given, whatever that folder is called.
    cp="$(stage_notes_path "/_rl_sd" "${ZBUILD_CURRENT_STAGE:-review_lenses}")"
    cp="${1%/}/${cp#/_rl_sd/artifacts/}"
    [[ -s "$cp" ]] || return 0
    head -c 4000 "$cp" 2>/dev/null || true
}

# #2366 (contract 3): a lens that reviewed nothing — score 0, no findings — with
# the outcome saying how it ended; any partial notes under data.
_review_lens_write_result() {
    local out="$1" outcome="$2" reason="$3" notes="${4:-}"
    local _base _name
    _base="$(basename "$out")"
    _name="${_base%.json}"; _name="${_name#lens-}"
    # Built beside the result and written to it ONCE: a signal that reaches the
    # trap and the rc=130 branch must still leave exactly one write (#2165).
    local _tmp="${out%/*}/.review-lens-result.$BASHPID.tmp"
    jq -nc \
        --arg n "$_name" \
        --arg pn "$notes" \
        '{schema_version:1, name:$n, score:0, findings:[]}
         + (if $pn != "" then {data:{partial_notes:$pn}} else {} end)' > "$_tmp" 2>/dev/null \
        && stage_result_add "$_tmp" "$outcome" "$reason" 2>/dev/null \
        && atomic_write "$out" 2>/dev/null < "$_tmp"
    rm -f "$_tmp" 2>/dev/null || true
}

# ─── _review_lens_interrupt_handler ──────────────────────────────────────────
# Trap handler for SIGTERM/SIGINT: write disposition:interrupted and propagate.
# Reads $_rl_out_ref (set by _review_lens_run_inner before trap registration)
# so it can be invoked directly in tests for SIGTERM simulation (SPEC-13).
_review_lens_interrupt_handler() {
    _review_lens_write_result "${_rl_out_ref:-}" \
        "${1:-$STAGE_SIGNAL_DISPOSITION}" "${2:-$STAGE_SIGNAL_REASON}" \
        "$(_review_lens_saved_notes "${_rl_out_ref%/*}")"
    # Ctrl-C reaches the whole process group: this trap fires AND the router
    # subshell returns 130. Record the write so the rc=130 branch skips its own.
    _rl_interrupted=1
}



# ─── _review_lens_id ─────────────────────────────────────────────────────────
# Resolve the lens identity: explicit override, else the running stage id, else
# the manifest default. A leading "lens-"/"lens_"/"review-lens-" prefix on a
# stage id is stripped so a stage `lens_security` maps to the `security` charter.
_review_lens_id() {
    local lens="${ZBUILD_REVIEW_LENS_ID:-${ZBUILD_CURRENT_STAGE:-}}"
    lens="${lens#review-lens-}"; lens="${lens#lens-}"; lens="${lens#lens_}"
    printf '%s' "$lens"
}

# _rl_context — what the change was for: the issue, its SPECs, the design's
# decisions and planned scope, each bounded and sanitised like the evidence.
# Every piece is optional; an absent one is simply left out.
# _rl_requirements_readable <design.md> — the acceptance block as a reviewer
# reads it (#2269): each requirement with what its status means (#2304,
# ADR-069), the evidence a done one names, the file that calls the new code,
# and the test files that check each one.
_rl_requirements_readable() {
    local design="$1" sid txt st kind tfs ev w
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        txt="$(acceptance_spec_text "$design" "$sid" 2>/dev/null || true)"
        st="$(acceptance_spec_status "$design" "$sid" 2>/dev/null || true)"
        case "$st" in
            no-code) kind="work that changes no behaviour" ;;
            done)    kind="already done — the code already does this" ;;
            *)       kind="new behaviour" ;;
        esac
        tfs="$(acceptance_list_testfiles_for_spec "$design" "$sid" 2>/dev/null | tr '\n' ' ')"
        printf -- '- %s (%s): %s\n' "$sid" "$kind" "${txt:-<no text>}"
        ev="$(acceptance_spec_evidence "$design" "$sid" 2>/dev/null | tr '\n' ' ')"
        [[ -n "${ev// /}" ]] && printf -- '  shown by: %s\n' "${ev% }"
        [[ -n "${tfs// /}" ]] && printf -- '  checked by: %s\n' "${tfs% }"
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    w="$(acceptance_list_wiring "$design" 2>/dev/null | tr '\n' ' ')"
    [[ -n "${w// /}" ]] && printf -- '- The existing file that calls the new code: %s\n' "${w% }"
    return 0
}

_rl_context() {
    local f out="" _txt
    # #2364: the issue text and the acceptance contract, found by what they are.
    _txt="$(earlier_issue_text "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    if [[ -n "$_txt" ]]; then
        _txt="$(printf '%s' "${_txt:0:6000}" | _zbuild_sanitize_for_llm)"
        out+=$'## THE ISSUE (what was asked for)\n'"$_txt"$'\n\n'
    fi
    f="$(earlier_acceptance_contract "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    if [[ -n "$f" && -s "$f" ]] && declare -F acceptance_list_spec_ids >/dev/null 2>&1; then
        # #2269: the requirements as sentences, not the raw block's keys and tags.
        _txt="$(_rl_requirements_readable "$f")"
        _txt="$(printf '%s' "${_txt:0:6000}" | _zbuild_sanitize_for_llm)"
        [[ -n "$_txt" ]] && out+=$'## THE REQUIREMENTS (what the change had to meet)\n'"$_txt"$'\n\n'
    fi
    # #1654: what the design DECIDED — so "this is odd" and "this was chosen"
    # can be told apart. Same extractor build honours (design_decisions_prose).
    if [[ -n "$f" && -s "$f" ]] && declare -F design_decisions_prose >/dev/null 2>&1; then
        _txt="$(design_decisions_prose "$f" 80)"
        _txt="$(printf '%s' "${_txt:0:6000}" | _zbuild_sanitize_for_llm)"
        [[ -n "${_txt//[[:space:]]/}" ]] && out+=$'## THE DESIGN DECISIONS (what the design chose, and why)\n'"$_txt"$'\n\n'
    fi
    # #2302: the files design planned to change — its ```scope block. Not the
    # scope_manifest input: that is the redaction allow-list ("+ ./" on #2035).
    if [[ -n "$f" && -s "$f" ]]; then
        _txt="$(acceptance_list_scope "$f" 2>/dev/null || true)"
        _txt="$(printf '%s' "${_txt:0:4000}" | _zbuild_sanitize_for_llm)"
        [[ -n "${_txt//[[:space:]]/}" ]] && out+=$'## THE PLANNED SCOPE (files the plan expected to change)\n'"$_txt"$'\n'
    fi
    printf '%s' "$out"
}

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

    # #896/#952: every lens judges the full-branch merge-base change bundle
    # (the incremental diff.patch when no base resolves) — the same evidence
    # for every lens, as for any stage.
    local evidence; evidence="$(zbuild_change_bundle "$artifact_dir")"
    _review_lens_run_inner \
        "$lens" \
        "$(earlier_scope_manifest "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)" \
        "$evidence" \
        "$artifact_dir/lens-$lens.json" \
        "$artifact_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args: $1=lens  $2=scope_manifest  $3=evidence(file)  $4=out lens-<name>.json
#       $5=(optional) artifact dir for the intermediate redacted prompt
_review_lens_run_inner() {
    # $2 (the scope manifest) is the redaction allow-list, not the plan: the
    # planned scope comes from design's ```scope block (_rl_context, #2302).
    # Redaction of the assembled prompt is the router's, by construction (ADR-043).
    local lens="$1" evidence="$3" out="$4"
    local artifact_dir="${5:-$(dirname "$out")}"

    if [[ -z "$lens" || -z "$out" ]]; then
        error "_review_lens_run_inner: requires <lens> <scope_manifest> <evidence> <out>"
        return 2
    fi
    mkdir -p "$artifact_dir"

    # Resolve evidence. ADR-043: the router redacts the assembled prompt by
    # construction, so we pass RAW evidence and ALWAYS route (the former
    # empty-evidence guard that skipped redaction — and thus tripped the router
    # C6 precondition on an empty change bundle, #952 — is gone).
    local evidence_content="(no change bundle available)"
    if [[ -s "$evidence" ]]; then
        # #721: strip OOS-marker tags + ANSI fragments from terminal capture.
        evidence_content="$(printf '%s' "$(_rl_lens_evidence "$evidence")" | _zbuild_sanitize_for_llm)"
    fi

    # ─── Build the single-lens prompt ──────────────────────────────────────
    local prompt; prompt="$(_rl_build_lens_prompt "$lens" "$evidence_content" "$(_rl_context)")"

    # ADR-067 §8: the lens's three parts and the engine's blocks — its budget
    # and notes file among the engine's rules — in the one prompt order.
    local _composed
    if ! _composed="$(stage_prompt_compose_parts "$prompt")"; then
        _review_lens_write_result "$out" "degraded" "misconfigured" "prompt_not_composed"
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
    raw_response="$(route_to_model "$tier" "$prompt")" || router_rc=$?
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
    if [[ "$router_rc" -eq 130 ]]; then
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

    # ADR-028 §Migration (#2035): schema-gated envelope parser replaces bare
    # extract_first_json_object so postamble sign-offs don't discard the real answer.
    # shellcheck disable=SC2034  # prose is a required output-param of _llm_envelope_parse;
    # review-lens emits no prose sidecar.
    local json prose
    _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok "$raw_response" json prose
    if [[ -z "$json" ]] || ! printf '%s' "$json" | jq empty >/dev/null 2>&1; then
        emit_event "review_lens.unparseable" "lens=$lens"
        _review_lens_write_result "$out" unusable "unparseable_reply"
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "the model returned unparseable JSON, so this lens reviewed nothing" \
            "Advisory lens: no findings were produced. Absence here is not evidence of a clean change."
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    # Coerce to the normalized shape; tolerate string or object findings.
    # v2 result fields (result_contract, verdict, disposition, reason) are embedded
    # in the primary output so the engine can read them from the declared primary
    # output without a separate sidecar (design decision #1840 — no sidecar).
    local normalized
    normalized="$(printf '%s' "$json" | jq -c --arg n "$lens" '
        {
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
              # ADR-038 amendment: whether the change introduced it. Kept here —
              # dropping it made every finding count as new (review on #2215).
              introduced: (if .introduced == false then false else true end)
            } else {
              file: "unknown", category: "general", severity: "low",
              line: null, message: (.|tostring), introduced: true
            } end ]
        }' 2>/dev/null || true)"
    if [[ -z "$normalized" ]]; then
        emit_event "review_lens.unparseable" "lens=$lens"
        _review_lens_write_result "$out" unusable "normalization_failed"
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "the lens response could not be normalised, so this lens reviewed nothing" \
            "Advisory lens: no findings were produced. Absence here is not evidence of a clean change."
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

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
    _rl_outcome="$(printf '%s' "$normalized" | jq -r --arg on " $_rl_fail_on " \
        'if any(.findings[]; .severity as $s | .introduced and ($on | contains(" \($s) ")))
         then "fail" else "pass" end' 2>/dev/null || printf 'pass')"
    _rl_reason="the ${lens} lens found no ${_rl_fail_on:+${_rl_fail_on// / or } }problem the change introduced that fails it"
    [[ "$_rl_outcome" == fail ]] && _rl_reason="the ${lens} lens found a ${_rl_fail_on// / or } problem the change introduced"
    printf '%s' "$normalized" | atomic_write "$out" \
        && stage_result_add "$out" "$_rl_outcome" "$_rl_reason"
    local score findings_count
    score="$(printf '%s' "$normalized" | jq -r '.score // 0' 2>/dev/null || echo 0)"
    findings_count="$(printf '%s' "$normalized" | jq '.findings | length' 2>/dev/null || echo 0)"
    stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "$_rl_outcome" \
        "reviewed the change through the ${lens} lens — $findings_count finding(s), score $score" \
        "$(printf -- '- artifact: lens-%s.json' "${lens}")"
    emit_event "plugin.result" "plugin=review-lens" \
        "lens=$lens" "score=$score" "findings_count=$findings_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── review_lens_cleanup ───────────────────────────────────────────────────────
