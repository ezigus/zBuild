#!/usr/bin/env bash
# tests/unit/plugin-manifest-contract-audit-test.sh — ADR-020 (#496) drift audit.
#
# Asserts that every stage-bound plugin manifest in the repo satisfies the
# inter-stage data contract. This is the regression test that catches a future
# manifest edit that drops `source:` or `required:` from an entry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "plugin manifest contract audit — ADR-020 (#496)"

# The stage-bound plugin manifests migrated in #496. (The review agent
# manifest was removed with #979 when the review stage was retired.)
STAGE_MANIFESTS=(
    "plugins/agent/intake/manifest.yaml"
    "plugins/agent/plan/manifest.yaml"
    "plugins/agent/build/manifest.yaml"
    "plugins/agent/security-lens/manifest.yaml"
    "plugins/tool/test/manifest.yaml"
    "plugins/tool/pr-open/manifest.yaml"
)

for rel in "${STAGE_MANIFESTS[@]}"; do
    m="$REPO_ROOT/$rel"
    if [[ ! -f "$m" ]]; then
        assert_fail "$rel exists" "missing"
        continue
    fi

    # Inputs block present (explicit `inputs: []` counts).
    if manifest_graph_inputs_block_present "$m"; then
        assert_pass "$rel: inputs: block present"
    else
        assert_fail "$rel: inputs: block present" \
            "no inputs: declared — use 'inputs: []' for zero-input plugins"
    fi

    # Every input has source: and required: declared.
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        IFS='|' read -r in_id _t in_source in_required _p <<< "$rec"
        [[ -z "$in_id" ]] && continue
        if [[ -n "$in_source" ]]; then
            assert_pass "$rel: input '$in_id' has source: ($in_source)"
        else
            assert_fail "$rel: input '$in_id' has source:" "missing source: declaration"
        fi
        case "${in_required:-}" in
            true|false)
                assert_pass "$rel: input '$in_id' required=$in_required"
                ;;
            *)
                assert_fail "$rel: input '$in_id' required: is true|false" \
                    "got '${in_required:-<empty>}'"
                ;;
        esac
    done < <(manifest_graph_get_inputs "$m")

    # Every output has required: declared.
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        IFS='|' read -r out_id _t _s out_required _p <<< "$rec"
        [[ -z "$out_id" ]] && continue
        case "${out_required:-}" in
            true|false)
                assert_pass "$rel: output '$out_id' required=$out_required"
                ;;
            *)
                assert_fail "$rel: output '$out_id' required: is true|false" \
                    "got '${out_required:-<empty>}'"
                ;;
        esac
    done < <(manifest_graph_get_outputs "$m")
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
