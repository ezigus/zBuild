#!/usr/bin/env bash
# core/pipeline/contract-validator.sh — ADR-020 runtime pre-flight contract
# validator (issue #496).
#
# Reads the active template's stage list + each stage's manifest, builds an
# O(1) lookup of available stage outputs in template order, then asserts that
# every required input of every stage has a producer ahead of it.
#
# Failure modes:
#   - missing required input from a stage NOT in the template → preflight_failed
#   - input declares `source: stage:X` but X declares no output with that id
#   - input declares `source: external` for an id outside the allowlist
#   - input path template references an unknown ${var}
#
# Integration: called from core/pipeline/runner.sh:~165 after load_template +
# init_state but before the --dry-run branch and before the stage loop.
#
# Rollout: gated by ZBUILD_CONTRACT_VALIDATOR=warn|enforce (default `warn`
# for the first release). In `warn` mode, violations are reported on stderr
# and a `pipeline.preflight.fail` event is emitted, but the pipeline is
# allowed to proceed; in `enforce` mode the function returns rc=2 and the
# runner halts before any stage starts.
#
# Bash 5+. Sourced library; do not add `set -euo pipefail`.

[[ -n "${_ZBUILD_CONTRACT_VALIDATOR_LOADED:-}" ]] && return 0
_ZBUILD_CONTRACT_VALIDATOR_LOADED=1

_ZBUILD_CV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_CV_ROOT="$(cd "$_ZBUILD_CV_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$_ZBUILD_CV_ROOT/scripts/lib/manifest-graph.sh"
# Defensive sources (validator is also invoked directly from unit tests).
if ! declare -F eb_emit_event >/dev/null 2>&1; then
    # shellcheck source=../event-bus/event-bus.sh
    source "$_ZBUILD_CV_ROOT/core/event-bus/event-bus.sh"
fi
if ! declare -F atomic_write >/dev/null 2>&1; then
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$_ZBUILD_CV_ROOT/scripts/lib/helpers.sh"
fi

# ─── _cv_var_in_canonical_set <var_name> ───────────────────────────────────────
# Returns 0 if the variable is in the closed templating-var set (decision #5).
_cv_var_in_canonical_set() {
    local v="$1"
    local allowed
    allowed="$(manifest_graph_canonical_vars)"
    for a in $allowed; do
        [[ "$a" == "$v" ]] && return 0
    done
    return 1
}

# ─── _cv_check_path_vars <path_template> → rc 0 ok, 1 unknown var ──────────────
# Scans the path template for ${var} references and rejects any not in the
# canonical set. Emits the first offender on stderr via $_CV_LAST_BAD_VAR.
_CV_LAST_BAD_VAR=""
_cv_check_path_vars() {
    local path="$1"
    _CV_LAST_BAD_VAR=""
    [[ -z "$path" ]] && return 0
    # Extract every "${name}" reference.
    local rest="$path" v
    while [[ "$rest" == *'${'*'}'* ]]; do
        v="${rest#*'${'}"
        v="${v%%'}'*}"
        if ! _cv_var_in_canonical_set "$v"; then
            _CV_LAST_BAD_VAR="$v"
            return 1
        fi
        rest="${rest#*'}'}"
    done
    return 0
}

# ─── _cv_redact_path <abs_path> <state_dir> ────────────────────────────────────
# Per decision #12: pre-flight errors render paths as $ZBUILD_STATE_DIR/...
# rather than absolute paths. Pre-flight runs before scope-manifest is final,
# so we can't use the redaction chokepoint; we strip the state_dir prefix
# manually here as a best-effort.
_cv_redact_path() {
    local path="$1" state_dir="$2"
    if [[ -n "$state_dir" && "$path" == "$state_dir"* ]]; then
        echo "\$ZBUILD_STATE_DIR${path#$state_dir}"
    else
        printf '%s' "$path"
    fi
}

