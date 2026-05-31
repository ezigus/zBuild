#!/usr/bin/env bash
# scripts/lib/lint-contract.sh — ADR-020 CI lint (issue #496).
#
# Statically validates every plugin manifest's inputs[]/outputs[] block
# against the inter-stage data contract:
#
#   - Every input with `source: stage:X` requires:
#       (a) X to exist in plugins/ tree
#       (b) X to declare an output with the referenced id
#   - Every input with `source: external` requires its id to be on the
#     hardcoded allowlist (decision #6).
#   - Empty `inputs:` block (missing or value-only) is rejected; explicit
#     `inputs: []` is required for zero-input plugins.
#   - `required:` must be true|false; empty value is malformed.
#
# Exit codes:
#   0 — clean
#   1 — at least one offending manifest (printed to stderr)
#
# Wired into `npm run lint`. Uses the shared manifest-graph.sh parser so
# the lint view and the runtime validator view are identical (parity test
# in tests/unit/preflight-lint-parity-test.sh asserts this).
set -euo pipefail

_LINT_CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LINT_CONTRACT_REPO="$(cd "$_LINT_CONTRACT_DIR/../.." && pwd)"

# shellcheck source=./manifest-graph.sh
source "$_LINT_CONTRACT_DIR/manifest-graph.sh"

_PLUGINS_ROOT="${ZBUILD_PLUGINS_ROOT:-$_LINT_CONTRACT_REPO/plugins}"

# ADR-020 lint scope: only stage-bound plugins participate in the inter-stage
# data contract. Backend services (cache/memory/orchestrator/claim-coordinator)
# don't read/produce stage artifacts and are intentionally excluded. The
# explicit allowlist below mirrors ADR-013's canonical stage set.
_LC_STAGE_IDS_TO_CHECK=(intake plan design build test test_assessment review compound_quality pr deploy validate monitor security-lens)

_lc_id_in_scope() {
    local id="$1" s
    for s in "${_LC_STAGE_IDS_TO_CHECK[@]}"; do
        [[ "$s" == "$id" ]] && return 0
    done
    return 1
}

# Build {stage_id → manifest_path} and {stage_id:output_id → 1} indices.
declare -A _LC_STAGE_MANIFEST=()
declare -A _LC_STAGE_OUTPUTS=()
declare -A _LC_EXTERNAL_OK=()
for a in $(manifest_graph_external_allowlist); do
    _LC_EXTERNAL_OK["$a"]=1
done

_offences=0

while IFS= read -r -d '' m; do
    id="$(manifest_graph_get_stage_id "$m")"
    [[ -z "$id" ]] && continue
    _LC_STAGE_MANIFEST["$id"]="$m"
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        out_id="${rec%%|*}"
        [[ -n "$out_id" ]] && _LC_STAGE_OUTPUTS["$id:$out_id"]=1
    done < <(manifest_graph_get_outputs "$m")
done < <(find "$_PLUGINS_ROOT" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)

_complain() {
    printf 'lint-contract: %s\n' "$*" >&2
    _offences=$((_offences + 1))
}

for id in "${!_LC_STAGE_MANIFEST[@]}"; do
    m="${_LC_STAGE_MANIFEST[$id]}"
    rel="${m#"$_LINT_CONTRACT_REPO"/}"

    # Only enforce on stage-bound plugins (ADR-020 scope).
    _lc_id_in_scope "$id" || continue

    if ! manifest_graph_inputs_block_present "$m"; then
        _complain "$rel: missing inputs: block (declare 'inputs: []' for zero-input plugins) [ADR-020 decision 1]"
    fi

    # ── ADR-020 amendment (#507): exactly-one outputs[].primary: true ──────
    primary_count=$(awk '
        BEGIN { in_out=0; n=0 }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && /^[[:space:]]+primary:[[:space:]]*true([[:space:]]|$|#)/ { n++ }
        END { print n }
    ' "$m" 2>/dev/null)
    if [[ "$primary_count" -eq 0 ]]; then
        _complain "$rel: no outputs[] entry declares 'primary: true' (#507; pick the canonical artifact)"
    elif [[ "$primary_count" -gt 1 ]]; then
        _complain "$rel: $primary_count outputs[] entries declare 'primary: true' (must be exactly one) [#507]"
    fi

    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        # shellcheck disable=SC2034  # in_type/in_path read for parity with validator parser
        IFS='|' read -r in_id in_type in_source in_required in_path <<< "$rec"
        [[ -z "$in_id" ]] && continue

        # required: must be true|false (if explicitly set)
        if [[ -n "$in_required" && "$in_required" != "true" && "$in_required" != "false" ]]; then
            _complain "$rel: input '$in_id' has malformed required: '$in_required' (must be true|false)"
            continue
        fi
        # Optional inputs may skip source declaration.
        eff_required="${in_required:-true}"

        if [[ "$eff_required" == "true" && -z "$in_source" ]]; then
            _complain "$rel: input '$in_id' is required but has no source: (use 'source: stage:<X>' or 'source: external')"
            continue
        fi

        case "$in_source" in
            ""|external)
                if [[ "$in_source" == "external" && -z "${_LC_EXTERNAL_OK[$in_id]:-}" ]]; then
                    _complain "$rel: input '$in_id' uses source: external for id NOT in allowlist [$(manifest_graph_external_allowlist)] [ADR-020 decision 6]"
                fi
                ;;
            cycle_feedback)
                # ADR-020 amendment (#511 / F2): cycle_feedback inputs are
                # wired by `cycles[].feedback.to.input==<id>`. Constraints:
                #   - required:true is a contradiction (feedback is best-effort)
                #   - path MUST use ${cycle_feedback_dir}, not ${artifact_dir}
                if [[ "$eff_required" == "true" ]]; then
                    _complain "$rel: input '$in_id' source:cycle_feedback cannot be required:true (#511; cross-iter feedback is best-effort)"
                fi
                if [[ -n "$in_path" && "$in_path" == *'${artifact_dir}'* ]]; then
                    _complain "$rel: input '$in_id' source:cycle_feedback uses \${artifact_dir} in path (use \${cycle_feedback_dir}; cross-iter data must not pollute artifact namespace) [#511]"
                fi
                # Cross-template wiring (unwired/undeclared) is enforced by the
                # runtime contract-validator when the active template + plugin
                # set are known together. CI lint operates on plugins alone, so
                # it cannot decide unwired here — runtime validator owns that.
                ;;
            stage:*)
                producer="${in_source#stage:}"
                if [[ "$producer" == "$id" ]]; then
                    _complain "$rel: input '$in_id' is self-referential (source: stage:$producer == self)"
                    continue
                fi
                if [[ -z "${_LC_STAGE_MANIFEST[$producer]:-}" ]]; then
                    _complain "$rel: input '$in_id' references unknown stage '$producer' (no plugin manifest with id: $producer)"
                    continue
                fi
                if [[ -z "${_LC_STAGE_OUTPUTS[$producer:$in_id]:-}" ]]; then
                    _complain "$rel: input '$in_id' references stage:$producer but $producer does NOT declare output id '$in_id'"
                fi
                ;;
            *)
                _complain "$rel: input '$in_id' has malformed source: '$in_source' (must be 'stage:<X>' or 'external')"
                ;;
        esac
    done < <(manifest_graph_get_inputs "$m")
done

if [[ $_offences -gt 0 ]]; then
    printf '\nlint-contract: %d violation(s). See docs/adr/ADR-020-inter-stage-data-contract.md.\n' "$_offences" >&2
    exit 1
fi

exit 0
