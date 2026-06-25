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
_RR_DIR="$_ZBUILD_PLUGIN_DIR"
_RR_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_RR_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_RR_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_RR_ROOT/core/router/route.sh"
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_RR_ROOT/scripts/lib/artifact-render.sh"
# shellcheck source=lib/lenses.sh
source "$_RR_DIR/lib/lenses.sh"
# shellcheck source=../../../scripts/lib/call-graph.sh
source "$_RR_ROOT/scripts/lib/call-graph.sh"

# ─── review_report_init ─────────────────────────────────────────────────────
review_report_init() {
    export ZBUILD_PLUGIN="review-report"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=review-report"
    return 0
}

# ─── review_report_run ──────────────────────────────────────────────────────
# Hook: review_report_run(stage, state_file). Derives artifact paths and
# delegates to the unit-testable inner function.
review_report_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "review_report_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    _rr_run_inner \
        "$state_dir/scope-manifest.md" \
        "$artifact_dir/diff.patch" \
        "$artifact_dir/review-report.json" \
        "$artifact_dir/review-report.md"
}

# Inner implementation — unit-testable with explicit paths.
# Args: $1=scope_manifest  $2=evidence(diff)  $3=out review-report.json  $4=out .md
_rr_run_inner() {
    local scope_manifest="$1" evidence="$2" out_json="$3" out_md="$4"
    if [[ -z "$out_json" ]]; then
        error "_rr_run_inner: output path required"
        return 2
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
            _RR_LENS_ARTIFACT_REGISTRY[architecture]="$_cg_out"
            _RR_LENS_ARTIFACT_REGISTRY[correctness]="$_cg_out"
        fi
    fi

    local tier="${ZBUILD_REVIEW_REPORT_TIER:-T2}"

    # Register per-lens artifacts before fan-out so each lens gets distinct evidence.
    _rr_populate_artifact_registry "$artifact_dir"
    # Wire coverage-map artifact to test-coverage lens when available (fail-soft).
    local _cmap="$artifact_dir/coverage-map.json"
    if [[ -s "$_cmap" ]]; then
        _rr_register_lens_artifact "test-coverage" "$_cmap"
    fi

    # Fan out the lenses (bounded-parallel) → combined per-lens results.
    local lenses_file
    lenses_file="$(_rr_fanout_lenses "$scope_manifest" "$evidence" "$artifact_dir" "$tier")"

    # Aggregate + de-dupe into the advisory report (always written first).
    _rr_aggregate "$lenses_file" | atomic_write "$out_json"

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

    emit_event "plugin.run.complete" \
        "plugin=review-report" \
        "merge_readiness=$merge_readiness" \
        "lens_count=$lens_count"
    return 0
}

# ─── review_report_finalize ─────────────────────────────────────────────────
review_report_finalize() {
    emit_event "plugin.finalize.complete" "plugin=review-report"
    return 0
}
