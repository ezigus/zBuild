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

# ─── #1230 S1: impact plugin.sh tier fallback matches its manifest ───────────
# #960 declared tier_default:T2 but plugin.sh:255 kept the `:-T1}` fallback, so
# nothing wired the manifest and the T1 fallback silently won (rc=124 timeout).
_plugin_tier_fallback() {
    # Extract the T? in the FIRST `${ZBUILD_*_TIER:-T?}` fallback of a plugin.sh.
    # Empty when the plugin has no such fallback (tolerant: pipefail-safe).
    { grep -oE '\$\{ZBUILD_[A-Z_]+_TIER:-T[0-4]\}' "$1" 2>/dev/null || true; } \
        | head -1 | { grep -oE 'T[0-4]' || true; }
}
impact_fallback="$(_plugin_tier_fallback "$REPO_ROOT/plugins/agent/impact/plugin.sh")"
assert_eq "[S1] impact plugin.sh tier fallback is T2 (honors manifest tier_default)" \
    "T2" "$impact_fallback"

# ─── #1230 S2: drift-guard — every agent plugin's tier fallback == manifest ──
# No plugin may silently drift its `:-T?}` fallback away from its declared
# config.tier_default (the #960/#1230 regression class).
print_test_section "S2: plugin tier fallback == manifest tier_default (drift-guard)"
for _plugin_sh in "$REPO_ROOT"/plugins/agent/*/plugin.sh; do
    _fb="$(_plugin_tier_fallback "$_plugin_sh")"
    [[ -z "$_fb" ]] && continue   # plugin has no single-shot tier fallback
    _dir="$(dirname "$_plugin_sh")"
    _name="$(basename "$_dir")"
    _mf="$(_tier "$_dir/manifest.yaml")"
    assert_eq "[S2] $_name: plugin.sh fallback ($_fb) == manifest tier_default ($_mf)" \
        "$_mf" "$_fb"
done

print_test_results
exit $((FAIL > 0))
