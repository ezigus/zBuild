#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugin-registry — lifecycle hook dispatch + fail-closed output scanner    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Split from registry.sh (#364). Owns the runtime dispatch path:
# `plugin_hook_call` (sources plugin.sh in an isolated subshell, applies
# pre-source tamper checks, calls the hook function, then verifies declared
# outputs) and `scan_plugin_outputs` (ADR-001 fail-closed artifact-presence
# scanner). Depends on yaml_get / verify_plugin_for_source from the other two
# split modules — sourced together via the registry.sh facade.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_REGISTRY_LIFECYCLE_LOADED:-}" ]] && return 0
_ZBUILD_REGISTRY_LIFECYCLE_LOADED=1

# ─── scan_plugin_outputs — fail-closed artifact-presence scanner (#288) ─────
# ADR-001 §Fail-closed scanner contract:
#   "If a plugin declares provides.artifact_type but no artifact exists at
#    outputs[].path after run completes with exit 0, the engine emits a
#    synthetic blocking finding."
#
# Arguments:
#   $1 — plugin_dir
#   $2 — state_file (so $state_dir / $artifacts_dir can substitute into paths)
#
# Returns:
#   0 if all declared outputs are present (or no outputs declared).
#   1 if any declared output is missing — and emits one
#      `plugin.artifact.missing` event per missing path.
#
# Path-template substitution (Phase 0.5): supports ${state_dir} and
# ${artifact_dir} / ${artifacts_dir}. Any other ${VAR} resolves from the work
# unit's exported environment (#1803) — per-member outputs such as review-lens's
# `lens-${ZBUILD_REVIEW_LENS_ID}.json` (ADR-047 §2) are only checkable once the
# element var is expanded. A var that is unset stays literal and fails the check.
scan_plugin_outputs() {
    local plugin_dir="$1"
    local state_file="${2:-}"
    local stage="${3:-}"
    local manifest="$plugin_dir/manifest.yaml"

    # No manifest, no outputs to scan — silently succeed.
    [[ ! -f "$manifest" ]] && return 0

    local plugin_id; plugin_id="$(yaml_get "$manifest" "id" 2>/dev/null || true)"
    local kind; kind="$(yaml_get "$manifest" "kind" 2>/dev/null || true)"
    local artifact_type; artifact_type="$(yaml_get "$manifest" "provides.artifact_type" 2>/dev/null || true)"
    # ADR-047 §4 capability flag: build legitimately writes a zero-byte diff.patch
    # when a turn changed no code. The exemption is deliberately narrow — it never
    # covers a `primary: true` output, so a stage cannot mask an empty verdict
    # artifact (e.g. build-summary.json) by declaring the flag in its own manifest.
    local empty_diff_ok; empty_diff_ok="$(yaml_get "$manifest" "capabilities.empty_diff_legitimate" 2>/dev/null || true)"

    # Compute substitution roots from state_file.
    local state_dir="" artifact_dir=""
    if [[ -n "$state_file" ]]; then
        state_dir="$(dirname "$state_file")"
        artifact_dir="${state_dir}/artifacts"
    fi

    # Pull outputs[].path entries from the manifest. yaml_get/yaml_get_list
    # don't model lists of objects, so grep the YAML directly. Format we
    # support (per ADR-001):
    #   outputs:
    #     - name: foo
    #       path: ${artifact_dir}/foo.json
    #       type: foo.json
    # #511 F2: respect `required: false` on outputs (e.g. test plugin's
    # `test_failures_summary` which is intentionally ABSENT when the test
    # verdict is `pass` — missing == empty). Without this, the scanner
    # would flag the missing optional artifact as a fail-closed contract
    # violation on every passing run, breaking the parity goldens.
    local paths
    paths="$(awk '
        BEGIN { in_block = 0; cur_path = ""; cur_required = ""; cur_primary = "" }
        function flush() {
            if (cur_path != "" && cur_required != "false") {
                print cur_path "\t" cur_primary
            }
            cur_path = ""; cur_required = ""; cur_primary = ""
        }
        /^outputs:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[a-zA-Z_]/ { flush(); in_block = 0 }
        in_block && /^[[:space:]]*-[[:space:]]/ { flush() }
        in_block && /^[[:space:]]+path:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur_path = line
            next
        }
        in_block && /^[[:space:]]+required:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+required:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur_required = line
            next
        }
        in_block && /^[[:space:]]+primary:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+primary:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur_primary = line
            next
        }
        END { flush() }
    ' "$manifest" 2>/dev/null)"

    [[ -z "$paths" ]] && return 0

    local missing=0
    local raw_path raw_primary resolved _violation _event _var _expansions
    while IFS=$'\t' read -r raw_path raw_primary; do
        [[ -z "$raw_path" ]] && continue
        resolved="$raw_path"
        # Phase 0.5 substitutions.
        resolved="${resolved//\$\{state_dir\}/$state_dir}"
        resolved="${resolved//\$\{artifact_dir\}/$artifact_dir}"
        resolved="${resolved//\$\{artifacts_dir\}/$artifact_dir}"
        # Remaining ${VAR} tokens come from the work unit's exported env (the
        # template's `as:` mapping, e.g. ZBUILD_REVIEW_LENS_ID). Indirect
        # expansion only — never eval — so a manifest cannot inject a command.
        # Bounded, and an unset var is left literal so the check fails loudly.
        _expansions=0
        while [[ $_expansions -lt 16 ]] && [[ "$resolved" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
            _var="${BASH_REMATCH[1]}"
            [[ -z "${!_var+x}" ]] && break
            resolved="${resolved//\$\{$_var\}/${!_var}}"
            _expansions=$((_expansions + 1))
        done

        # An absent output always violates; a zero-byte one violates unless the
        # plugin declared the empty-diff capability AND this is not its primary.
        _violation=""
        if [[ ! -e "$resolved" ]]; then
            _violation="absent"
            _event="plugin.artifact.missing"
        elif [[ ! -s "$resolved" ]] &&
             ! { [[ "$empty_diff_ok" == "true" ]] && [[ "$raw_primary" != "true" ]]; }; then
            _violation="empty"
            _event="plugin.artifact.empty"
        fi

        if [[ -n "$_violation" ]]; then
            if [[ "$_violation" == "absent" ]]; then
                error "scan_plugin_outputs: plugin=$plugin_id declared output missing: $resolved (template: $raw_path)"
            else
                error "scan_plugin_outputs: plugin=$plugin_id declared output is empty (zero bytes): $resolved (template: $raw_path)"
            fi
            emit_event "$_event" \
                "plugin=$plugin_id" \
                "kind=$kind" \
                "artifact_type=$artifact_type" \
                "expected_path=$resolved" \
                "template=$raw_path"
            # ADR-001 §Fail-closed contract: emit plugin.contract.violated and write
            # synthetic blocking findings.json so the output stage can surface the violation.
            local _stage_id="${stage:-${plugin_id}}"
            emit_event "plugin.contract.violated" \
                "stage=$_stage_id" \
                "plugin=$plugin_id" \
                "artifact_type=$artifact_type" \
                "expected_path=$resolved" \
                "reason=artifact_missing_or_empty"
            if [[ -n "$state_dir" ]]; then
                mkdir -p "${state_dir}/artifacts"
                local _findings_file="${state_dir}/artifacts/${_stage_id}-${plugin_id}-contract-violated-findings.json"
                jq -n \
                    --arg stage "$_stage_id" \
                    --arg plugin "$plugin_id" \
                    --arg artifact_type "$artifact_type" \
                    --arg path "$resolved" \
                    --arg violation "$_violation" \
                    '{
                        schema_version: 1,
                        findings: [{
                            id: "artifact-contract-violated",
                            title: ("Plugin contract violated: " + $plugin +
                                    (if $violation == "empty"
                                     then " wrote an empty (zero-byte) required output"
                                     else " declared a required output but wrote no artifact" end)),
                            severity: "blocking",
                            stage: $stage,
                            plugin: $plugin,
                            detail: ("Expected artifact at: " + $path +
                                     (if $artifact_type == "" then ""
                                      else " (provides.artifact_type=" + $artifact_type + ")" end))
                        }]
                    }' > "$_findings_file" 2>/dev/null || true
            fi
            missing=$((missing + 1))
        fi
    done <<< "$paths"

    return $((missing > 0))
}

