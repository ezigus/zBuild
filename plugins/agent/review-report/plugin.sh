#!/usr/bin/env bash
# plugins/agent/review-report — evidence-fed multi-lens merge-readiness report.
#
# ADR-038 (EPIC #966 I6). Bound to the single `review` stage of simple.yaml via
# provides.role: review_report (resolver.sh) — NOT a new flow stage, and the
# legacy `review` plugin (standard.yaml) is untouched. Fans N lenses out as N
# independent LLM calls, aggregates + de-dupes findings, and emits an advisory
# report. Advisory only: it never recommends a merge action and never gates the
# pipeline — _rr_run_inner always writes review-report.json first and
# returns 0 (a failed lens degrades to empty findings).
#
# ADR refs: ADR-001 (plugin contract), ADR-003 (tier T2), ADR-004 (redaction),
#           ADR-037 (objective gates vs semantic judgment), ADR-038 (this stage).

[[ -n "${_ZBUILD_REVIEW_REPORT_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_REPORT_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_RR_DIR="$_ZBUILD_PLUGIN_DIR"
_RR_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_RR_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_RR_ROOT/core/router/route.sh"
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_RR_ROOT/scripts/lib/artifact-render.sh"
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_RR_ROOT/scripts/lib/llm-agent.sh"
# shellcheck source=lib/lenses.sh
source "$_RR_DIR/lib/lenses.sh"
# shellcheck source=../../../scripts/lib/call-graph.sh
source "$_RR_ROOT/scripts/lib/call-graph.sh"
# #896/#952: shared merge-base change-bundle resolver — the report judges the same
# full-branch diff as `review`, not the (often empty) incremental build diff.patch.
# shellcheck source=../../../scripts/lib/merge-base.sh
source "$_RR_ROOT/scripts/lib/merge-base.sh"

# ─── _rr_write_v2 <out_json> <verdict> <disposition> <reason> [<report_json>] ─
# The v2 result IS the primary (ADR-054 §5: one file, outputs[primary: true]),
# so the report's own keys (merge_readiness/findings/lenses — pr-open and
# pr-delivery read them top-level) and the contract keys share review-report.json.
_rr_write_v2() {
    # `{\}` is the literal two-character default `{}` — the backslash keeps the
    # brace from closing the expansion.
    local out_json="$1" verdict="$2" disposition="$3" reason="$4" report="${5:-{\}}"
    mkdir -p "$(dirname "$out_json")" 2>/dev/null || true
    jq -n --argjson r "$report" --arg v "$verdict" --arg d "$disposition" --arg why "$reason" \
        '$r + {result_contract: 2, verdict: $v, disposition: $d, reason: $why, data: ($r.data // {})}' \
        | atomic_write "$out_json" 2>/dev/null \
        || warn "review_report: failed to write $out_json"
}

# ─── _rr_budget_guidance <max_turns> <timeout_s> ─────────────────────────────
# TURN BUDGET block for lens prompts (ADR-063 §1). Both numbers come from the
# resolvers that enforce them; a hand-copied literal drifts from what kills
# the call. Empty when the budget is unknown.
_rr_budget_guidance() {
    local budget="${1:-}" timeout_s="${2:-}"
    [[ "$budget" =~ ^[0-9]+$ && "$budget" -gt 0 ]] || { printf ''; return 0; }
    local wall=""
    [[ "$timeout_s" =~ ^[0-9]+$ && "$timeout_s" -gt 0 ]] && wall=" and about ${timeout_s} seconds of wall clock"
    cat <<EOF
TURN BUDGET (read this — you have a BOUNDED tool-call budget):
- You have about ${budget} tool-call turns for this review lens${wall}.
- Review only what you can examine within your budget; flag unexamined areas explicitly.
- STOP examining and emit your JSON findings object before you run out of turns. A partial review with named gaps BEATS exhausting the budget and producing no output at all.
EOF
}

# ─── review_report_run ──────────────────────────────────────────────────────
# Hook: review_report_run(stage, state_file). Derives artifact paths and
# delegates to the unit-testable inner function.
review_report_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "review_report_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/review-report-summary.md}" "review-report" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        _rr_write_v2 "${ZBUILD_ARTIFACT_DIR:-.}/review-report.json" "error" "broken" \
            "the engine dispatched this stage with no state file"
        return 1
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    # Read declared inputs from ZBUILD_STAGE_INPUTS when the engine provides the index.
    local scope_manifest=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -f "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        scope_manifest="$(jq -r '.inputs.scope_manifest // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi

    # #896/#952: judge the full-branch merge-base change bundle (falls back to the
    # incremental diff.patch when no base resolves) so review-report and `review`
    # share ONE change basis. The empty per-run diff.patch was the #952 lens miss.
    local bundle; bundle="$(zbuild_change_bundle "$artifact_dir")"
    _rr_run_inner \
        "$scope_manifest" \
        "$bundle" \
        "$artifact_dir/review-report.json" \
        "$artifact_dir/review-report.md"
}

# Inner implementation — unit-testable with explicit paths.
# Args: $1=scope_manifest  $2=evidence(diff)  $3=out review-report.json  $4=out .md
_rr_run_inner() {
    local scope_manifest="$1" evidence="$2" out_json="$3" out_md="$4"
    if [[ -z "$out_json" ]]; then
        error "_rr_run_inner: output path required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/review-report-summary.md}" "review-report" "error" \
            "no output path was supplied, so no review report could be written" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        _rr_write_v2 "${ZBUILD_ARTIFACT_DIR:-.}/review-report.json" "error" "broken" \
            "no output path was supplied"
        return 1
    fi
    local artifact_dir; artifact_dir="$(dirname "$out_json")"
    mkdir -p "$artifact_dir"

    # Produce call-graph artifact for architecture/correctness lenses (fail-soft).
    local _cg_out="$artifact_dir/call-graph.json" _cg_rc=0
    call_graph_produce "$evidence" "$_RR_ROOT" "$_cg_out" || _cg_rc=$?
    if [[ $_cg_rc -eq 0 && -s "$_cg_out" ]]; then
        local _cg_n
        _cg_n="$(jq -r '.changed_surface | length' "$_cg_out" 2>/dev/null || echo 0)"
        if [[ "${_cg_n:-0}" -gt 0 ]]; then
            _rr_register_lens_artifact "architecture" "$_cg_out"
            _rr_register_lens_artifact "correctness" "$_cg_out"
        fi
    fi

    local tier
    if ! tier="$(resolve_tier review-report "$_RR_DIR")"; then
        stage_summary_write "$artifact_dir/review-report-summary.md" "review-report" "error" \
            "no model tier resolved for review-report, so no lens could be dispatched" \
            "No work was attempted. This is a configuration fault, not a fault in the change."
        _rr_write_v2 "$out_json" "error" "broken" "no model tier resolved for review-report"
        return 1
    fi

    # Register per-lens artifacts before fan-out so each lens gets distinct evidence.
    _rr_populate_artifact_registry "$artifact_dir"
    # Wire coverage-map artifact to test-coverage lens when available (fail-soft).
    local _cmap="$artifact_dir/coverage-map.json"
    if [[ -s "$_cmap" ]]; then
        _rr_register_lens_artifact "test-coverage" "$_cmap"
    fi

    # Resolve router budget and build guidance block to inject into each lens prompt.
    local _budget_max_turns _budget_timeout_s _budget_guidance
    _budget_max_turns="$(_route_resolve_max_turns 2>/dev/null || printf '0')"
    _budget_timeout_s="$(_route_resolve_timeout 2>/dev/null || printf '0')"
    _budget_guidance="$(_rr_budget_guidance "$_budget_max_turns" "$_budget_timeout_s")"

    # Fan out the lenses (bounded-parallel) → combined per-lens results.
    local lenses_file
    lenses_file="$(_rr_fanout_lenses "$scope_manifest" "$evidence" "$artifact_dir" "$tier" "$_budget_guidance")"

    # ADR-063 §3: a lens whose call returned non-zero ran out of something —
    # the report is still written (advisory), but the disposition says
    # `exhausted` so the engine's response table can act on it.
    local _rr_failed_lenses="" _rr_lens_name _rr_lens_rc
    for _rr_lens_name in "${_RR_LENSES[@]}"; do
        _rr_lens_rc="$(cat "$artifact_dir/lens-${_rr_lens_name}.rc" 2>/dev/null || echo 1)"
        [[ "$_rr_lens_rc" -ne 0 ]] && _rr_failed_lenses="${_rr_failed_lenses:+$_rr_failed_lenses, }$_rr_lens_name"
    done
    local _disposition="complete" _reason
    if [[ -n "$_rr_failed_lenses" ]]; then
        _disposition="exhausted"
        _reason="lens call(s) returned non-zero: ${_rr_failed_lenses}; the report covers the lenses that completed"
    else
        _reason="all ${#_RR_LENSES[@]} lenses completed; advisory report written"
    fi

    # Aggregate + de-dupe into the advisory report, which IS the v2 result
    # (always written first, before any fail-soft step below).
    _rr_write_v2 "$out_json" "pass" "$_disposition" "$_reason" "$(_rr_aggregate "$lenses_file")"

    local merge_readiness lens_count
    merge_readiness="$(jq -r '.merge_readiness // "advisory"' "$out_json" 2>/dev/null || echo advisory)"
    lens_count="$(jq -r '.lenses | length' "$out_json" 2>/dev/null || echo 0)"

    # Render markdown via the registered renderer (bracketed jq — no blank
    # sections; the PR #1004 stream-into-join() bug is fixed in the renderer).
    if [[ -s "$out_json" ]]; then
        render_review_report_md "$(cat "$out_json")" | atomic_write "$out_md" 2>/dev/null || true
    fi

    # Fail-soft PR attach (gh error never aborts the advisory stage).
    local pr_num="${ZBUILD_PR_NUMBER:-}"
    if [[ -n "$pr_num" && -s "$out_md" ]]; then
        set +e
        gh pr comment "$pr_num" --body-file "$out_md" >/dev/null 2>&1
        local gh_rc=$?
        set -e
        [[ $gh_rc -ne 0 ]] && warn "review_report: gh pr comment failed (rc=$gh_rc); continuing"
    fi

    stage_summary_write "$artifact_dir/review-report-summary.md" "review-report" "pass" \
        "aggregated $lens_count review lens(es) — merge readiness: $merge_readiness" \
        "$(printf -- '- artifact: review-report.md')"
    emit_event "plugin.result" \
        "plugin=review-report" \
        "merge_readiness=$merge_readiness" \
        "lens_count=$lens_count"
    return 0
}
