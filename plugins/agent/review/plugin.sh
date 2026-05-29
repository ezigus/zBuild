#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/review — review stage plugin (ADR-013, issue #343)         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Examines diff + plan + test results and produces review.json with a verdict:
#   approve         — diff implements plan; tests pass; safe to open PR
#   request_changes — fixable issues found; not blocking
#   block           — critical issues; must not proceed to PR
#
# Manifest: plugins/agent/review/manifest.yaml
# ADR refs: ADR-001 (plugin contract), ADR-003 (tier), ADR-004 (redaction),
#           ADR-013 (stage list, review = T2 agent)

[[ -n "${_ZBUILD_REVIEW_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_REVIEW_DIR="$_ZBUILD_PLUGIN_DIR"
_REVIEW_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_REVIEW_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_REVIEW_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_REVIEW_ROOT/core/router/route.sh"

# Valid verdict values per manifest config.valid_verdicts
_REVIEW_VALID_VERDICTS="approve request_changes block"

# ─── init ───────────────────────────────────────────────────────────────────
review_init() {
    export ZBUILD_PLUGIN="review"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=review"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
# Hook called by the pipeline runner: review_run(stage, state_file)
# Derives artifact paths from state_dir and delegates to the inner function.
review_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "review_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    _review_run_inner \
        "$state_dir/scope-manifest.md" \
        "$artifact_dir/plan.json" \
        "$artifact_dir/diff.patch" \
        "$artifact_dir/test-results.json" \
        "$artifact_dir/review.json" \
        "$artifact_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = plan.json path
#   $3 = diff.patch path
#   $4 = test-results.json path
#   $5 = output review.json path
#   $6 = artifact_dir (for intermediate files)
_review_run_inner() {
    local scope_manifest="$1"
    local plan_json_path="$2"
    local diff_patch_path="$3"
    local test_results_json_path="$4"
    local output_review_json="$5"
    local artifact_dir="${6:-$(dirname "$output_review_json")}"

    if [[ -z "$output_review_json" ]]; then
        error "_review_run_inner: output path required"
        return 2
    fi

    mkdir -p "$artifact_dir"

    # ─── Read input files (missing files handled gracefully) ─────────────────
    local plan_content diff_content test_content
    if [[ -f "$plan_json_path" ]]; then
        plan_content="$(cat "$plan_json_path")"
    else
        warn "review_run: plan.json not found at $plan_json_path; using empty"
        plan_content="{}"
    fi

    if [[ -f "$diff_patch_path" ]]; then
        diff_content="$(cat "$diff_patch_path")"
    else
        warn "review_run: diff.patch not found at $diff_patch_path; using empty"
        diff_content="(no diff available)"
    fi

    if [[ -f "$test_results_json_path" ]]; then
        test_content="$(cat "$test_results_json_path")"
    else
        warn "review_run: test-results.json not found; treating as test failure"
        test_content='{"status":"unknown","passed":0,"failed":0,"note":"test results missing -- treated as failure"}'
    fi

    # ─── Build prompt ────────────────────────────────────────────────────────
    local _review_instructions
    _review_instructions="$(cat <<'REVIEW_PROMPT'
You are a code review agent. Examine the diff to determine whether it correctly
implements the plan. Respond with a SINGLE JSON object and nothing else —
no markdown code fences, no commentary before or after, no tool calls.

Required JSON schema:

  {
    "verdict": "approve" | "request_changes" | "block",
    "confidence": <float 0.0-1.0>,
    "issues": ["<string>", ...],
    "summary": "<string>"
  }

Rules:
- `schema_version` is implicit (1).
- `verdict` MUST be exactly one of: approve, request_changes, block.
- `issues` is an array of strings; empty array [] if no issues found.
- `confidence` is a float between 0.0 and 1.0.
- Do not include reasoning, explanations, or prose — just the JSON.

Verdict definitions:
  approve         — diff implements the plan; tests pass; safe to open PR
  request_changes — fixable issues found; not blocking but need attention
  block           — critical issues; must not proceed to PR

REVIEW_PROMPT
)"
    local prompt
    printf -v prompt '%s\nPlan:\n%s\n\nDiff:\n%s\n\nTest results:\n%s\n' \
        "$_review_instructions" \
        "$plan_content" \
        "$diff_content" \
        "$test_content"

    # Write prompt to a temp file for redaction (apply_scope_redaction takes file paths)
    local prompt_file="$artifact_dir/review-prompt.txt"
    printf '%s\n' "$prompt" > "$prompt_file"

    # ─── Redaction chokepoint (REQUIRED — refuse to call LLM without it) ────
    local redacted_prompt_file="$artifact_dir/review-prompt.redacted.txt"
    if ! apply_scope_redaction "$prompt_file" "$redacted_prompt_file" "$scope_manifest" "" "0"; then
        error "review_run: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=review" "reason=redaction_failed"
        return 1
    fi

    local redacted_prompt
    redacted_prompt="$(cat "$redacted_prompt_file")"

    # ─── Route to LLM (T2 per manifest config.tier_default) ─────────────────
    local tier="${ZBUILD_REVIEW_TIER:-T2}"
    local raw_response="" router_rc=0
    raw_response="$(route_to_model "$tier" "$redacted_prompt" 2>/dev/null)" || router_rc=$?

    # ─── Parse verdict from LLM response ────────────────────────────────────
    local verdict="" confidence="" issues_json="[]" summary=""

    if [[ $router_rc -eq 0 && -n "$raw_response" ]]; then
        # Strip markdown code fences if present
        local stripped
        stripped="$(printf '%s' "$raw_response" \
            | sed 's/^[[:space:]]*```json[[:space:]]*//' \
            | sed 's/^[[:space:]]*```[[:space:]]*//'     \
            | sed 's/[[:space:]]*```[[:space:]]*$//')"

        verdict="$(printf '%s' "$stripped" \
            | jq -r '.verdict // empty' 2>/dev/null || true)"
        confidence="$(printf '%s' "$stripped" \
            | jq -r '.confidence // 0.5' 2>/dev/null || echo "0.5")"
        local issues_raw
        issues_raw="$(printf '%s' "$stripped" \
            | jq -r '.issues // [] | tojson' 2>/dev/null || true)"
        if printf '%s' "$issues_raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
            issues_json="$issues_raw"
        fi
        summary="$(printf '%s' "$stripped" \
            | jq -r '.summary // ""' 2>/dev/null || true)"
    elif [[ $router_rc -eq 1 ]]; then
        warn "review_run: router rc=1 (recoverable); defaulting verdict"
    elif [[ $router_rc -ne 0 ]]; then
        error "review_run: router rc=$router_rc (fatal); refusing to emit"
        emit_event "plugin.run.error" "plugin=review" \
            "reason=router_fatal" "router_rc=$router_rc"
        return 1
    fi

    # ─── Validate verdict; default to request_changes if invalid ─────────────
    local verdict_valid=false
    local v
    for v in $_REVIEW_VALID_VERDICTS; do
        if [[ "$verdict" == "$v" ]]; then
            verdict_valid=true
            break
        fi
    done

    if ! $verdict_valid; then
        warn "review_run: invalid verdict '${verdict}' from LLM; defaulting to request_changes"
        local original_verdict="$verdict"
        verdict="request_changes"
        confidence="${confidence:-0.5}"
        # Prepend a note about the invalid verdict to issues
        local note="LLM returned invalid verdict '${original_verdict}'; defaulted to request_changes"
        issues_json="$(printf '%s' "$issues_json" \
            | jq --arg n "$note" '. + [$n]' 2>/dev/null \
            || jq -n --arg n "$note" '[$n]')"
        if [[ -z "$summary" ]]; then
            summary="Verdict defaulted: LLM response was not a valid verdict value."
        fi
    fi

    # ─── Write review.json ───────────────────────────────────────────────────
    local issues_count
    issues_count="$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)"

    # Coerce confidence to numeric 0..1; default 0.5 for non-numeric values.
    local confidence_num
    confidence_num="$(printf '%s' "${confidence:-0.5}" \
        | awk 'BEGIN{v=0.5} /^[0-9.]+$/{v=$1; if(v>1)v=1; if(v<0)v=0} END{printf "%g",v}')"

    jq -n \
        --arg verdict "$verdict" \
        --argjson confidence "$confidence_num" \
        --argjson issues "$issues_json" \
        --arg summary "$summary" \
        '{
            schema_version: 1,
            verdict: $verdict,
            confidence: $confidence,
            issues: $issues,
            summary: $summary
        }' | atomic_write "$output_review_json"

    emit_event "plugin.run.complete" "plugin=review" \
        "verdict=$verdict" \
        "issues_count=$issues_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
review_finalize() {
    emit_event "plugin.finalize.complete" "plugin=review"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
review_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=review"
    return 0
}
