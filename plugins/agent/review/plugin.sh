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
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_REVIEW_ROOT/scripts/lib/artifact-render.sh"

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
    # ADR-018 (#469): Pattern 1 — one-shot with tools. Read is available for
    # diff verification; Edit/Write/Bash are forbidden. Final-output contract
    # remains a SINGLE JSON object with no fences and no prose.
    local _review_instructions
    _review_instructions="$(cat <<'REVIEW_PROMPT'
You are a code review agent. Examine the diff to determine whether it correctly
implements the plan.

Final-output contract:
Your FINAL response must be a SINGLE JSON object — no markdown code fences, no
prose before or after the JSON.

Tool-use policy:
You MAY use the Read tool to inspect files referenced by the diff to verify
the change implements the plan. Do NOT call Edit, Write, or Bash. Limit reads
to paths in the diff or in the scope manifest.

Scope redaction:
Files outside the declared scope appear in the diff as `<out-of-scope-context>`
markers — do NOT attempt to Read those paths.

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
- Do not include reasoning, explanations, or prose in the FINAL response —
  just the JSON.
- Your response MUST begin with `{` and contain nothing other than the JSON object — no leading prose, no trailing prose, no markdown fences.

Verdict definitions:
  approve         — diff implements the plan; tests pass; safe to open PR
  request_changes — fixable issues found; not blocking but need attention
  block           — critical issues; must not proceed to PR

REVIEW_PROMPT
)"
    # ADR-018: render plan and diff as markdown for LLM consumption. Test
    # results stay as raw fenced text — no test-results renderer (see #470).
    local plan_md diff_md
    plan_md="$(render_artifact plan "$plan_content")"
    diff_md="$(render_artifact diff "$diff_content")"
    local prompt
    printf -v prompt '%s\nPlan:\n%s\n\nDiff:\n%s\n\nTest results:\n%s\n' \
        "$_review_instructions" \
        "$plan_md" \
        "$diff_md" \
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
    # ADR-018 (#476): Pattern 1 stages with tools MUST use JSON envelope mode.
    # Envelope (JSON output mode + .result extraction) is unconditional now;
    # without it the model streams reasoning turns as prose before the final
    # JSON and the parser below rejects the response.
    #
    # ADR-018 (#469): opt-in tool-use audit gated by ZBUILD_REVIEW_AUDIT_TOOL_USE=1
    # additionally exports ZBUILD_ROUTER_TOOL_USES_FILE so the router writes
    # tool_uses[] to a side-channel file we can parse back here ($() discards
    # subshell state otherwise).
    local tier="${ZBUILD_REVIEW_TIER:-T2}"
    local raw_response="" router_rc=0
    local _audit_enabled=0 _audit_tool_uses_file=""
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    # ADR-018 (#483): tag the router's capture so review's own banner renders
    # the review.json output via render_review_md (mirror #476 save/restore).
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_ARTIFACT_ID=review
    if [[ "${ZBUILD_REVIEW_AUDIT_TOOL_USE:-0}" == "1" ]]; then
        _audit_enabled=1
        _audit_tool_uses_file="$artifact_dir/review-tool-uses.json"
        : > "$_audit_tool_uses_file"
        export ZBUILD_ROUTER_TOOL_USES_FILE="$_audit_tool_uses_file"
    fi
    raw_response="$(route_to_model "$tier" "$redacted_prompt" 2>/dev/null)" || router_rc=$?
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
    if [[ $_audit_enabled -eq 1 ]]; then
        unset ZBUILD_ROUTER_TOOL_USES_FILE
        _review_audit_tool_use "$_audit_tool_uses_file" "$scope_manifest" || true
    fi

    # #476 finding: distinguish "envelope returned empty .result" from
    # "router rc=non-zero" so an empty model output doesn't masquerade as a
    # legitimate verdict downstream.
    if [[ $router_rc -eq 0 && -z "$raw_response" ]]; then
        error "review_run: router returned empty .result envelope; refusing to emit verdict"
        emit_event "plugin.run.error" "plugin=review" "reason=empty_result_envelope"
        return 1
    fi

    # ─── Parse verdict from LLM response ────────────────────────────────────
    local verdict="" confidence="" issues_json="[]" summary=""

    if [[ $router_rc -eq 0 && -n "$raw_response" ]]; then
        # #478: slice the LAST top-level balanced JSON object out of the
        # response. Envelope mode (#476) separates reasoning turns from the
        # final turn; the model can still preface its JSON with prose
        # *inside* the final turn. Helper passes input through verbatim on
        # no-match so downstream parsing falls back to the existing defaults.
        local stripped
        stripped="$(printf '%s' "$raw_response" | extract_first_json_object)"

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

# ─── _review_audit_tool_use ─────────────────────────────────────────────────
# ADR-018 (#469): warn-only audit. Parses tool_uses[] (written by the router
# side-channel) and emits review.scope.violation for each Read whose
# input.file_path is NOT covered by the scope manifest allowlist. Does NOT
# coerce the verdict — downstream consumers decide. Fail-soft: any error is
# logged via warn() but the function still returns 0.
#
# Args:
#   $1 = tool_uses_file (json array; may be empty or missing)
#   $2 = scope_manifest path
_review_audit_tool_use() {
    local tool_uses_file="$1" scope_manifest="$2"

    [[ -z "$tool_uses_file" || ! -s "$tool_uses_file" ]] && return 0
    [[ -z "$scope_manifest" || ! -f "$scope_manifest" ]] && return 0

    # Allowlist: lines starting with '+' in the manifest (mirrors
    # apply_scope_redaction's parser).
    local allow_lines
    allow_lines="$(awk '/^\+/ { sub(/^\+[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); if (length($0)) print $0 }' "$scope_manifest" 2>/dev/null || true)"
    local scope_hash
    scope_hash="$(shasum -a 256 "$scope_manifest" 2>/dev/null | cut -d' ' -f1)"

    # Extract Read paths from tool_uses[]; skip non-Read calls.
    local read_paths
    read_paths="$(jq -r '
        if type == "array" then
            .[] | select(.name == "Read") | .input.file_path // empty
        else
            empty
        end
    ' "$tool_uses_file" 2>/dev/null || true)"

    [[ -z "$read_paths" ]] && return 0

    local path stripped in_scope a
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        stripped="${path#./}"
        in_scope=0
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            # Prefix match — `a` is the allowlist entry (e.g. "tests/"). The
            # case glob `"$a"*` expands to e.g. `tests/*` and matches when
            # `stripped` starts with `a`. Quote `a` so its own contents are
            # taken literally; only the trailing `*` is a glob.
            case "$stripped" in
                "$a"*) in_scope=1; break ;;
            esac
        done <<< "$allow_lines"
        if [[ $in_scope -eq 0 ]]; then
            emit_event "review.scope.violation" \
                "plugin=review" \
                "stage=review" \
                "path=$path" \
                "scope_hash=$scope_hash"
            warn "review_audit: out-of-scope Read on '$path' (warn-only; verdict unchanged)"
        fi
    done <<< "$read_paths"

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
