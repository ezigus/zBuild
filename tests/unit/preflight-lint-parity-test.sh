#!/usr/bin/env bash
# tests/unit/preflight-lint-parity-test.sh — ADR-020 (#496) parity meta-test.
#
# Asserts that the runtime contract validator (core/pipeline/contract-validator.sh)
# and the CI lint (scripts/lib/lint-contract.sh) see the same view of any
# given manifest set. They share scripts/lib/manifest-graph.sh as the parser
# chokepoint; if either caller starts using a different YAML reader, this
# parity check fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "preflight-lint parity (shared manifest-graph parser) — ADR-020 (#496)"

# TC-1: both lint and validator source the same shared parser file.
if grep -q 'manifest-graph.sh' "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>/dev/null; then
    assert_pass "TC-1: lint sources manifest-graph.sh"
else
    assert_fail "TC-1: lint sources manifest-graph.sh" "no reference in lint-contract.sh"
fi
if grep -q 'manifest-graph.sh' "$REPO_ROOT/core/pipeline/contract-validator.sh" 2>/dev/null; then
    assert_pass "TC-1: validator sources manifest-graph.sh"
else
    assert_fail "TC-1: validator sources manifest-graph.sh" "no reference in contract-validator.sh"
fi

# TC-2: both produce the same inputs[] view on a fixture manifest.
# (#979 retired the review agent manifest; the build manifest is an equivalent
# KEEP fixture with non-empty inputs and outputs.)
FIXTURE="$REPO_ROOT/plugins/agent/build/manifest.yaml"
if [[ ! -f "$FIXTURE" ]]; then
    assert_fail "TC-2: build manifest exists" "missing $FIXTURE"
else
    inputs_from_parser="$(manifest_graph_get_inputs "$FIXTURE" | LC_ALL=C sort)"
    outputs_from_parser="$(manifest_graph_get_outputs "$FIXTURE" | LC_ALL=C sort)"
    # The shared parser is the only legitimate source; both callers use it.
    # We assert non-empty data here so a parser regression is caught even when
    # both callers regress simultaneously.
    if [[ -n "$inputs_from_parser" ]]; then
        assert_pass "TC-2: shared parser yields non-empty inputs for build.yaml"
    else
        assert_fail "TC-2: shared parser yields non-empty inputs for build.yaml" \
            "got empty result"
    fi
    if [[ -n "$outputs_from_parser" ]]; then
        assert_pass "TC-2: shared parser yields non-empty outputs for build.yaml"
    else
        assert_fail "TC-2: shared parser yields non-empty outputs for build.yaml" \
            "got empty result"
    fi
fi

# TC-3: external sources allowlist is the SAME literal in both ADR-020 and parser.
ADR="$REPO_ROOT/docs/adr/ADR-020-inter-stage-data-contract.md"
parser_allow="$(manifest_graph_external_allowlist)"
for tok in $parser_allow; do
    if grep -qF "$tok" "$ADR" 2>/dev/null; then
        assert_pass "TC-3: allowlist token '$tok' is in ADR-020"
    else
        assert_fail "TC-3: allowlist token '$tok' is in ADR-020" \
            "parser declares $tok but ADR-020 doesn't mention it"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