# ─── _contract_validate_pipeline <template_stage_list> <plugins_root> <state_file>
# Public entry. The template_stage_list is a space-delimited ordered list of
# stage ids (the runner's `active_stages`). plugins_root is the directory
# containing kind/plugin/manifest.yaml. state_file is the path the runner
# will use as the resume target — used to write a `status: preflight_failed`
# stub on hard failure (decision #4).
#
# Returns:
#   0  — all required inputs satisfied OR mode=warn (warn always returns 0)
#   2  — contract violation detected AND mode=enforce
#
# Side-effects:
#   - Emits `pipeline.preflight.fail` event on violation (mode-agnostic).
#   - Writes a minimal state.json with `status: preflight_failed` on enforce.
#   - Prints structured error to stderr per ADR-020 (stable ordering: by
#     template position, alphabetical by input id within stage).
_contract_validate_pipeline() {
    local template_stages_csv="$1" plugins_root="$2" state_file="$3"
    local state_dir; state_dir="$(dirname "${state_file:-/dev/null}")"

    # Mode (decision #2). Default `warn` for the first release.
    local mode="${ZBUILD_CONTRACT_VALIDATOR:-warn}"
    case "$mode" in
        warn|enforce) ;;
        *)
            # Unknown mode: degrade to warn but log it.
            mode="warn"
            ;;
    esac

    # Skip entirely if explicitly disabled (escape hatch for ops emergencies).
    if [[ "$mode" == "off" ]]; then return 0; fi

    # Parse stage list (newline-delimited input from runner)
    local -a stages=()
    local s
    while IFS= read -r s; do
        [[ -n "$s" ]] && stages+=("$s")
    done <<< "$template_stages_csv"
    [[ ${#stages[@]} -eq 0 ]] && return 0

    # External allowlist (decision #6)
    local allowlist
    allowlist="$(manifest_graph_external_allowlist)"
    local -A _CV_EXTERNAL_OK=()
    local a
    for a in $allowlist; do
        _CV_EXTERNAL_OK["$a"]=1
    done

    # Build cumulative available-outputs map: key="stage:output_id" → 1
    declare -A _CV_AVAILABLE=()
    # Also build per-stage available list to check `stage:X` references
    declare -A _CV_STAGE_OUTPUTS_OK=()  # key="stage:id" → 1 if stage X has output id

    # Pass 1: collect every stage's outputs into _CV_STAGE_OUTPUTS_OK
    local -A _CV_STAGE_MANIFEST=()
    local stage manifest
    for stage in "${stages[@]}"; do
        manifest="$(manifest_graph_collect "$plugins_root" "$stage" 2>/dev/null || true)"
        if [[ -z "$manifest" ]]; then
            # No manifest for this stage. NOT a contract violation by itself
            # (runner has its own fail-closed "no plugin registered" path);
            # we just skip output enumeration for this stage and let any
            # downstream stage that depends on it surface the violation.
            continue
        fi
        if ! manifest_graph_probe_sentinel "$manifest"; then
            # Manifest present but unparseable — distinguish from absent.
            printf '  WARNING: manifest for stage %s is present but missing top-level id: (unparseable)\n' \
                "$stage" >&2
            continue
        fi
        _CV_STAGE_MANIFEST["$stage"]="$manifest"
        local outrec
        while IFS= read -r outrec; do
            [[ -z "$outrec" ]] && continue
            local out_id="${outrec%%|*}"
            [[ -z "$out_id" ]] && continue
            _CV_STAGE_OUTPUTS_OK["$stage:$out_id"]=1
        done < <(manifest_graph_get_outputs "$manifest")
    done

    # Pass 2: walk stages in order; for each, validate inputs against the
    # cumulative _CV_AVAILABLE map, then merge this stage's outputs into it.
    local -a violations=()
    local fail_count=0

    for stage in "${stages[@]}"; do
        manifest="${_CV_STAGE_MANIFEST[$stage]:-}"
        [[ -z "$manifest" ]] && continue

        # Decision #1: an absent `inputs:` block is malformed. An explicit
        # `inputs: []` is required to declare zero inputs. (For agent
        # plugins specifically; tool/orchestrator that haven't migrated yet
        # are warned but not failed during the warn-default rollout.)
        if ! manifest_graph_inputs_block_present "$manifest"; then
            printf '  WARNING: manifest for stage %s has no inputs: block — declare `inputs: []` for zero-input plugins (ADR-020)\n' \
                "$stage" >&2
        fi

        # Collect inputs and sort by id for stable error ordering (decision: stable ordering)
        local -a input_lines=()
        local rec
        while IFS= read -r rec; do
            [[ -z "$rec" ]] && continue
            input_lines+=("$rec")
        done < <(manifest_graph_get_inputs "$manifest" | LC_ALL=C sort)

        local in_rec in_id in_type in_source in_required in_path
        for in_rec in "${input_lines[@]}"; do
            # shellcheck disable=SC2034  # in_type captured for future schema-aware checks
            IFS='|' read -r in_id in_type in_source in_required in_path <<< "$in_rec"
            [[ -z "$in_id" ]] && continue

            # Default required=true if absent at parse time (decision #1).
            # Empty `required:` value (key present but no value) is malformed.
            if [[ -z "$in_required" ]]; then
                in_required="true"
            fi
            case "$in_required" in
                true|false) ;;
                *)
                    violations+=("$stage|MALFORMED|$in_id|invalid required: value '$in_required' (must be true|false)")
                    fail_count=$((fail_count + 1))
                    continue
                    ;;
            esac

            # Check path template variables (decision #5)
            if [[ -n "$in_path" ]]; then
                if ! _cv_check_path_vars "$in_path"; then
                    violations+=("$stage|BAD_VAR|$in_id|path template references unknown variable \${${_CV_LAST_BAD_VAR}} (allowed: $(manifest_graph_canonical_vars))|$in_path")
                    fail_count=$((fail_count + 1))
                    continue
                fi
            fi

            # If optional, presence of source is informational only.
            if [[ "$in_required" == "false" ]]; then
                # Still merge what's available (no enforcement on optional misses).
                continue
            fi

            # Required input: must declare a valid source.
            if [[ -z "$in_source" ]]; then
                violations+=("$stage|MISSING_SOURCE|$in_id|required input has no source: declared|$in_path")
                fail_count=$((fail_count + 1))
                continue
            fi

            case "$in_source" in
                external)
                    if [[ -z "${_CV_EXTERNAL_OK[$in_id]:-}" ]]; then
                        violations+=("$stage|BAD_EXTERNAL|$in_id|source: external used for id not in allowlist (allowed: $(manifest_graph_external_allowlist))")
                        fail_count=$((fail_count + 1))
                    fi
                    ;;
                stage:*)
                    local producer="${in_source#stage:}"
                    # Self-reference check
                    if [[ "$producer" == "$stage" ]]; then
                        violations+=("$stage|SELF_REF|$in_id|source: stage:$producer refers to itself")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    # Is producer in the template?
                    local in_template=0 ts
                    for ts in "${stages[@]}"; do
                        [[ "$ts" == "$producer" ]] && { in_template=1; break; }
                    done
                    if [[ "$in_template" -eq 0 ]]; then
                        violations+=("$stage|MISSING_STAGE|$in_id|source declared: stage:$producer; status: stage '$producer' is NOT in template — add it before '$stage'|$in_path")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    # Is producer ordered before consumer? (Misordered)
                    if [[ -z "${_CV_AVAILABLE[$producer]:-}" ]]; then
                        # producer is in template but not yet seen → misordered
                        violations+=("$stage|MISORDERED|$in_id|source declared: stage:$producer; status: stage '$producer' runs AFTER '$stage' in template")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    # Does producer declare this output id?
                    if [[ -z "${_CV_STAGE_OUTPUTS_OK[$producer:$in_id]:-}" ]]; then
                        violations+=("$stage|MISSING_OUTPUT|$in_id|source declared: stage:$producer; status: stage '$producer' does NOT declare output id '$in_id'")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    ;;
                *)
                    violations+=("$stage|BAD_SOURCE|$in_id|source: '$in_source' is malformed (must be 'stage:<name>' or 'external')")
                    fail_count=$((fail_count + 1))
                    ;;
            esac
        done

        # Mark this stage as available for downstream consumers.
        _CV_AVAILABLE["$stage"]=1
    done

    # No violations → success
    if [[ $fail_count -eq 0 ]]; then
        return 0
    fi

    # ── Render structured error ────────────────────────────────────────────
    {
        printf '\n'
        printf '✗ Pipeline cannot start — inputs missing for declared stages:\n\n'
        local v sstage scode sid smsg spath
        for v in "${violations[@]}"; do
            IFS='|' read -r sstage scode sid smsg spath <<< "$v"
            local rendered_path=""
            if [[ -n "$spath" ]]; then
                rendered_path="$(_cv_redact_path "$spath" "$state_dir")"
            fi
            case "$scode" in
                MISSING_STAGE)
                    printf '  %s: expects %s%s\n' "$sstage" "'$sid'" \
                        "$( [[ -n "$rendered_path" ]] && printf ' (path: %s)' "$rendered_path" )"
                    printf '    %s\n\n' "$smsg" | sed 's/|/\n    /g'
                    ;;
                MISORDERED)
                    printf '  %s: expects %s\n    %s\n\n' "$sstage" "'$sid'" "$smsg"
                    ;;
                MISSING_OUTPUT|BAD_EXTERNAL|BAD_SOURCE|MISSING_SOURCE|SELF_REF|MALFORMED|BAD_VAR)
                    printf '  %s: %s (id=%s)\n    %s\n\n' "$sstage" "$scode" "$sid" "$smsg"
                    ;;
                *)
                    printf '  %s: %s (id=%s): %s\n\n' "$sstage" "$scode" "$sid" "$smsg"
                    ;;
            esac
        done
        printf 'Fix: edit the relevant plugin manifest (plugins/*/manifest.yaml)\n'
        printf '     or the active template (config/templates/<id>.yaml).\n'
        printf '     See docs/adr/ADR-020-inter-stage-data-contract.md.\n\n'
    } >&2

    # Emit event (best-effort; do not fail the validator on event-bus errors)
    if declare -F eb_emit_event >/dev/null 2>&1; then
        eb_emit_event "pipeline.preflight.fail" \
            "reason=missing_input" \
            "violation_count=$fail_count" \
            "mode=$mode" 2>/dev/null || true
    fi

    # Mode-specific resolution
    if [[ "$mode" == "warn" ]]; then
        printf '  ZBUILD_CONTRACT_VALIDATOR=warn — continuing despite violations. Set =enforce to fail-fast.\n\n' >&2
        return 0
    fi

    # enforce: write preflight_failed status and return 2
    if [[ -n "$state_file" ]]; then
        local sdir; sdir="$(dirname "$state_file")"
        mkdir -p "$sdir" 2>/dev/null || true
        if declare -F atomic_write >/dev/null 2>&1; then
            jq -n \
                --arg status "preflight_failed" \
                --arg reason "missing_input" \
                --argjson count "$fail_count" \
                '{schema_version: 1, status: $status, reason: $reason, violation_count: $count}' \
                2>/dev/null | atomic_write "$state_file" 2>/dev/null || true
        fi
    fi
    return 2
}
