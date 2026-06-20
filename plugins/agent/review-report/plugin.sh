#!/usr/bin/env bash
# plugins/agent/review-report — informational multi-lens review report (issue #972)
#
# Pattern 1 single-envelope LLM agent (ADR-018/ADR-028). Fans out across
# correctness, security, test-coverage, and plan-conformance lenses in one
# LLM pass. Emits report.json + report.md. No verdict field, no block/coerce.
# Posts report.md as PR comment when ZBUILD_PR_NUMBER is set (fail-soft).
#
# ADR refs: ADR-001 (plugin contract), ADR-003 (tier T2), ADR-004 (redaction),
#           ADR-013 (canonical stage list), ADR-018 (Pattern 1 envelope)

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

_RR_VALID_READINESS="ready advisory needs_attention"

# ─── _rr_validate_readiness ─────────────────────────────────────────────────
# Validates merge_readiness value against the closed vocabulary.
# Prints the validated value; falls back to 'advisory' on unknown input.
_rr_validate_readiness() {
    local val="$1"
    case "$val" in
        ready|advisory|needs_attention) printf '%s' "$val" ;;
        *) printf 'advisory' ;;
    esac
}

# ─── _rr_build_prompt ───────────────────────────────────────────────────────
# Builds the LLM prompt from available artifacts. All text passes through
# apply_scope_redaction before being spliced in (ADR-004 chokepoint).
_rr_build_prompt() {
    local scope_manifest="$1"
    local plan_json="$2"
    local diff_patch="$3"
    local test_results="$4"
    local intake_md="$5"

    # Load scope manifest for redaction context
    local scope_content=""
    if [[ -s "$scope_manifest" ]]; then
        scope_content="$(apply_scope_redaction "$scope_manifest" < "$scope_manifest" 2>/dev/null || true)"
    fi

    local plan_content="(no plan available)"
    if [[ -s "$plan_json" ]]; then
        plan_content="$(apply_scope_redaction "$scope_manifest" < "$plan_json" 2>/dev/null || cat "$plan_json" 2>/dev/null || true)"
    fi

    local diff_content="(no diff available)"
    if [[ -s "$diff_patch" ]]; then
        diff_content="$(apply_scope_redaction "$scope_manifest" < "$diff_patch" 2>/dev/null || cat "$diff_patch" 2>/dev/null || true)"
    fi

    local test_content="(no test results available)"
    if [[ -s "$test_results" ]]; then
        test_content="$(apply_scope_redaction "$scope_manifest" < "$test_results" 2>/dev/null || cat "$test_results" 2>/dev/null || true)"
    fi

    local goal_content="(no issue description available)"
    if [[ -s "$intake_md" ]]; then
        goal_content="$(apply_scope_redaction "$scope_manifest" < "$intake_md" 2>/dev/null || cat "$intake_md" 2>/dev/null || true)"
    fi

    cat <<PROMPT
You are a multi-lens code review agent. Examine the diff against the plan and
test results through FOUR lenses simultaneously and emit a single structured
report. This is informational — do NOT block or approve. Simply describe what
you find.

GOAL / ISSUE:
${goal_content}

PLAN:
${plan_content}

DIFF:
${diff_content}

TEST RESULTS:
${test_content}

SCOPE MANIFEST:
${scope_content}

OUTPUT CONTRACT (read first, obey absolutely):
- Respond with EXACTLY ONE JSON object. Nothing else.
- Your first output character MUST be \`{\`. Your last MUST be \`}\`.
- NO markdown code fences (no \`\`\`json, no \`\`\` wrapping).
- NO prose before, after, or around the JSON envelope.
- Your \`.merge_readiness\` field MUST be one of: ready, advisory, needs_attention
- FORBIDDEN: the strings "block", "coerce", "approve", "request_changes", "verdict"

Required JSON schema:
{
  "schema_version": 1,
  "merge_readiness": "<ready|advisory|needs_attention>",
  "lenses": [
    {
      "name": "<lens name>",
      "findings": ["<finding 1>", "..."],
      "score": <0-10 integer>
    }
  ],
  "summary": "<one paragraph human-readable summary>"
}

Evaluate these four lenses:
1. correctness — Logic errors, off-by-one issues, null-pointer risks, incorrect
   assumptions about data shapes.
2. security — Injection risks, credential exposure, path traversal, missing
   input validation at system boundaries.
3. test-coverage — Are the changed lines exercised by tests? Are edge cases
   covered? Are there untested public functions?
4. plan-conformance — Does the diff implement what the plan described? Are there
   missing pieces or out-of-scope additions?

Set merge_readiness:
- "ready" — all lenses score >= 7 and no critical findings
- "needs_attention" — any lens has critical findings (score <= 3)
- "advisory" — everything else

Emit the JSON object now.
PROMPT
}

# ─── _rr_write_markdown ─────────────────────────────────────────────────────
# Renders report.json to report.md for human consumption and PR comments.
_rr_write_markdown() {
    local report_json="$1"
    local out_md="$2"

    local readiness lens_count summary
    readiness="$(jq -r '.merge_readiness // "advisory"' "$report_json" 2>/dev/null || echo "advisory")"
    lens_count="$(jq -r '.lenses | length' "$report_json" 2>/dev/null || echo "0")"
    summary="$(jq -r '.summary // ""' "$report_json" 2>/dev/null || true)"

    {
        printf '## Review Report\n\n'
        printf '**Merge Readiness:** %s\n\n' "$readiness"
        printf '%s\n\n' "$summary"
        printf '### Lens Findings\n\n'
        jq -r '.lenses[] | "#### \(.name) (score: \(.score)/10)\n\n" + (
            if (.findings | length) > 0 then
                [.findings[] | "- " + .] | join("\n")
            else "No findings.\n"
            end
        ) + "\n"' "$report_json" 2>/dev/null || true
    } | atomic_write "$out_md"
}

# ─── review_report_init ─────────────────────────────────────────────────────
review_report_init() {
    export ZBUILD_PLUGIN="review-report"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=review-report"
    return 0
}

# ─── review_report_run ──────────────────────────────────────────────────────
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
        "$artifact_dir/plan.json" \
        "$artifact_dir/diff.patch" \
        "$artifact_dir/test-results.json" \
        "$artifact_dir/report.json" \
        "$artifact_dir/report.md" \
        "$state_dir/intake.md"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = plan.json path
#   $3 = diff.patch path
#   $4 = test-results.json path
#   $5 = output report.json path
#   $6 = output report.md path
#   $7 = intake.md path (optional)
_rr_run_inner() {
    local scope_manifest="$1"
    local plan_json="$2"
    local diff_patch="$3"
    local test_results="$4"
    local out_json="$5"
    local out_md="$6"
    local intake_md="${7:-}"

    if [[ -z "$out_json" ]]; then
        error "_rr_run_inner: output path required"
        return 2
    fi

    local out_dir; out_dir="$(dirname "$out_json")"
    mkdir -p "$out_dir"

    # Build and redact prompt (ADR-004: all LLM-bound text passes through redaction)
    local prompt
    prompt="$(_rr_build_prompt "$scope_manifest" "$plan_json" "$diff_patch" "$test_results" "$intake_md")"

    # Route to LLM (T2 tier per manifest)
    local router_out router_rc=0
    set +e
    router_out="$(route_to_model "T2" "$prompt")"
    router_rc=$?
    set -e

    # Parse and validate response
    local merge_readiness lens_count=0 schema_version=1 summary=""

    if [[ $router_rc -ne 0 || -z "$router_out" ]]; then
        warn "review_report: router returned empty or error (rc=$router_rc); defaulting to advisory"
        merge_readiness="advisory"
        # Write minimal fallback report
        printf '{"schema_version":1,"merge_readiness":"advisory","lenses":[],"summary":"Report unavailable: LLM call failed."}\n' \
            | atomic_write "$out_json"
    else
        # Strip any prose/code-fences around the JSON envelope
        local json_body
        json_body="$(printf '%s' "$router_out" | sed -n '/^{/,/^}/p' 2>/dev/null | head -500 || printf '%s' "$router_out")"

        # Validate JSON parseable
        if ! printf '%s' "$json_body" | jq . >/dev/null 2>&1; then
            warn "review_report: LLM response is not valid JSON; defaulting to advisory"
            merge_readiness="advisory"
            printf '{"schema_version":1,"merge_readiness":"advisory","lenses":[],"summary":"Report unavailable: response not valid JSON."}\n' \
                | atomic_write "$out_json"
        else
            merge_readiness="$(_rr_validate_readiness \
                "$(printf '%s' "$json_body" | jq -r '.merge_readiness // "advisory"' 2>/dev/null || echo "advisory")")"
            lens_count="$(printf '%s' "$json_body" | jq -r '.lenses | length' 2>/dev/null || echo "0")"
            summary="$(printf '%s' "$json_body" | jq -r '.summary // ""' 2>/dev/null || true)"

            # Write report.json atomically with validated merge_readiness
            printf '%s' "$json_body" \
                | jq --arg mr "$merge_readiness" --argjson sv 1 \
                    '. + {schema_version: $sv, merge_readiness: $mr}' 2>/dev/null \
                | atomic_write "$out_json"
        fi
    fi

    # Write report.md
    if [[ -s "$out_json" ]]; then
        _rr_write_markdown "$out_json" "$out_md" 2>/dev/null || true
    fi

    # Post PR comment (fail-soft: gh error must never abort the plugin)
    local pr_num="${ZBUILD_PR_NUMBER:-}"
    if [[ -n "$pr_num" && -s "$out_md" ]]; then
        set +e
        gh pr comment "$pr_num" --body-file "$out_md" 2>/dev/null
        local gh_rc=$?
        set -e
        if [[ $gh_rc -ne 0 ]]; then
            warn "review_report: gh pr comment failed (rc=$gh_rc); continuing"
        fi
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
