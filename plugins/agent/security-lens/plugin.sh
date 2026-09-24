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

# ADR-054 §6 / ADR-060 §1: write v2 result artifact atomically.
# Keeps top-level findings/stub for backward compat with pre-v2 consumers.
# Args: <output-path> <verdict> <disposition> <reason> [<findings-json>]
_security_lens_write_result() {
    local output="$1" verdict="$2" disposition="$3" reason="$4"
    local findings_json="${5:-[]}"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n \
        --arg ts "$now" \
        --arg verdict "$verdict" \
        --arg disposition "$disposition" \
        --arg reason "$reason" \
        --argjson findings "$findings_json" \
        '{
            result_contract: 2,
            verdict: $verdict,
            disposition: $disposition,
            reason: $reason,
            plugin_id: "security-lens",
            generated_at: $ts,
            findings: $findings,
            stub: false,
            data: {
                plugin_id: "security-lens",
                generated_at: $ts,
                findings: $findings,
                stub: false
            }
        }' | atomic_write "$output"
}

# ADR-063 §3: interrupt handler — writes v2 result with verdict=error/interrupted.
# Registered as TERM/INT trap in _security_lens_run_inner around the model call.
_security_lens_interrupt_handler() {
    _sl_interrupted=1
    _security_lens_write_result "${_sl_out_ref:-/dev/null}" "error" "interrupted" \
        "signal_interrupt"
}

# ─── run ────────────────────────────────────────────────────────────────────
# Hook called by the pipeline runner: security_lens_run(stage, state_file)
# Derives artifact paths from state_dir and delegates to the inner function.
security_lens_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "security_lens_run: state_file argument required"
        if [[ -n "${ZBUILD_ARTIFACT_DIR:-}" ]]; then
            mkdir -p "$ZBUILD_ARTIFACT_DIR" 2>/dev/null || true
            _security_lens_write_result "$ZBUILD_ARTIFACT_DIR/security-findings.json" \
                "error" "broken" \
                "the engine dispatched this stage with no state file"
        fi
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/security-lens-summary.md}" "security-lens" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 1
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"
    # Partition by platform when running in fanout mode so parallel invocations
    # don't overwrite each other. Filename still matches the *-findings.json
    # glob that the output plugin uses to collect results.
    local platform_infix="${ZBUILD_TARGET_PLATFORM:+-${ZBUILD_TARGET_PLATFORM}}"
    # ADR-055 §1 (#1825/#1826): the ENGINE says where another stage's artifact
    # is. Hardcoding a producer's filename pins it forever and bypasses the
    # resolved-input index.
    local _si_intake="" _si_scope=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        _si_intake="$(jq -r '.inputs.intake_goal // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
        _si_scope="$(jq -r '.inputs.scope_manifest // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi
    # The fallbacks stand only for a DIRECT hook call (the contract tests drive
    # security_lens_run with no index). In the pipeline the engine always
    # provides one, so the resolved path is what production uses and a producer
    # is free to move its artifact.
    [[ -n "$_si_intake" ]] || _si_intake="$state_dir/intake.md"
    [[ -n "$_si_scope"  ]] || _si_scope="$state_dir/scope-manifest.md"

    _security_lens_run_inner \
        "$_si_intake" \
        "$_si_scope" \
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
        return 1
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
    local tier
    if ! tier="$(resolve_tier security-lens "$_SEC_LENS_DIR")"; then
        error "security_lens_run: resolve_tier failed; refusing to emit"
        _security_lens_write_result "$output" "error" "broken" \
            "the model call failed, so no security review happened"
        stage_summary_write "$artifact_dir/security-lens-summary.md" "security-lens" "error" \
            "tier resolution failed — no security review happened" \
            "This lens contributed no findings; absence here is not evidence of safety."
        # No router_rc here: the tier never resolved, so no router call was made.
        # The old literal `router_rc=2` claimed an exit code that never happened,
        # conflating tier-resolution failure with a router failure.
        emit_event "plugin.result" "verdict=error" "plugin=security-lens" \
            "result_contract=2" "reason=tier_unresolved"
        # The manifest DECLARES security_lens.failed; nothing emitted it, so a
        # monitor wired to it could never fire. A failure is what it is for.
        emit_event "security_lens.failed" "plugin=security-lens" \
            "reason=tier_unresolved"
        return 1
    fi
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
    _sl_out_ref="$output"
    _sl_interrupted=0
    trap '_security_lens_interrupt_handler' TERM INT
    # #491: do NOT redirect route_to_model's stderr — see ADR-015 §v4.
    raw_response="$(route_to_model "$tier" "$prompt")" || router_rc=$?
    trap - TERM INT
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

    # ─── ADR-063 §3: interrupt ─────────────────────────────────────────────
    # The flag, not only rc=130: a signal can arrive between `trap` and the
    # router returning, and the call then completes with rc=0. Keyed on rc
    # alone, the normal-pass path below overwrote the handler's interrupted
    # artifact and an interrupted SECURITY review was reported as a pass —
    # absence of findings reads as evidence of safety, which is the one claim
    # this lens must never make falsely.
    if [[ "${_sl_interrupted:-0}" == "1" && "$router_rc" -ne 130 ]]; then
        _security_lens_write_result "$output" "error" "interrupted" "signal_interrupt"
        emit_event "security_lens.failed" "plugin=security-lens" "reason=signal_interrupt"
        return 130
    fi
    if [[ "$router_rc" -eq 130 ]]; then
        [[ "${_sl_interrupted:-0}" == "1" ]] \
            || _security_lens_write_result "$output" "error" "interrupted" "signal_interrupt"
        return 130
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
        _security_lens_write_result "$output" "error" "broken" \
            "the model call failed, so no security review happened"
        stage_summary_write "$artifact_dir/security-lens-summary.md" "security-lens" "error" \
            "the model call failed, so no security review happened" \
            "This lens contributed no findings; absence here is not evidence of safety."
        emit_event "plugin.result" "verdict=error" "plugin=security-lens" \
            "reason=router_fatal" "router_rc=$router_rc"
        emit_event "security_lens.failed" "plugin=security-lens" \
            "reason=router_fatal" "router_rc=$router_rc"
        return 1
    fi

    # ─── Write findings.json (v2 contract + backward-compat top-level fields) ─
    local findings_count
    findings_count="$(printf '%s' "$findings_json" | jq 'length' 2>/dev/null || echo 0)"
    local _reason="reviewed the change for security issues — $findings_count finding(s)"
    _security_lens_write_result "$output" "pass" "complete" "$_reason" "$findings_json"

    stage_summary_write "$artifact_dir/security-lens-summary.md" "security-lens" "pass" \
        "$_reason" \
        "$(printf -- '- artifact: findings.json')"
    emit_event "plugin.result" "plugin=security-lens" \
        "result_contract=2" \
        "findings_count=$findings_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
# ADR-056 §4: no resources to release; presence recorded per contract.
security_lens_cleanup() { return 0; }
