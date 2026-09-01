#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/security-lens — first POC of the migration loop            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# This plugin proves the end-to-end zBuild migration loop:
#   - Manifest declares requires.core: [redaction, event-bus, state]
#   - Plugin reads input through the redaction chokepoint
#   - Plugin emits events via the event bus
#   - Output is a typed findings.json artifact
#
# The actual LLM call is stubbed in Phase 0 (we don't have the router yet).
# The keeper's behavior is the prompt content + the chokepoint wiring + the
# findings.json schema — those are testable today.

[[ -n "${_ZBUILD_SECURITY_LENS_LOADED:-}" ]] && return 0
_ZBUILD_SECURITY_LENS_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_SEC_LENS_DIR="$_ZBUILD_PLUGIN_DIR"
_SEC_LENS_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_SEC_LENS_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_SEC_LENS_ROOT/core/router/route.sh"
# #721: strip stage-io banners and ANSI from input before LLM prompt.
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_SEC_LENS_ROOT/scripts/lib/test-output-sanitize.sh"
# ADR-028 v1.2 (#944): shared LLM-agent framework for envelope recovery.
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_SEC_LENS_ROOT/scripts/lib/llm-agent.sh"

# ─── _security_lens_envelope_schema_ok (#944, ADR-028 v1.2) ─────────────────
# Gate for _llm_envelope_parse --schema-gate. Security-lens has no schema_version
# in the LLM response, so the gate checks type==object and findings:array only.
# This is sufficient to distinguish the real envelope from a brace-bearing
# postamble (which is unlikely to carry a findings array).
_security_lens_envelope_schema_ok() {
    printf '%s' "${1:-}" | jq -e '
        type == "object"
        and (.findings | type == "array")
    ' >/dev/null 2>&1
}

# ─── run ────────────────────────────────────────────────────────────────────
# Hook called by the pipeline runner: security_lens_run(stage, state_file)
# Derives artifact paths from state_dir and delegates to the inner function.
security_lens_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "security_lens_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/security-lens-summary.md}" "security-lens" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"
    # Partition by platform when running in fanout mode so parallel invocations
    # don't overwrite each other. Filename still matches the *-findings.json
    # glob that the output plugin uses to collect results.
    local platform_infix="${ZBUILD_TARGET_PLATFORM:+-${ZBUILD_TARGET_PLATFORM}}"
    _security_lens_run_inner \
        "$state_dir/intake.md" \
        "$state_dir/scope-manifest.md" \
        "$artifacts_dir/security${platform_infix}-findings.json" \
        "$artifacts_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = input file (raw text to analyze, e.g., a git diff or file list)
