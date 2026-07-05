#!/usr/bin/env bash
# tests/unit/impact-tier-test.sh — #960 / #1230 / #1231
#
# History: impact is the most tool-heavy agentic stage (Reads every design-scope
# file + repo-wide greps). On T1 (haiku) its per-turn latency × the number of
# tool turns exceeds the router timeout once the design scope is non-trivial
# (rc=124). It MUST be tiered like its reasoning siblings (T2/sonnet). #960
# declared tier_default:T2 in the manifest but plugin.sh kept a `:-T1}` literal,
# so nothing wired the manifest and the T1 fallback silently won.
#
# #1231 makes the manifest config.tier_default the SINGLE source of truth: the
# per-plugin `${ZBUILD_<ID>_TIER:-Tn}` literals are retired and resolve_tier
# reads the manifest (operator ZBUILD_<ID>_TIER still overrides). This guard is
# therefore FLIPPED from "the literal matches the manifest" to "there is NO
# literal, and resolve_tier returns the manifest value." A reintroduced literal
# is the #960/#1230 drift class and MUST fail here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/tier-resolve.sh
source "$REPO_ROOT/scripts/lib/tier-resolve.sh"

print_test_header "impact tier + no-hardcoded-tier-literal drift-guard (#960/#1230/#1231)"

# ─── impact resolves T2 from its manifest (the #960 fix, now via resolve_tier) ─
impact_tier="$(resolve_tier impact "$REPO_ROOT/plugins/agent/impact")"
design_tier="$(resolve_tier design "$REPO_ROOT/plugins/agent/design")"
assert_eq "impact resolves T2 (not T1 — avoids the haiku router timeout)" "T2" "$impact_tier"
assert_eq "impact is tiered like its tool-heavy sibling design" "$design_tier" "$impact_tier"

# ─── #1231 anti-drift invariant: NO plugin.sh has a hardcoded tier literal ───
# The `${ZBUILD_<ID>_TIER:-T[0-4]}` literal is the exact construct that drifted
# from the manifest (#960/#1230). Repo-wide, no plugin.sh may reintroduce it —
# the manifest config.tier_default is the only per-plugin tier declaration.
print_test_section "no plugin.sh contains a \${ZBUILD_*_TIER:-T[0-4]} literal (repo-wide)"
_offenders="$(grep -rlE '\$\{ZBUILD_[A-Z_]+_TIER:-T[0-4]\}' \
    "$REPO_ROOT"/plugins/*/*/plugin.sh 2>/dev/null || true)"
assert_eq "no hardcoded tier fallback literal remains in any plugin.sh" \
    "" "$_offenders"

# ─── #1231 resolve_tier contract: manifest value + operator override ─────────
print_test_section "resolve_tier: manifest is source of truth, ZBUILD_<ID>_TIER overrides"
assert_eq "manifest config.tier_default drives impact's tier" \
    "T2" "$(resolve_tier impact "$REPO_ROOT/plugins/agent/impact")"
assert_eq "ZBUILD_IMPACT_TIER overrides the manifest" \
    "T4" "$(ZBUILD_IMPACT_TIER=T4 resolve_tier impact "$REPO_ROOT/plugins/agent/impact")"

# ─── every agent plugin that routes resolves a valid tier == its manifest ────
# _tier() reads the manifest directly; resolve_tier must agree (no drift).
# `|| true`: under set -euo pipefail a no-match grep (rc 1) or a SIGPIPE from the
# `head -1` early close (rc 141) would otherwise propagate through the plain
# assignment below and abort the script on the first tier-less plugin.
_tier() { { grep -E '^[[:space:]]*tier_default:' "$1" 2>/dev/null | head -1 | awk '{print $2}'; } || true; }
print_test_section "resolve_tier == manifest tier_default for every agent plugin"
for _plugin_sh in "$REPO_ROOT"/plugins/agent/*/plugin.sh; do
    _dir="$(dirname "$_plugin_sh")"
    _name="$(basename "$_dir")"
    _mf="$(_tier "$_dir/manifest.yaml")"
    [[ -z "$_mf" ]] && continue   # plugin declares no tier_default (non-routing)
    _resolved="$(resolve_tier "$_name" "$_dir" 2>/dev/null || echo ERR)"
    assert_eq "[drift] $_name: resolve_tier ($_resolved) == manifest tier_default ($_mf)" \
        "$_mf" "$_resolved"
done

print_test_results
exit $((FAIL > 0))
