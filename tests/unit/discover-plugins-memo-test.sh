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

# ─── SPEC-4..8 (ADR-065 §3): the memo survives a subshell and a new process ──
# Callers resolve stages inside `$( )`, where an in-shell memo dies, so a test
# or a plugin process that never warms it walked and re-validated every
# manifest on every lookup: 10,009 programs in stage-resolution-parity-test.sh.
# The walk's answer is kept in a file next to the run's state; it is reused
# only while nothing under the plugins tree or the validator code is newer.
_ft="$TEST_TEMP_DIR/ftree"; mkdir -p "$_ft/tool"
for _p in lint-gate secret-scan-lib teardown; do
    [[ -d "$REPO_ROOT/plugins/tool/$_p" ]] && cp -R "$REPO_ROOT/plugins/tool/$_p" "$_ft/tool/$_p"
done
_WALKS="$TEST_TEMP_DIR/walks"; : > "$_WALKS"
eval "$(declare -f validate_manifest | sed '1s/^validate_manifest/_orig_validate_manifest/')"
validate_manifest() { printf 'x\n' >> "$_WALKS"; _orig_validate_manifest "$@"; }
_nwalk() { wc -l < "$_WALKS" | tr -d ' '; }
_cold() { ( discovery_cache_flush_memory 2>/dev/null || { _ZBUILD_DISCOVERY_CACHE=(); _ZBUILD_DISCOVERY_SHAPE=(); }; discover_plugins "$_ft" 2>/dev/null | sort ); }
_n_manifests="$(find "$_ft" -name manifest.yaml | wc -l | tr -d ' ')"

_l1="$(_cold)"; _w1="$(_nwalk)"
assert_eq "[SPEC-4] the first cold lookup walks the tree (validates each manifest once)" "$_n_manifests" "$_w1"
_l2="$(_cold)"
assert_eq "[SPEC-4] a second cold lookup, in a new subshell, does not walk again" "$_w1" "$(_nwalk)"
assert_eq "[SPEC-4] …and gives the same answer" "$_l1" "$_l2"
_l2b="$(bash -c "source '$REPO_ROOT/scripts/lib/helpers.sh'; _ZBUILD_ROOT='$REPO_ROOT'; source '$REPO_ROOT/core/plugin-registry/manifest-validation.sh'; source '$REPO_ROOT/core/plugin-registry/discovery.sh'; discover_plugins '$_ft' 2>/dev/null | sort")"
assert_eq "[SPEC-5] a new process gets the same answer from the memo" "$_l1" "$_l2b"

# An edited manifest is newer than the memo: the next lookup walks and sees it.
_victim="$(printf '%s\n' "$_l1" | head -1)"   # sigpipe-ok: test-only, printf of a short list
sleep 0.01
printf 'id: \n' > "$_victim/manifest.yaml"
_l3="$(_cold)"
assert_eq "[SPEC-6] after a manifest is edited in place the lookup walks again" "1" "$(( $(_nwalk) > _w1 ))"
assert_eq "[SPEC-6] …and the now-invalid plugin is gone from the answer" "0" "$(grep -cxF "$_victim" <<< "$_l3" || true)"
_w3="$(_nwalk)"
# A changed plugin source file (requires.core is resolved from it) also walks.
_src="$(find "$_ft" -name '*.sh' -not -path '*/tests/*' | head -1)"   # sigpipe-ok: test-only
sleep 0.01; printf '\n' >> "$_src"
_cold >/dev/null
assert_eq "[SPEC-7] after a plugin's source changes the lookup walks again" "1" "$(( $(_nwalk) > _w3 ))"
_w4="$(_nwalk)"
discovery_cache_flush
_cold >/dev/null
assert_eq "[SPEC-8] discovery_cache_flush drops the file memo too" "1" "$(( $(_nwalk) > _w4 ))"
_w5="$(_nwalk)"
( ZBUILD_PLUGIN_DISCOVERY_CACHE=0 discover_plugins "$_ft" >/dev/null 2>&1 )
assert_eq "[SPEC-8] ZBUILD_PLUGIN_DISCOVERY_CACHE=0 always walks" "1" "$(( $(_nwalk) > _w5 ))"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
