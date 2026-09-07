#!/usr/bin/env bash
# Regression guard for #2061: spec-coverage calls route_to_model in production,
# so its plugin must load the shared router when no host router is present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "spec-coverage router dependency (#2061)"
setup_test_env "spec-coverage-router-source"

PLUGIN="$REPO_ROOT/plugins/agent/spec-coverage/plugin.sh"
assert_contains "spec-coverage sources the shared model router" \
    "$(cat "$PLUGIN")" $'source "$_SCV_ROOT/core/router/route.sh"'

print_test_results
exit $((FAIL > 0))
