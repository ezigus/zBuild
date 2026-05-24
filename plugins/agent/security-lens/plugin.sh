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

_SEC_LENS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SEC_LENS_ROOT="$(cd "$_SEC_LENS_DIR/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/helpers.sh
source "$_SEC_LENS_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_SEC_LENS_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_SEC_LENS_ROOT/core/event-bus/event-bus.sh"

# ─── init ───────────────────────────────────────────────────────────────────
security_lens_init() {
    export ZBUILD_PLUGIN="security-lens"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=security-lens"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
# Args:
#   $1 = input file (raw text to analyze, e.g., a git diff or file list)
#   $2 = scope_manifest path
#   $3 = output findings.json path
#   $4 = (optional) artifact dir for intermediate redacted prompt
security_lens_run() {
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

    # ─── Phase 0 stub: emit deterministic findings.json ─────────────────────
    # Real implementation routes the redacted prompt through the model router
    # (router lands later in the migration). For Phase 0, we emit a synthetic
    # finding so the migration loop is testable end-to-end.
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Look for trigger keywords in the redacted input
    local triggers="injection|auth|secret|credential|permission|bypass|xss|csrf|traversal|sanitiz"
    local trigger_hits=0
    trigger_hits="$(grep -cEo "$triggers" "$redacted" 2>/dev/null || true)"

    jq -n \
        --arg ts "$now" \
        --argjson hits "${trigger_hits:-0}" \
        '{
            schema_version: 1,
            plugin_id: "security-lens",
            generated_at: $ts,
            findings: (
                if $hits > 0 then
                    [{
                        title: "Phase 0 stub: trigger keywords detected in input",
                        severity: "low",
                        category: "phase-0-stub",
                        file: "n/a",
                        evidence: "(\($hits) keyword matches; real LLM routing lands with the router)",
                        suggestion: "Wire the real LLM call once core/router/ is implemented."
                    }]
                else
                    []
                end
            ),
            stub: true
        }' > "$output"

    emit_event "plugin.run.complete" "plugin=security-lens" \
        "findings_count=$(jq -r '.findings | length' "$output")" \
        "trigger_hits=$trigger_hits"

    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
security_lens_finalize() {
    emit_event "plugin.finalize.complete" "plugin=security-lens"
    return 0
}