# Exit code returned when an optional hook (cleanup) is absent.
# Distinguishable from success (0) and plugin error codes (1=recoverable, 2=fatal).
# Callers compare $rc -eq ZBUILD_HOOK_ABSENT to detect "never ran" vs $rc -eq 0 ("ran ok").
ZBUILD_HOOK_ABSENT=3

# ─── plugin_hook_call ───────────────────────────────────────────────────────
# Source the plugin's plugin.sh and call a lifecycle hook by name.
# Plugin functions are isolated by sub-shell to prevent namespace pollution.
plugin_hook_call() {
    local plugin_dir="$1"
    local hook_name="$2"   # run | cleanup (or kind-specific)
    shift 2
    local manifest="$plugin_dir/manifest.yaml"
    local plugin_sh="$plugin_dir/plugin.sh"

    if [[ ! -f "$plugin_sh" ]]; then
        error "plugin_hook_call: plugin.sh missing: $plugin_sh"
        return 1
    fi

    local plugin_id; plugin_id="$(yaml_get "$manifest" "id")"
    local kind; kind="$(yaml_get "$manifest" "kind")"

    local hook_fn; hook_fn="$(yaml_get "$manifest" "hooks.$hook_name")"
    if [[ -z "$hook_fn" ]]; then
        if [[ "$hook_name" == "cleanup" ]]; then
            # Absent optional hook: emit sentinel event and return ZBUILD_HOOK_ABSENT.
            emit_event "plugin.$hook_name.absent" "plugin=$plugin_id" "kind=$kind"
            return "$ZBUILD_HOOK_ABSENT"
        fi
        # Absent required hook: emit refused event and fail.
        emit_event "plugin.$hook_name.refused" "plugin=$plugin_id" "kind=$kind" "reason=hook-not-declared"
        return 1
    fi

    # Pre-source tamper check (#290). Honors ZBUILD_STRICT_PLUGIN_LOCK.
    if ! verify_plugin_for_source "$manifest"; then
        emit_event "plugin.$hook_name.refused" "plugin=$plugin_id" "kind=$kind" "reason=lockfile-mismatch"
        return 1
    fi

    emit_event "plugin.$hook_name.start" "plugin=$plugin_id" "kind=$kind"

    # Run in a subshell to isolate plugin's variables/functions
    (
        # shellcheck disable=SC1090
        source "$plugin_sh"
        if declare -F "$hook_fn" >/dev/null 2>&1; then
            "$hook_fn" "$@"
        else
            echo "plugin_hook_call: function $hook_fn not defined in $plugin_sh" >&2
            exit 1
        fi
    )
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        # #288: after a successful `run`, verify the plugin actually produced
        # the artifacts it declared. Absent evidence IS blocking evidence —
        # emit synthetic findings for each missing output and surface the
        # failure as a non-zero hook exit so the caller can react.
        if [[ "$hook_name" == "run" ]]; then
            # Per ADR-001 hook signature: $@ after shift 2 is (stage_id, state_file, ...).
            local stage_arg="${1:-}"
            local state_file_arg="${2:-}"
            if ! scan_plugin_outputs "$plugin_dir" "$state_file_arg" "$stage_arg"; then
                emit_event "plugin.$hook_name.artifact_check_failed" \
                    "plugin=$plugin_id" "kind=$kind"
                return 1
            fi
        fi
        emit_event "plugin.$hook_name.complete" "plugin=$plugin_id" "kind=$kind"
    else
        emit_event "plugin.$hook_name.error" "plugin=$plugin_id" "kind=$kind" "rc=$rc"
    fi
    return $rc
}
