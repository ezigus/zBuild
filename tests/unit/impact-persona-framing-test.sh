#!/usr/bin/env bash
# Unit (#1324 pattern): impact stage uses persona_stage_framing to open its prompt.
# SPEC assertions live in impact-prompt-override-test.sh (per ADR-036 testfile strategy).
# This file is a discovery stub created by the build stage so the glob in run-tests.sh
# finds it; the load-bearing SPEC-tagged assertions are in the override test.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: impact persona framing seam (companion stub)"
setup_test_env "impact-persona-framing"

# Minimal smoke: persona_stage_framing is resolvable after sourcing impact plugin.
# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$REPO_ROOT/plugins/agent/impact/plugin.sh"

assert_pass "persona_stage_framing function is available after sourcing impact plugin" \
    "$(declare -f persona_stage_framing >/dev/null 2>&1 && echo "ok" || echo "")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
