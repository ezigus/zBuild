#!/usr/bin/env bash
# tests/unit/test-env-no-credentials-test.sh — no test sees a real credential
# (#2588, ADR-012).
#
# C1 [change] setup_test_env clears every real GitHub credential: a token set
#             before setup is gone after it.
#             (#2532 run 45102665787: on a CI runner RG9 read the runner's
#             real GITHUB_TOKEN and printed it; push protection refused the
#             push and GitHub revoked the token.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# A value shaped like a real token, set before the harness loads.
_REAL="ghs_C2realLooking0123456789abcdefABCDEF"
export GH_TOKEN="$_REAL" GITHUB_TOKEN="$_REAL" GH_ENTERPRISE_TOKEN="$_REAL" GITHUB_ENTERPRISE_TOKEN="$_REAL" \
    CLAUDE_CODE_OAUTH_TOKEN="$_REAL" ANTHROPIC_API_KEY="$_REAL"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "no test sees a real credential (#2588)"
# C0: cleared as soon as the harness is sourced, so a test that never calls
# setup_test_env is covered too (review of #2588: 47 test files do not).
_c0=""; for _v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY; do
    [[ -n "${!_v+x}" ]] && _c0+="$_v "; done
assert_eq "[C0] sourcing the harness clears every real credential" "" "$_c0"
setup_test_env "no-credentials"

print_test_section "C1: the harness clears them"
assert_eq "[C1] GH_TOKEN is unset" "unset" "${GH_TOKEN-unset}"
assert_eq "[C1] GITHUB_TOKEN is unset" "unset" "${GITHUB_TOKEN-unset}"
assert_eq "[C1] GH_ENTERPRISE_TOKEN is unset" "unset" "${GH_ENTERPRISE_TOKEN-unset}"
assert_eq "[C1] GITHUB_ENTERPRISE_TOKEN is unset" "unset" "${GITHUB_ENTERPRISE_TOKEN-unset}"
assert_eq "[C1] CLAUDE_CODE_OAUTH_TOKEN is unset" "unset" "${CLAUDE_CODE_OAUTH_TOKEN-unset}"
assert_eq "[C1] ANTHROPIC_API_KEY is unset" "unset" "${ANTHROPIC_API_KEY-unset}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
