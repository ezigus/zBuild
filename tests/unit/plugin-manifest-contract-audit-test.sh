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

    # #1825 / ADR-055 §1: an input declares its NAME and whether it is required,
    # and nothing else. It names no producer, restates no path and restates no
    # type — the producer already declared all three, and a second declaration
    # that can disagree with the first is not a contract. `source: external` is
    # the one survivor (§1.2), because it names something outside the pipeline
    # and so has no producer to resolve.
    #
    # This replaces the inverse assertion ("every input HAS source:"), which was
    # correct under ADR-020 and is exactly what this change deletes.
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        IFS='|' read -r in_id in_type in_source in_required in_path <<< "$rec"
        [[ -z "$in_id" ]] && continue
        if [[ -z "$in_source" || "$in_source" == "external" ]]; then
            assert_pass "$rel: input '$in_id' declares no producer${in_source:+ (external)}"
        else
            assert_fail "$rel: input '$in_id' declares no producer" \
                "source: '$in_source' — a consumer names an artifact, not a stage (ADR-055 §1.2)"
        fi
        if [[ -z "$in_path" ]]; then
            assert_pass "$rel: input '$in_id' restates no path"
        else
            assert_fail "$rel: input '$in_id' restates no path" "path: '$in_path'"
        fi
        if [[ -z "$in_type" ]]; then
            assert_pass "$rel: input '$in_id' restates no type"
        else
            assert_fail "$rel: input '$in_id' restates no type" "type: '$in_type'"
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
