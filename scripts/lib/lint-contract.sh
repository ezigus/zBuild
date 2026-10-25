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

_LINT_CONTRACT_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
_LINT_CONTRACT_REPO="$(cd "$_LINT_CONTRACT_DIR/../.." && pwd)"

# shellcheck source=./manifest-graph.sh
source "$_LINT_CONTRACT_DIR/manifest-graph.sh"

_PLUGINS_ROOT="${ZBUILD_PLUGINS_ROOT:-$_LINT_CONTRACT_REPO/plugins}"

# ADR-047 §5: lint scope is DERIVED from the manifests, not a hardcoded roster. A
# manifest is in scope iff it is a stage: it writes a stage result
# (provides.result_contract). A backend service (orchestrator, cache, memory,
# persona, output destination) writes none. Declared inputs are retired
# (ADR-055 §1, amended 2026-10-12), so the old graph built from them would leave
# nothing in scope.
#
# The old CURATED SUBSET is retained ONLY as the strangler baseline: the parity test
# (tests/unit/preflight-lint-parity-test.sh) asserts the DERIVED set is a
# superset-or-equal of this list, so scope can never silently NARROW below what the
# hand-maintained list validated. Removed once the strangler window closes.
# shellcheck disable=SC2034  # strangler baseline: read by the scope-derivation test, not here
_LC_STAGE_IDS_TO_CHECK=(intake plan design build test acceptance-gate pr deploy validate monitor security-lens)

# _lc_id_in_scope <manifest-key> — in scope iff a data-dependency-graph node (ADR-047 §5).
_lc_id_in_scope() {
    [[ -n "${_LC_IS_STAGE[$1]:-}" ]]
}

# Build {stage_id → manifest_path} and {stage_id:output_id → 1} indices.
declare -A _LC_STAGE_MANIFEST=()
declare -A _LC_STAGE_OUTPUTS=()
declare -A _LC_IS_STAGE=()   # manifest key → 1 if it writes a stage result
# _lc_manifest_role <manifest> — echo provides.role (nested one level under provides:).
_lc_manifest_role() {
    awk '
        /^provides:/ { inp=1; next }
        inp && /^[A-Za-z_]/ { inp=0 }
        inp && /^[[:space:]]+role:[[:space:]]*/ {
            sub(/^[[:space:]]+role:[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, ""); print; exit
        }
    ' "$1" 2>/dev/null
}

_offences=0

while IFS= read -r -d '' m; do
    id="$(manifest_graph_get_stage_id "$m")"
    [[ -z "$id" ]] && continue
    _role="$(_lc_manifest_role "$m")"
    # Index the manifest maps by BOTH the plugin id AND a `role:<role>` key, so a
    # template reference (feedback.from.stage / input source:stage:X) whose stage
    # id ≠ plugin id can still resolve via role-then-id — mirroring dispatch's
    # resolve_stage_plugin (ADR-042). E.g. the `acceptance-gate` stage binds role
    # `acceptance_gate`, served by the method-named `spec-acceptance` plugin.
    _keys=("$id")
    [[ -n "$_role" ]] && _keys+=("role:$_role")
    if grep -qE '^[[:space:]]+result_contract:' "$m" 2>/dev/null; then
        for _k in "${_keys[@]}"; do _LC_IS_STAGE["$_k"]=1; done
    fi
    for _k in "${_keys[@]}"; do _LC_STAGE_MANIFEST["$_k"]="$m"; done
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        out_id="${rec%%|*}"
        [[ -n "$out_id" ]] && for _k in "${_keys[@]}"; do _LC_STAGE_OUTPUTS["$_k:$out_id"]=1; done
    done < <(manifest_graph_get_outputs "$m")
done < <(find "$_PLUGINS_ROOT" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)

_complain() {
    printf 'lint-contract: %s\n' "$*" >&2
    _offences=$((_offences + 1))
}

for id in "${!_LC_STAGE_MANIFEST[@]}"; do
    # Each manifest is indexed under BOTH its plugin id and a `role:<role>` alias
    # (for reference resolution). Enforce ONCE, via the id key — skip the role:
    # alias so a role-bound manifest isn't linted twice (duplicate diagnostics /
    # double-counted offences). _LC_IS_STAGE is set on every key, so the id
    # key carries the same in-scope decision.
    [[ "$id" == role:* ]] && continue
    m="${_LC_STAGE_MANIFEST[$id]}"
    rel="${m#"$_LINT_CONTRACT_REPO"/}"

    # Only enforce on stage-bound plugins (ADR-020 scope).
    _lc_id_in_scope "$id" || continue

    if grep -qE '^inputs:' "$m" 2>/dev/null; then
        _complain "$rel: declares inputs:, which are retired — every stage gets every stage's latest output (ADR-055 §1, ADR-068 §8) [INPUTS_RETIRED]"
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

    # ── ADR-055 §9 (#2000): EXACTLY ONE outputs[].summary: true ───────────
    # A stage that publishes nothing is indistinguishable from one that had
    # nothing to say, so zero is no longer legal. This is the tree-wide echo of
    # the pre-flight SUMMARY_MISSING check — the validator is the AUTHORITY,
    # because it walks the resolved flow and can see a stage authored outside
    # this repository, which this scan structurally cannot.
    summary_count=$(awk '
        BEGIN { in_out=0; n=0 }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && /^[[:space:]]+summary:[[:space:]]*true([[:space:]]|$|#)/ { n++ }
        END { print n }
    ' "$m" 2>/dev/null)
    if [[ "$summary_count" -eq 0 ]]; then
        _complain "$rel: declares no outputs[] entry with 'summary: true' — every stage-bound plugin must state what it did [ADR-055 §9 SUMMARY_MISSING]"
    elif [[ "$summary_count" -gt 1 ]]; then
        _complain "$rel: $summary_count outputs[] entries declare 'summary: true' (exactly one) [ADR-055 §9 SUMMARY_DUP]"
    fi

done

# #1980: the OUTPUT_UNCONSUMED check is retired. It asked a PRODUCER to declare
# whether anyone consumes its output — a property of the TEMPLATE, not of the
# plugin, so the same plugin in a different flow needed a different answer. The
# 24 `terminal:`/`advisory:` annotations it forced were written to pass a gate,
# not to describe an artifact. The mirror check (a required input naming no
# producer) went with declared inputs (ADR-055 §1, amended 2026-10-12).

# #2368: the ADR-040 §5 convergence-path guard is gone with the `convergence:`
# marker it read; a loop's exit_when names its must-pass members.

if [[ $_offences -gt 0 ]]; then
    printf '\nlint-contract: %d violation(s). See docs/adr/ADR-020-inter-stage-data-contract.md.\n' "$_offences" >&2
    exit 1
fi

exit 0
