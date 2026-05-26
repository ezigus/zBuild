#!/usr/bin/env bash
# core/pipeline/contracts.sh — artifact contract checking extracted from
# runner.sh (issue #279). ARCHITECTURE.md §2: if a plugin declares
# provides.artifact_type, it MUST write the declared output artifact.
# No behavior change from the original runner-embedded version.

[[ -n "${_ZBUILD_CONTRACTS_LOADED:-}" ]] && return 0
_ZBUILD_CONTRACTS_LOADED=1

_ZBUILD_CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_CONTRACTS_ROOT="$(cd "$_ZBUILD_CONTRACTS_DIR/../.." && pwd)"

# Depends on yaml_get (core/plugin-registry/registry.sh — NOT helpers.sh,
# Copilot caught this on #280), warn (scripts/lib/helpers.sh), and
# eb_emit_event (core/event-bus/event-bus.sh). Defensively source each
# if absent so the file is self-contained when tests source it directly.
if ! declare -F yaml_get >/dev/null 2>&1; then
    source "$_ZBUILD_CONTRACTS_ROOT/core/plugin-registry/registry.sh"
fi
if ! declare -F warn >/dev/null 2>&1; then
    source "$_ZBUILD_CONTRACTS_ROOT/scripts/lib/helpers.sh"
fi
if ! declare -F eb_emit_event >/dev/null 2>&1; then
    source "$_ZBUILD_CONTRACTS_ROOT/core/event-bus/event-bus.sh"
fi

# _check_artifact_contract <plugin_dir> <state_dir> <stage>
# Emits plugin.contract.violated and creates a synthetic blocking findings.json
# if the artifact is missing/empty. Returns 0 always (caller decides whether
# to halt the pipeline).
_check_artifact_contract() {
    local plugin_dir="$1" state_dir="$2" stage="$3"
    local manifest="$plugin_dir/manifest.yaml"

    # Check if plugin declares provides.artifact_type
    local artifact_type
    artifact_type="$(yaml_get "$manifest" "provides.artifact_type" 2>/dev/null || true)"
    [[ -z "$artifact_type" ]] && return 0

    # Get declared output path (first outputs[].path entry)
    local output_path
    output_path="$(awk '
        /^outputs:/ { in_outputs=1; next }
        in_outputs && /^[a-zA-Z_]/ { in_outputs=0 }
        in_outputs && /path:/ {
            sub(/^[[:space:]]*path:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            print
            exit
        }
    ' "$manifest" 2>/dev/null || true)"

    # Resolve path relative to state_dir if not absolute
    local resolved_path
    if [[ -n "$output_path" ]]; then
        if [[ "$output_path" == /* ]]; then
            resolved_path="$output_path"
        else
            resolved_path="$state_dir/$output_path"
        fi
    else
        # No explicit output path declared — check for state_dir/artifacts/<stage>-findings.json
        resolved_path="$state_dir/artifacts/${stage}-findings.json"
    fi

    # Check if artifact exists and is non-empty
    if [[ -s "$resolved_path" ]]; then
        return 0  # artifact present and non-empty — contract satisfied
    fi

    local plugin_id; plugin_id="$(yaml_get "$manifest" "id" 2>/dev/null || true)"

    # Emit plugin.contract.violated event
    eb_emit_event "plugin.contract.violated" \
        "stage=$stage" \
        "plugin=${plugin_id:-unknown}" \
        "artifact_type=$artifact_type" \
        "expected_path=$resolved_path" \
        "reason=artifact_missing_or_empty"

    # Create synthetic blocking findings.json under artifacts/ so the output
    # plugin's aggregator (which reads $state_dir/artifacts/*-findings.json) picks it up
    mkdir -p "$state_dir/artifacts"
    local findings_file="$state_dir/artifacts/${stage}-${plugin_id:-unknown}-contract-violated-findings.json"
    jq -n \
        --arg stage "$stage" \
        --arg plugin "${plugin_id:-unknown}" \
        --arg artifact_type "$artifact_type" \
        --arg path "$resolved_path" \
        '{
            schema_version: 1,
            findings: [{
                id: "artifact-contract-violated",
                title: ("Plugin contract violated: " + $plugin + " declared provides.artifact_type=" + $artifact_type + " but wrote no artifact"),
                severity: "blocking",
                stage: $stage,
                plugin: $plugin,
                detail: ("Expected artifact at: " + $path)
            }]
        }' > "$findings_file" 2>/dev/null || true

    warn "Plugin contract violated: $plugin_id (stage=$stage) declared artifact_type=$artifact_type but wrote no artifact at $resolved_path"
    return 0
}
