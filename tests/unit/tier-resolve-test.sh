#!/usr/bin/env bash
# tests/unit/tier-resolve-test.sh — #1231
#
# resolve_tier <plugin_id> <plugin_dir> is the single accessor for a plugin's
# model tier: manifest config.tier_default is the source of truth, the operator
# override ZBUILD_<ID>_TIER wins, an undeclared/invalid tier fails loud, and the
# env-var name is derived from the (possibly hyphenated) plugin id. These are
# the contracts every retired plugin fallback now depends on (ADR-003).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/tier-resolve.sh
source "$REPO_ROOT/scripts/lib/tier-resolve.sh"

print_test_header "resolve_tier — manifest is the single source of truth (#1231)"

# Fixture plugin dirs with a config.tier_default manifest.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/simple" "$TMP/review-lens" "$TMP/badtier" "$TMP/notier"
printf 'config:\n  tier_default: T3\n' > "$TMP/simple/manifest.yaml"
printf 'config:\n  tier_default: T2\n' > "$TMP/review-lens/manifest.yaml"
printf 'config:\n  tier_default: T9\n' > "$TMP/badtier/manifest.yaml"
printf 'config:\n  max_findings: 50\n' > "$TMP/notier/manifest.yaml"

# ─── manifest fallback ───────────────────────────────────────────────────────
print_test_section "manifest config.tier_default"
assert_eq "reads tier_default from the plugin's own manifest" \
    "T3" "$(resolve_tier simple "$TMP/simple")"

# ─── env override wins ───────────────────────────────────────────────────────
print_test_section "ZBUILD_<ID>_TIER override wins"
assert_eq "operator override beats the manifest value" \
    "T4" "$(ZBUILD_SIMPLE_TIER=T4 resolve_tier simple "$TMP/simple")"

# ─── hyphenated-id env-var derivation ────────────────────────────────────────
print_test_section "hyphenated id → env var name"
# review-lens → ZBUILD_REVIEW_LENS_TIER (upper + '-'→'_').
assert_eq "manifest fallback for a hyphenated id" \
    "T2" "$(resolve_tier review-lens "$TMP/review-lens")"
assert_eq "ZBUILD_REVIEW_LENS_TIER overrides the hyphenated-id manifest" \
    "T0" "$(ZBUILD_REVIEW_LENS_TIER=T0 resolve_tier review-lens "$TMP/review-lens")"

# ─── missing tier → fail loud ────────────────────────────────────────────────
print_test_section "undeclared tier fails loud"
_rc=0; resolve_tier notier "$TMP/notier" >/dev/null 2>&1 || _rc=$?
assert_exit_code "no config.tier_default and no env → non-zero" 1 "$_rc"

_rc=0; resolve_tier missingdir "$TMP/does-not-exist" >/dev/null 2>&1 || _rc=$?
assert_exit_code "missing manifest → non-zero" 1 "$_rc"

# ─── invalid tier value → fail loud ──────────────────────────────────────────
print_test_section "invalid tier value fails loud"
_rc=0; resolve_tier badtier "$TMP/badtier" >/dev/null 2>&1 || _rc=$?
assert_exit_code "manifest tier T9 (out of T0-T4) → non-zero" 1 "$_rc"

_rc=0; ZBUILD_SIMPLE_TIER=nonsense resolve_tier simple "$TMP/simple" >/dev/null 2>&1 || _rc=$?
assert_exit_code "env override with a bad value → non-zero" 1 "$_rc"

# ─── missing args → fail loud ────────────────────────────────────────────────
print_test_section "missing args fail loud"
_rc=0; resolve_tier >/dev/null 2>&1 || _rc=$?
assert_exit_code "no args → non-zero" 1 "$_rc"

