#!/usr/bin/env bash
# discover_plugins must not re-validate an unchanged tree on every call.
#
# Measured with an already-warm manifest cache:
#   validate_manifest  39ms each
#   discover_plugins   1.47s per call (it validates all ~56 plugins, every time)
#
# template-resolvability-preflight-test.sh resolves 19 leaves across 2 templates
# = 38 calls = ~56s, which is the whole of its remaining 66s block after the
# read-cache fix. The tree does not change between those 38 calls.
#
# Same shape as the yaml cache before it: the memo must be filled in a shell the
# later subshells descend from, because callers consume discovery through
# `< <(…)` and resolve_stage_plugin wraps that in `$( )`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# discovery.sh reads _ZBUILD_ROOT at source time for its default root.
_ZBUILD_ROOT="$REPO_ROOT"
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
# shellcheck source=../../core/plugin-registry/discovery.sh
source "$REPO_ROOT/core/plugin-registry/discovery.sh"

print_test_header "discover_plugins memoises an unchanged tree"
setup_test_env "discover-plugins-memo"

# ─── SPEC-1: GUARD — the answer is identical cached vs uncached ───────────
_fresh="$(ZBUILD_PLUGIN_DISCOVERY_CACHE=0 discover_plugins "$REPO_ROOT/plugins" 2>/dev/null | sort)"
_first="$(discover_plugins "$REPO_ROOT/plugins" 2>/dev/null | sort)"
assert_eq "[SPEC-1] GUARD: the memoised list equals the uncached list" "$_fresh" "$_first"
assert_gt "[SPEC-1] GUARD: and it is a real, non-empty list" \
    "$(printf '%s\n' "$_first" | grep -c . || true)" "0"

# ─── SPEC-2: a repeat call in the same shell does not re-walk ─────────────
# Timed in THIS shell, not in $( ): a command substitution would discard the
# memo and both calls would measure a cold cache — the trap that produced a
# convincing false red earlier in this work.
discover_plugins "$REPO_ROOT/plugins" >/dev/null 2>&1 || true   # warm
_a="$EPOCHREALTIME"; discover_plugins "$REPO_ROOT/plugins" >/dev/null 2>&1 || true
_b="$EPOCHREALTIME"
_repeat_ms="$(awk -v a="$_a" -v b="$_b" 'BEGIN{printf "%d",(b-a)*1000}')"
assert_eq "[SPEC-2] a warm repeat call costs under 100ms (was ~1470ms)" \
    "1" "$(awk -v m="$_repeat_ms" 'BEGIN{print (m<100)?1:0}')"

# ─── SPEC-3: GUARD — a different tree gets its own answer ────────────────
_alt="$TEST_TEMP_DIR/altplugins/tool/solo"
mkdir -p "$_alt"
cp "$REPO_ROOT/plugins/tool/lint-gate/manifest.yaml" "$_alt/manifest.yaml"
sed -i.bak 's/^id: .*/id: solo/' "$_alt/manifest.yaml"; rm -f "$_alt/manifest.yaml.bak"
_altlist="$(discover_plugins "$TEST_TEMP_DIR/altplugins" 2>/dev/null)"
assert_eq "[SPEC-3] GUARD: a different plugins root resolves to its own tree" \
    "$_alt" "$_altlist"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
