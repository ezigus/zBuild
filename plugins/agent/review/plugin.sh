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
# #506: shared numstat banner formatter (operator-banner override input).
# shellcheck source=../../../scripts/lib/numstat-format.sh
source "$_REVIEW_ROOT/scripts/lib/numstat-format.sh"

# Valid verdict values per manifest config.valid_verdicts
_REVIEW_VALID_VERDICTS="approve request_changes block"

# ─── _review_derive_test_status ──────────────────────────────────────────────
# #485: Map the test plugin's test-results.json into one of three
# review-side states:
#   passed   — tests ran and verdict=pass
#   failed   — tests ran and verdict in {fail, error}
#   unknown  — test-results.json missing or has no usable .verdict
#
# Test plugin (plugins/tool/test) writes `.verdict` (pass|fail|error). Review
# does NOT read `.status`; that field has never been written by the producer.
# Fail-closed: anything we cannot positively interpret as `pass` is treated as
# at-least-`unknown`; verdict=error specifically maps to `failed` so a
# misconfigured run cannot smuggle approve through.
#
# #569 / ADR-019 §7 amendment (#572): when test-assessment.json is also present
# in the artifact dir, PREFER its .verdict over test-results.json. The
# test_assessment LLM stage (#567) interprets test output and is the
# authoritative signal. Mapping:
#   assessment.verdict=pass         → "passed"
#   assessment.verdict=fail|error   → "failed"
#   assessment.verdict=inconclusive → "unknown"
#   assessment absent/malformed/unknown verdict → fall through to test-results
# Fail-closed is preserved: a malformed assessment never coerces approve
# (jq returns empty → fall through, where the test-results check still applies).
#
# Usage: _review_derive_test_status <test_results_json_path>
# Prints: passed | failed | unknown
_review_derive_test_status() {
    local path="$1"

    # #569: precedence — check test-assessment.json first. Resolve from the
    # artifact dir (dirname of test-results path); honor ZBUILD_ARTIFACT_DIR
    # as a fallback when the test-results path is absent or unusable.
    local _art_dir=""
    if [[ -n "$path" ]]; then
        _art_dir="$(dirname "$path")"
    fi
    if [[ -z "$_art_dir" || ! -d "$_art_dir" ]]; then
        _art_dir="${ZBUILD_ARTIFACT_DIR:-}"
    fi
    if [[ -n "$_art_dir" ]]; then
        local _assessment="$_art_dir/test-assessment.json"
        if [[ -s "$_assessment" ]]; then
            local _av
            _av="$(jq -r '.verdict // empty' "$_assessment" 2>/dev/null || true)"
            case "$_av" in
                pass)         printf 'passed\n';  return 0 ;;
                fail|error)   printf 'failed\n';  return 0 ;;
                inconclusive) printf 'unknown\n'; return 0 ;;
                *) ;;  # fall through to test-results.json
            esac
        fi
    fi

    if [[ -z "$path" || ! -f "$path" ]]; then
        printf 'unknown\n'
        return 0
    fi
    local v jq_err
    # #527 silent-failure CRIT #5: jq parse errors must not be silently swallowed;
    # emit a discoverable event so a malformed test-results.json is visible in the
    # post-mortem event log. Behavior on parse error is preserved (v="" → unknown,
    # which the ADR-019 fail-closed gate coerces approve → request_changes).
    jq_err="$(mktemp 2>/dev/null || printf '/tmp/zb-review-jq.%s' "$$")"
    if v="$(jq -r '.verdict // empty' "$path" 2>"$jq_err")"; then
        :
    else
        local err_msg
        err_msg="$(tr -d '\n' < "$jq_err" 2>/dev/null | head -c 200)"
        emit_event "review.jq.parse_error" \
            "plugin=review" \
            "stage=review" \
            "path=$path" \
            "error=${err_msg:-jq_failed}" 2>/dev/null || true
        v=""
    fi
    rm -f "$jq_err" 2>/dev/null || true
    case "$v" in
        pass)        printf 'passed\n' ;;
        fail|error)  printf 'failed\n' ;;
        *)           printf 'unknown\n' ;;
    esac
    return 0
}

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
        # #527 silent-failure CRIT #4: ALWAYS emit a discoverable event when
        # test-results.json is missing so operators can spot it in event-log
        # post-mortems regardless of which verdict path runs downstream. The
        # ADR-019 fail-closed coercion still fires below; this event is purely
        # for observability (no behavior change).
        emit_event "review.test_status.missing" \
            "plugin=review" \
            "stage=review" \
            "path=$test_results_json_path" \
            "reason=file_absent"
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
- An approve verdict requires that test results show tests passed; if test results are missing, unknown, or failed, return request_changes (not approve).

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

    # ── #506: numstat banner override ───────────────────────────────────────
    # The review LLM needs the full diff (above), but the operator-visible
    # stage_io banner should show a compact numstat-style file-change
    # summary, NOT every diff hunk. Compute `git diff <merge-base> HEAD
    # --numstat` and format it via the shared formatter, then export
    # ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE so _stage_io_stdout_begin uses
    # it for the on-screen banner. The persisted artifact + LLM prompt
    # are unchanged.
    local _prev_banner_override="${ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE-__UNSET__}"
    _review_set_banner_override "$scope_manifest" "$diff_patch_path"

    # #491: do NOT redirect route_to_model's stderr — see ADR-015 §v4.
    raw_response="$(route_to_model "$tier" "$redacted_prompt")" || router_rc=$?

    # Restore env immediately after route returns.
    if [[ "$_prev_banner_override" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE
    else
        export ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE="$_prev_banner_override"
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

    # ─── #485 fail-closed: coerce approve → request_changes when tests
    # did not positively pass. block is the strictest floor and is NOT
    # demoted here (ADR-019). LLM confidence is preserved verbatim — it
    # remains an advisory signal independent of the post-validation result.
    local test_status
    test_status="$(_review_derive_test_status "$test_results_json_path")"
    if [[ "$verdict" == "approve" && ( "$test_status" == "unknown" || "$test_status" == "failed" ) ]]; then
        local original_verdict_485="$verdict"
        local test_exit_code_485=""
        if [[ -f "$test_results_json_path" ]]; then
            test_exit_code_485="$(jq -r '.exit_code // empty' "$test_results_json_path" 2>/dev/null || true)"
        fi
        warn "review_run: verdict coerced from approve to request_changes (test_status=$test_status)"
        verdict="request_changes"
        local coerce_note="tests did not pass (test_status=$test_status); approve coerced to request_changes"
        issues_json="$(printf '%s' "$issues_json" \
            | jq --arg n "$coerce_note" '. + [$n]' 2>/dev/null \
            || jq -n --arg n "$coerce_note" '[$n]')"
        # Prepend coercion note to summary so the LLM's reasoning stays visible.
        if [[ -n "$summary" ]]; then
            summary="[coerced: tests $test_status] $summary"
        else
            summary="[coerced: tests $test_status]"
        fi
        emit_event "review.test_status.coerced" \
            "plugin=review" \
            "stage=review" \
            "original_verdict=$original_verdict_485" \
            "coerced_verdict=request_changes" \
            "test_status=$test_status" \
            "test_exit_code=$test_exit_code_485"
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

# ─── _review_set_banner_override ────────────────────────────────────────────
# #506: Compute a numstat-style file-change summary for the operator-visible
# stage_io banner and export it via ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE. The
# review LLM still receives the full diff via the redacted prompt — this
# override ONLY swaps the on-screen banner body.
#
# Args:
#   $1 = scope_manifest path (for the allowlist; reconstructed from `+` lines
#        the same way _review_audit_tool_use does)
#   $2 = diff_patch_path     (used as the --full-at pointer in the
#        truncation hint so operators can grep where the full diff lives)
#
# Strategy:
#   - Resolve merge-base against the default branch (origin/main, then main,
#     then HEAD~1). If none resolves, fall back to `git diff HEAD --numstat`.
#   - Format via shared format_numstat with --event-prefix review so a
#     truncation fires as `review.numstat.truncated`.
#   - Wrap the body in `── changed files ──` heading + a trailing blank line
#     so the override is visually distinct from the raw-prompt body.
#
# Fail-soft: any git error → empty override (banner falls back to raw prompt).
_review_set_banner_override() {
    local scope_manifest="$1"
    local diff_patch_path="$2"

    # Reconstruct allowlist from scope manifest `+` lines.
    local -a _allowed_files=()
    if [[ -n "$scope_manifest" && -f "$scope_manifest" ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -z "$_line" ]] && continue
            _allowed_files+=( "$_line" )
        done < <(awk '/^\+/ { sub(/^\+[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); if (length($0)) print $0 }' "$scope_manifest" 2>/dev/null || true)
    fi

    # Resolve a merge-base ref. Best-effort; never propagate git errors.
    local _base="" _candidate
    for _candidate in "origin/main" "main" "HEAD~1"; do
        if git rev-parse --verify "$_candidate" >/dev/null 2>&1; then
            _base="$(git merge-base "$_candidate" HEAD 2>/dev/null || true)"
            [[ -n "$_base" ]] && break
        fi
    done

    local _raw=""
    if [[ -n "$_base" ]]; then
        _raw="$(git diff "$_base" HEAD --numstat 2>/dev/null || true)"
    fi
    if [[ -z "$_raw" ]]; then
        _raw="$(git diff HEAD --numstat 2>/dev/null || true)"
    fi

    # Format. Empty _raw → formatter still emits a "total: 0 files…" footer
    # which is the honest signal to the operator.
    local _formatted
    _formatted="$(format_numstat "$_raw" _allowed_files \
        --event-prefix "review" \
        --full-at "${diff_patch_path:-diff.patch}")"

    export ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE=$'── changed files ──\n'"$_formatted"
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
