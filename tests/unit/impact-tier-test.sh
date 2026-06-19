#!/usr/bin/env bash
# tests/unit/impact-tier-test.sh — #960
#
# impact is the most tool-heavy agentic stage (Reads every design-scope file +
# repo-wide greps). On T1 (haiku) its per-turn latency × the number of tool
# turns exceeds the 180s router timeout once the design scope is non-trivial
# (rc=124, run 20260619082915-41231). It MUST be tiered like its reasoning
# siblings (T2/sonnet), not left on the mechanical-gate tier. This guard fails
# at the pre-fix T1 baseline so a future edit can't silently reintroduce the
# timeout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact stage tier — must be T2, not T1 (#960)"

# First `tier_default:` under the manifest's config block.
_tier() { grep -E '^[[:space:]]*tier_default:' "$1" 2>/dev/null | head -1 | awk '{print $2}'; }

impact_tier="$(_tier "$REPO_ROOT/plugins/agent/impact/manifest.yaml")"
design_tier="$(_tier "$REPO_ROOT/plugins/agent/design/manifest.yaml")"

assert_eq "impact is tiered T2 (not T1 — avoids the haiku router timeout)" "T2" "$impact_tier"
assert_eq "impact is tiered like its tool-heavy sibling design" "$design_tier" "$impact_tier"

print_test_results
exit $((FAIL > 0))
