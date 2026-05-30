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
_SEC_LENS_DIR="$_ZBUILD_PLUGIN_DIR"
_SEC_LENS_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_SEC_LENS_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_SEC_LENS_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_SEC_LENS_ROOT/core/router/route.sh"

# ─── init ───────────────────────────────────────────────────────────────────
security_lens_init() {
    export ZBUILD_PLUGIN="security-lens"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=security-lens"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
# Hook called by the pipeline runner: security_lens_run(stage, state_file)
# Derives artifact paths from state_dir and delegates to the inner function.
security_lens_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "security_lens_run: state_file argument required"
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
    local scope_manifest="$2"
    local output="$3"
    local artifact_dir="${4:-$(dirname "$output")}"

    # Note: we deliberately do NOT validate $scope_manifest here. The redaction
    # chokepoint (ADR-004) refuses to emit when it's absent and returns 1.
    # Putting a separate check here would mask that signal and return code.
    if [[ -z "$input" || -z "$output" ]]; then
        error "security_lens_run: requires <input> <scope_manifest> <output>"
        return 2
    fi

    mkdir -p "$artifact_dir"
    local redacted="$artifact_dir/security-lens-prompt.redacted.txt"

    # ─── Redaction chokepoint (REQUIRED — refuse to call LLM without it) ────
    if ! apply_scope_redaction "$input" "$redacted" "$scope_manifest" "" "0"; then
        error "security_lens_run: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=security-lens" "reason=redaction_failed"
        return 1
    fi

    # ─── Build prompt: system prompt + redacted input ─────────────────────
    local sys_prompt redacted_content prompt
    sys_prompt="$(cat "$_SEC_LENS_DIR/prompts/security.md")"
    redacted_content="$(cat "$redacted")"
    prompt="${sys_prompt}"$'\n\n'"${redacted_content}"

    # ─── Route to LLM (hardcoded T3, matching manifest config.tier_default) ──
    # ZBUILD_SECURITY_LENS_TIER overrides for testing. Manifest-driven tier
    # read is deferred to a follow-up issue.
    # ADR-018 (#476): Pattern 1 stages with tools MUST use JSON envelope mode.
    # Without the JSON envelope + .result extraction, reasoning turns leak
    # as a prose preamble that breaks the strict-JSON parser below.
    # Save/restore so an outer caller's env intent is preserved.
    local tier="${ZBUILD_SECURITY_LENS_TIER:-T3}"
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
        # #478: slice the LAST top-level balanced JSON object out of any
        # prose preface the model may emit inside the final assistant turn
        # (envelope mode separates turns but not in-turn prose). Helper
        # passes input through verbatim on no-match so the existing
        # empty-findings fallback below still fires.
        local stripped extracted
        stripped="$(printf '%s' "$raw_response" | extract_first_json_object)"
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
        emit_event "plugin.run.error" "plugin=security-lens" \
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

    emit_event "plugin.run.complete" "plugin=security-lens" \
        "findings_count=$findings_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
security_lens_finalize() {
    emit_event "plugin.finalize.complete" "plugin=security-lens"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
security_lens_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=security-lens"
    return 0
}
