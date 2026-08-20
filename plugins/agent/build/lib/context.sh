#!/usr/bin/env bash
# plugins/agent/build/lib/context.sh — context-loading helpers for the build stage.
# Sourced by plugin.sh after shared libs (acceptance-block.sh, etc.) are loaded.

[[ -n "${_ZBUILD_BUILD_CONTEXT_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_CONTEXT_LOADED=1

# _build_read_acceptance_testfiles <design_md_path> (ADR-031 / #866)
# Returns only the TESTFILES paths from the ```acceptance block in design.md,
# one per line. Empty when design.md is absent, has no acceptance block, or
# the block has no TESTFILES section.
_build_read_acceptance_testfiles() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    [[ -z "$block_output" ]] && return 0
    local in_testfiles=0 line
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then
            in_testfiles=1
            continue
        fi
        if [[ $in_testfiles -eq 1 && -n "$line" ]]; then
            line="${line%$'\r'}"
            [[ -z "$line" ]] && continue
            # ADR-031: never surface absolute or ".."-containing paths.
            if [[ "$line" == /* || "/$line/" == *"/../"* ]]; then
                continue
            fi
            printf '%s\n' "$line"
        fi
    done <<< "$block_output"
}

# _build_read_design_decisions <design_md_path> (ISSUE-E / #916, ADR-020)
# Extract the design.md DECISION PROSE, excluding all fenced blocks. Bounded
# to _BUILD_DESIGN_DECISIONS_MAX_LINES. Empty stdout when absent or no prose.
_BUILD_DESIGN_DECISIONS_MAX_LINES="${_BUILD_DESIGN_DECISIONS_MAX_LINES:-120}"
_build_read_design_decisions() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    local body
    body="$(awk -v cap="$_BUILD_DESIGN_DECISIONS_MAX_LINES" '
        /^```/ { infence = !infence; next }
        infence { next }
        { print; emitted++ }
        emitted >= cap { exit }
    ' "$design_md" 2>/dev/null || true)"
    body="$(printf '%s\n' "$body" | sed '/./,$!d')"
    [[ -z "${body//[[:space:]]/}" ]] && return 0
    printf '%s\n' "$body"
}

# _build_read_prior_build_summary (ADR-050 / #1581)
# Read a prior RUN's build-summary.json (via the unified prior-work seam), and
# emit a concise, human-readable advisory line for the build prompt. The seam's
# cross-run/local tiers surface a prior attempt's summary; empty stdout when
# absent (first run / no state branch). Intentionally NOT machine JSON in the
# prompt — build already sees the actual committed code via the router's BRANCH
# STATE injection; this just tells it a prior attempt exists so it continues
# rather than restarts.
_build_read_prior_build_summary() {
    local raw; raw="$(_read_prior_output "build-summary.json" 2>/dev/null || true)"
    [[ -z "${raw//[[:space:]]/}" ]] && return 0
    local verdict n_files files
    verdict="$(printf '%s' "$raw" | jq -r '.verdict // "unknown"' 2>/dev/null || echo unknown)"
    n_files="$(printf '%s' "$raw" | jq -r '(.files_changed // []) | length' 2>/dev/null || echo 0)"
    files="$(printf '%s' "$raw" | jq -r '(.files_changed // []) | join(", ")' 2>/dev/null || echo "")"
    [[ "$n_files" =~ ^[0-9]+$ ]] || n_files=0
    printf 'A previous attempt on this issue ended build with verdict=%s and touched %s file(s)%s. That work is likely already committed on this branch (check `git log` / `git diff`). Continue or refine it — do NOT restart from scratch, and emit LOOP_COMPLETE immediately if the change is already present.' \
        "$verdict" "$n_files" "${files:+: $files}"
}

# _build_read_prior_assessment (#571)
# Read the prior cycle iter's test_assessment markdown from
# $ZBUILD_CYCLE_FEEDBACK_DIR/prior_test_assessment.txt. Empty stdout when
# not in a cycle, dir unset, or file missing/empty.
_build_read_prior_assessment() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    local f="$fb_dir/prior_test_assessment.txt"
    [[ ! -s "$f" ]] && return 0
    local body
    body="$(cat "$f" 2>/dev/null)" || return 0
    [[ -z "$body" ]] && return 0
    printf '%s' "$body"
}

# _build_read_prior_review (ADR-026 / Wave 18-B / #707)
# Read the prior outer-cycle iter's review markdown from
# $ZBUILD_CYCLE_FEEDBACK_DIR/prior_review_feedback.txt. Empty stdout when
# not in a cycle, dir unset, or file missing/empty.
_build_read_prior_review() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    local f="$fb_dir/prior_review_feedback.txt"
    [[ ! -s "$f" ]] && return 0
    local body
    body="$(cat "$f" 2>/dev/null)" || return 0
    [[ -z "$body" ]] && return 0
    printf '%s' "$body"
}

# _build_read_prior_gate (B2 / ADR-040)
# Read the prior cycle iter's consolidated gate-aggregator feedback from
# $ZBUILD_CYCLE_FEEDBACK_DIR/gate_feedback.txt. Empty stdout when
# not in a cycle, dir unset, or file missing/empty.
_build_read_prior_gate() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    local f="$fb_dir/gate_feedback.txt"
    [[ ! -s "$f" ]] && return 0
    local body
    body="$(cat "$f" 2>/dev/null)" || return 0
    [[ -z "$body" ]] && return 0
    printf '%s' "$body"
}

# _build_read_prior_acceptance (#951 Layer 2 / ADR-036)
# Read the prior outer-cycle iter's acceptance-gate-result.json from
# $ZBUILD_CYCLE_FEEDBACK_DIR/prior_acceptance_feedback.txt. Prints ONLY
# untagged_spec:<id> failure ids, one per line. Empty when not in a cycle,
# dir unset, file missing/empty, verdict=pass, or no untagged_spec failures.
_build_read_prior_acceptance() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    local f="$fb_dir/prior_acceptance_feedback.txt"
    [[ ! -s "$f" ]] && return 0
    jq -r '
        if (.verdict? // "pass") == "pass" then empty
        else (.failures // [])[]
             | select(type == "string" and startswith("untagged_spec:"))
             | sub("^untagged_spec:"; "")
        end' "$f" 2>/dev/null || return 0
}

# _build_read_tautology_ids (#1583 / ADR-036)
# Read the prior outer-cycle iter's acceptance-gate-result.json from
# $ZBUILD_CYCLE_FEEDBACK_DIR/prior_acceptance_feedback.txt. Prints ONLY
# tautology:<id> failure ids, one per line — the [change] SPECs whose tagged
# assertion PASSES at the merge-base baseline (asserts nothing). Since #1477
# BUILD owns the assertion bodies, build must re-author these to fail-at-baseline;
# the negative control re-verifies next iteration. Empty when not in a cycle, dir
# unset, file missing/empty, verdict=pass, or no tautology failures.
_build_read_tautology_ids() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    local f="$fb_dir/prior_acceptance_feedback.txt"
    [[ ! -s "$f" ]] && return 0
    jq -r '
        if (.verdict? // "pass") == "pass" then empty
        else (.failures // [])[]
             | select(type == "string" and startswith("tautology:"))
             | sub("^tautology:"; "")
        end' "$f" 2>/dev/null || return 0
}

# _build_load_context — extracted context-loading block from _build_stage_run_inner.
# Uses dynamic scoping: reads plan_json + artifact_dir from caller's locals; writes
# plan_files_csv, _acceptance_testfiles, _acceptance_spec_ids, _design_decisions
# back into caller's scope (no `local` on those names here — bash dynamic scope).
_build_load_context() {
    # shellcheck disable=SC2154  # artifact_dir and plan_json injected via dynamic scope from caller
    local _ctx_design_md_path="$artifact_dir/design.md"
    local _ctx_scope_source="plan"
    local _ctx_design_csv="" _ctx_scope_file_count=0 _ctx_granted="" _ctx_candidate=""
    local _ctx_state_dir_for_design

    # Extract plan.files[] — the canonical scope for this build.
    # shellcheck disable=SC2154  # plan_json injected via dynamic scope from caller
    plan_files_csv="$(printf '%s' "$plan_json" | \
        jq -r '[(.files // []), ([.steps[]?.files[]?] // [])] | flatten | unique | join(",")' \
        2>/dev/null || echo "")"

    # Resolve design.md path.
    if [[ ! -f "$_ctx_design_md_path" ]]; then
        _ctx_state_dir_for_design="$(dirname "$artifact_dir")"
        _ctx_candidate="$_ctx_state_dir_for_design/artifacts/design.md"
        [[ -f "$_ctx_candidate" ]] && _ctx_design_md_path="$_ctx_candidate"
    fi

    # ADR-031 (#866): acceptance test file paths for charter injection.
    _acceptance_testfiles=""
    if [[ -f "$_ctx_design_md_path" ]]; then
        _acceptance_testfiles="$(_build_read_acceptance_testfiles "$_ctx_design_md_path" 2>/dev/null || true)"
    fi

    # #951 Layer 1: enumerate the design's stable SPEC ids.
    _acceptance_spec_ids=""
    if [[ -f "$_ctx_design_md_path" ]]; then
        _acceptance_spec_ids="$(acceptance_list_spec_ids "$_ctx_design_md_path" 2>/dev/null || true)"
    fi

    # #916 (ADR-020): design.md decision prose.
    _design_decisions=""
    if [[ -f "$_ctx_design_md_path" ]]; then
        _design_decisions="$(_build_read_design_decisions "$_ctx_design_md_path" 2>/dev/null || true)"
    fi

    # #754: if design.md has a ```scope block, use it as the authoritative scope source.
    if [[ -f "$_ctx_design_md_path" ]] && grep -q '^```scope' "$_ctx_design_md_path" 2>/dev/null; then
        _ctx_design_csv="$(_extract_scope_from_design "$_ctx_design_md_path" 2>/dev/null || echo "")"
        if [[ -n "$_ctx_design_csv" ]]; then
            plan_files_csv="$_ctx_design_csv"
            _ctx_scope_source="design"
        fi
    fi
    if [[ "$_ctx_scope_source" == "design" ]]; then
        _ctx_scope_file_count=0
        if [[ -n "$plan_files_csv" ]]; then
            # `|| true`, never `|| echo 0`: grep -c already prints its count, so
            # the echo would append a second line and yield "0\n0" (#1751).
            _ctx_scope_file_count="$(printf '%s' "$plan_files_csv" | tr ',' '\n' | grep -c '.' 2>/dev/null || true)"
            _ctx_scope_file_count="${_ctx_scope_file_count//[^0-9]/}"
            _ctx_scope_file_count="${_ctx_scope_file_count:-0}"
        fi
        emit_event "build.scope_injected" "plugin=build" \
            "source=$_ctx_scope_source" "file_count=$_ctx_scope_file_count" \
            >/dev/null 2>&1 || true
    fi

    # #840 (ADR-030): consume scope grant from cycle orchestrator.
    if [[ -n "${ZBUILD_SCOPE_EXPANSION_GRANT:-}" && -f "$ZBUILD_SCOPE_EXPANSION_GRANT" ]]; then
        while IFS= read -r _ctx_granted; do
            [[ -z "$_ctx_granted" ]] && continue
            case ",$plan_files_csv," in
                *",$_ctx_granted,"*) ;;
                *) plan_files_csv="${plan_files_csv:+$plan_files_csv,}$_ctx_granted" ;;
            esac
        done < "$ZBUILD_SCOPE_EXPANSION_GRANT"
        emit_event "build.scope_grant_applied" "plugin=build" \
            "grant_file=$ZBUILD_SCOPE_EXPANSION_GRANT" >/dev/null 2>&1 || true
    fi
}