#   $2 = scope_manifest path
#   $3 = output findings.json path
#   $4 = (optional) artifact dir for intermediate redacted prompt
_security_lens_run_inner() {
    local input="$1"
    # $2 (scope_manifest) is accepted for call-compat but no longer read: ADR-043
    # makes the router redact the assembled prompt by construction.
    local output="$3"
    local artifact_dir="${4:-$(dirname "$output")}"

    if [[ -z "$input" || -z "$output" ]]; then
        error "security_lens_run: requires <input> <scope_manifest> <output>"
        return 2
    fi

    mkdir -p "$artifact_dir"

    # ─── Build prompt: system prompt + input. ADR-043: redaction is owned by
    # the router (route_to_model) — this stage passes the RAW assembled text. ─
    local sys_prompt input_content prompt
    sys_prompt="$(cat "$_SEC_LENS_DIR/prompts/security.md")"
    input_content="$(cat "$input")"
    # #721: strip OOS-marker tags and ANSI codes — input may carry
    # <out-of-scope-context> wrappers and ANSI fragments from terminal capture.
    input_content="$(printf '%s' "$input_content" | _zbuild_sanitize_for_llm)"
    prompt="${sys_prompt}"$'\n\n'"${input_content}"

    # ─── Route to LLM (hardcoded T3, matching manifest config.tier_default) ──
    # ZBUILD_SECURITY_LENS_TIER overrides for testing. Manifest-driven tier
    # read is deferred to a follow-up issue.
    # ADR-018 (#476): Pattern 1 stages with tools MUST use JSON envelope mode.
    # Without the JSON envelope + .result extraction, reasoning turns leak
    # as a prose preamble that breaks the strict-JSON parser below.
    # Save/restore so an outer caller's env intent is preserved.
    local tier; tier="$(resolve_tier security-lens "$_SEC_LENS_DIR")" || return 1
    local raw_response="" router_rc=0
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    # ADR-018 (#483): tag the router's capture symmetrically with plan/review.
    # The "security-lens" renderer is NOT yet registered — render_artifact will
    # passthrough and emit stage.io.render.fallback (acceptable; follow-up
    # issue tracks adding render_security_lens_md). Tagging now keeps the
    # opt-in surface symmetric across all Pattern 1 stages.
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_ARTIFACT_ID=security-lens
    # #491: do NOT redirect route_to_model's stderr — see ADR-015 §v4.
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

    # ─── Parse: strip fences, extract .findings, validate array ───────────
    # Ported from legacy/scripts/lib/compound-audit.sh:160-182
    local findings_json="[]"
    if [[ $router_rc -eq 0 && -n "$raw_response" ]]; then
        # ADR-028 v1.2 (#944): use _llm_envelope_parse --schema-gate so
        # _llm_recover_envelope_json fires when LAST-wins selects a postamble
        # instead of the real findings envelope.
        # shellcheck disable=SC2034  # _sl_prose is a required output-param of
        # _llm_envelope_parse; security-lens emits no prose sidecar (only impact does).
        local stripped _sl_prose extracted
        _llm_envelope_parse --schema-gate _security_lens_envelope_schema_ok \
            "$raw_response" stripped _sl_prose
        extracted="$(printf '%s' "$stripped" \
            | jq -r '.findings // [] | tojson' 2>/dev/null || true)"
        if printf '%s' "$extracted" | jq -e 'type == "array"' >/dev/null 2>&1; then
            findings_json="$extracted"
        else
            warn "security_lens_run: LLM response unparseable; using empty findings"
        fi
    elif [[ $router_rc -eq 1 ]]; then
        warn "security_lens_run: router rc=1 (recoverable); using empty findings"
    elif [[ $router_rc -ne 0 ]]; then
        error "security_lens_run: router rc=$router_rc (fatal); refusing to emit"
        stage_summary_write "$artifact_dir/security-lens-summary.md" "security-lens" "error" \
            "the model call failed, so no security review happened" \
            "This lens contributed no findings; absence here is not evidence of safety."
        emit_event "plugin.result" "verdict=error" "plugin=security-lens" \
            "reason=router_fatal" "router_rc=$router_rc"
        return 1
    fi

    # ─── Write findings.json (schema unchanged + stub:false marker) ───────
    local now findings_count
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    findings_count="$(printf '%s' "$findings_json" | jq 'length' 2>/dev/null || echo 0)"

    jq -n \
        --arg ts "$now" \
        --argjson findings "$findings_json" \
        '{
            schema_version: 1,
            plugin_id: "security-lens",
            generated_at: $ts,
            findings: $findings,
            stub: false
        }' | atomic_write "$output"

    stage_summary_write "$artifact_dir/security-lens-summary.md" "security-lens" "pass" \
        "reviewed the change for security issues — $findings_count finding(s)" \
        "$(printf -- '- artifact: findings.json')"
    emit_event "plugin.result" "plugin=security-lens" \
        "findings_count=$findings_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
security_lens_cleanup() {
    # No self-emit (#1705): plugin_hook_call already brackets this hook with
    # plugin.cleanup.start/complete. A second `complete` from here is the same
    # two-emitters-one-name collision the run pair was filed for.
    return 0
}