# ─── template router.tier source (#1252) ─────────────────────────────────────
# resolve_tier gained a THIRD source between the env override and the manifest:
# the loaded template's per-stage `router.tier`, keyed by ZBUILD_CURRENT_STAGE.
# Precedence: env ZBUILD_<ID>_TIER > template router.tier > manifest tier_default.
# In this unit test template.sh is NOT sourced, so we stub the accessor and set
# ZBUILD_CURRENT_STAGE, mirroring how the dispatch paths export the stage id.
print_test_section "template router.tier feeds resolve_tier (env > template > manifest)"

# Stub the accessor: returns $__STUB_TIER for the stage we pin, empty otherwise.
template_stage_router_tier() {
    local stage="$1"
    if [[ -n "${__STUB_TIER:-}" && "$stage" == "${__STUB_STAGE:-}" ]]; then
        # Mirror the real accessor's read-time ^T[0-4]$ fail-loud validation so a
        # bad template value surfaces here just as it would in production.
        if [[ ! "$__STUB_TIER" =~ ^T[0-4]$ ]]; then
            error "template_stage_router_tier: invalid tier '$__STUB_TIER'"
            return 1
        fi
        printf '%s\n' "$__STUB_TIER"
    fi
    return 0
}

# template-only (env unset) → template tier wins over the manifest default.
__STUB_STAGE=simple __STUB_TIER=T1 \
assert_eq "template router.tier used when env unset (T1 beats manifest T3)" \
    "T1" "$(ZBUILD_CURRENT_STAGE=simple __STUB_STAGE=simple __STUB_TIER=T1 resolve_tier simple "$TMP/simple")"

# env beats template.
assert_eq "env ZBUILD_<ID>_TIER beats template router.tier" \
    "T4" "$(ZBUILD_SIMPLE_TIER=T4 ZBUILD_CURRENT_STAGE=simple __STUB_STAGE=simple __STUB_TIER=T1 resolve_tier simple "$TMP/simple")"

# template beats manifest (explicit restatement with review-lens manifest T2).
assert_eq "template router.tier beats manifest tier_default" \
    "T0" "$(ZBUILD_CURRENT_STAGE=review-lens __STUB_STAGE=review-lens __STUB_TIER=T0 resolve_tier review-lens "$TMP/review-lens")"

# no ZBUILD_CURRENT_STAGE → template source is skipped → falls back to manifest.
assert_eq "no ZBUILD_CURRENT_STAGE → template source skipped, manifest wins" \
    "T3" "$(__STUB_STAGE=simple __STUB_TIER=T1 resolve_tier simple "$TMP/simple")"

# invalid template tier (T9) → fail loud (the read-time validator rejects it).
_rc=0; ZBUILD_CURRENT_STAGE=simple __STUB_STAGE=simple __STUB_TIER=T9 \
    resolve_tier simple "$TMP/simple" >/dev/null 2>&1 || _rc=$?
assert_exit_code "invalid template router.tier T9 → non-zero (fail loud)" 1 "$_rc"

# CRITICAL INVARIANT (#1231): with NO template tier set the manifest default must
# resolve exactly as today — behavior unchanged when the new source is silent.
assert_eq "empty template tier + stage set → manifest default unchanged (#1231 invariant)" \
    "T3" "$(ZBUILD_CURRENT_STAGE=simple __STUB_STAGE=other __STUB_TIER=T1 resolve_tier simple "$TMP/simple")"

unset -f template_stage_router_tier

# ─── behavior-identical: the shipped agent plugins resolve their manifest tier ──
# (#979: test_assessment + the old `review` stage were retired with the
# compound-quality lattice, so they drop out of this list.)
print_test_section "the shipped agent plugins resolve their manifest tier"
_expect_tier() {  # <plugin> <expected>
    local p="$1" want="$2" dir="$REPO_ROOT/plugins/agent/$1"
    assert_eq "$p resolves $want (== its manifest, unchanged behavior)" \
        "$want" "$(resolve_tier "$p" "$dir")"
}
_expect_tier design T2
_expect_tier plan T2
_expect_tier security-lens T3
_expect_tier review-report T2
_expect_tier review-lens T2
_expect_tier impact T2
_expect_tier build T2

print_test_results
exit $((FAIL > 0))
