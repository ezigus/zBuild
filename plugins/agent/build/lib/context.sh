#!/usr/bin/env bash
# plugins/agent/build/lib/context.sh — context-loading helpers for the build stage.
# Sourced by plugin.sh after shared libs (acceptance-block.sh, etc.) are loaded.

[[ -n "${_ZBUILD_BUILD_CONTEXT_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_CONTEXT_LOADED=1

# _build_read_acceptance_testfiles <design_md_path> (ADR-031 / #866)
# The acceptance tests, one per line: the files in the test folders holding a
# SPEC's tag (#2508 — design names none). Empty when there are none yet.
_build_read_acceptance_testfiles() {
    acceptance_list_testfiles "${1:-}" "${ZBUILD_REPO_ROOT:-}"
}

# _build_read_design_decisions <design_md_path> (ISSUE-E / #916, ADR-020)
# Extract the design.md DECISION PROSE, excluding all fenced blocks. Bounded
# to _BUILD_DESIGN_DECISIONS_MAX_LINES. Empty stdout when absent or no prose.
_BUILD_DESIGN_DECISIONS_MAX_LINES="${_BUILD_DESIGN_DECISIONS_MAX_LINES:-120}"
_build_read_design_decisions() {
    # The extractor is shared (scripts/lib/acceptance-block.sh) — review-lens
    # judges against the same decisions (#1654).
    design_decisions_prose "${1:-}" "$_BUILD_DESIGN_DECISIONS_MAX_LINES"
}


# _build_read_prior_review / _build_read_prior_acceptance — RETIRED (#2124).
# No shipped template wired the feedback edges they read since #1979; what a
# reviewer or the acceptance gate found reaches build as the engine-collected
# STAGE SUMMARIES block (ADR-055 §9). The acceptance reader also told build to
# tag testfiles #2022 forbids it to edit.

# _build_read_tautology_ids — RETIRED (#2022).
# Since #1477 build owned the assertion bodies, so the gate's tautology finding
# was fed here for build to re-author. That is the agent whose control was found
# inert rewriting the control. Assertion authorship now belongs to test-author,
# and so does this feedback: the same
# acceptance-gate-result.json -> cycle-feedback/prior_acceptance_feedback.txt
# path carries it there. Removed rather than left unused so no future prompt
# builder finds it and re-wires the defect.

# _build_gather_acceptance_specs <design_md>  (#1978)
# One line per SPEC: "SPEC-n<TAB>what it requires", and "<TAB>doc" after a [doc]
# one (#2525: it has no test; build makes the doc say it). A SPEC whose text cannot be
# resolved emits the bare id, so the prompt degrades to the id-only form rather
# than dropping a SPEC the gate will still demand coverage for. A done SPEC is
# left out: the code already does it, so build has nothing to do (#2304, ADR-069 §6).
_build_gather_acceptance_specs() {
    local design_md="${1:-}" sid text blk _p
    [[ -n "$design_md" && -f "$design_md" ]] || return 0
    # #2467: the block read once; each SPEC's words and its parts, on its one line.
    blk="$(extract_acceptance_block "$design_md" 2>/dev/null)" || blk=""
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        text=""
        if _acceptance_spec_line "$blk" "$sid"; then
            [[ "$_ACC_SPEC_STATUS" == "done" ]] && continue
            text="$_ACC_SPEC_TEXT"
            local -a _bg_parts=()
            acceptance_parts_shown_v _bg_parts "$_ACC_SPEC_PARTS"
            for _p in ${_bg_parts[@]+"${_bg_parts[@]}"}; do text+=" — ${_p%%$'\t'*}: ${_p#*$'\t'}"; done
        fi
        if [[ -n "$text" && "$_ACC_SPEC_STATUS" == "doc" ]]; then
            printf '%s\t%s\tdoc\n' "$sid" "$text"
        elif [[ -n "$text" ]]; then
            printf '%s\t%s\n' "$sid" "$text"
        else
            printf '%s\n' "$sid"
        fi
    done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)
}

# _build_load_context — extracted context-loading block from _build_stage_run_inner.
# Uses dynamic scoping: reads artifact_dir from the caller's locals; writes
# _acceptance_testfiles, _acceptance_spec_ids, _design_decisions back into the
# caller's scope (no `local` on those names here — bash dynamic scope).
# #2508 (ADR-030 §8): build has no file list — no scope block, no plan files,
# no grant. It may change any file outside the test folders.
_build_load_context() {
    # shellcheck disable=SC2154  # artifact_dir injected via dynamic scope from caller
    # #2364: the acceptance contract, found by what it contains.
    local _ctx_design_md_path; _ctx_design_md_path="$(earlier_acceptance_contract "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"

    # ADR-031 (#866): the acceptance tests, for the prompt.
    _acceptance_testfiles=""
    if [[ -f "$_ctx_design_md_path" ]]; then
        _acceptance_testfiles="$(_build_read_acceptance_testfiles "$_ctx_design_md_path" 2>/dev/null || true)"
    fi

    # #951 Layer 1: enumerate the design's stable SPEC ids.
    # #1978: each id is paired with what it REQUIRES. The id alone made the
    # prompt's demand a shape requirement — "an assertion tagged [SPEC-n] that
    # fails at baseline" — which an assertion about any field satisfies.
    _acceptance_spec_ids=""
    if [[ -f "$_ctx_design_md_path" ]]; then
        _acceptance_spec_ids="$(_build_gather_acceptance_specs "$_ctx_design_md_path" 2>/dev/null || true)"
    fi

    # #916 (ADR-020): design.md decision prose.
    _design_decisions=""
    if [[ -f "$_ctx_design_md_path" ]]; then
        _design_decisions="$(_build_read_design_decisions "$_ctx_design_md_path" 2>/dev/null || true)"
    fi
}
