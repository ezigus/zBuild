#!/usr/bin/env bash
# tests/unit/discovery-cold-lookup-test.sh — #2105
# A persona lookup must not pay the full discovery walk, and the runner must
# fill the discovery memo in ITS OWN shell (not inside a process substitution
# that dies before main() runs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "discovery — cold lookups do not pay the full walk (#2105)"
setup_test_env "discovery-cold-lookup"

WALKS="$TEST_TEMP_DIR/walks.count"
: > "$WALKS"
# Wrap the walk with a file-backed counter: the walk runs inside $( ) in
# discover_plugins, so a shell variable would not survive; a file does.
eval "$(declare -f _discover_plugins_walk | sed '1s/^_discover_plugins_walk/_orig_discover_plugins_walk/')"
_discover_plugins_walk() { printf 'walk\n' >> "$WALKS"; _orig_discover_plugins_walk "$@"; }
_walks() { grep -c '' "$WALKS" 2>/dev/null || echo 0; }

PROOT="$REPO_ROOT/plugins"

# ─── [#2105-1] cold find_persona of a shipped persona: 0 walks ───────────────
discovery_cache_flush
: > "$WALKS"
set +e
mf="$(find_persona security "$PROOT")"; rc=$?
set -e
assert_eq "[#2105-1] find_persona resolves the shipped security persona" "0" "$rc"
assert_contains "[#2105-1] path is the canonical persona manifest" "$mf" "plugins/persona/security/manifest.yaml"
assert_eq "[#2105-1] a cold find_persona performed 0 discovery walks" "0" "$(_walks)"

# ─── [#2105-2] an unknown id still falls through to the walk (and is absent) ──
: > "$WALKS"
set +e
find_persona ghost-persona-2105 "$PROOT" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[#2105-2] unknown persona returns 1" "1" "$rc"
assert_eq "[#2105-2] the fallback walk still runs for an unknown id" "1" "$(_walks)"

# ─── [#2105-3] a persona OUTSIDE the canonical path is still found ───────────
FIX="$TEST_TEMP_DIR/plugins"
mkdir -p "$FIX/agent/odd-place"
cat > "$FIX/agent/odd-place/manifest.yaml" <<'YAML'
id: oddball
name: Oddball
kind: persona
version: 0.1.0
persona:
  role: a tester
  perspective: Looks where nobody expects.
YAML
discovery_cache_flush
set +e
mf="$(find_persona oddball "$FIX")"; rc=$?
set -e
assert_eq "[#2105-3] non-canonical persona resolves via the walk" "0" "$rc"
assert_contains "[#2105-3] path points at the odd-place manifest" "$mf" "agent/odd-place/manifest.yaml"

# ─── [#2105-4] a disabled persona at the canonical path is NOT resolved ──────
export ZBUILD_DISABLED_FILE="$TEST_TEMP_DIR/disabled"
printf 'security\n' > "$ZBUILD_DISABLED_FILE"
discovery_cache_flush
set +e
find_persona security "$PROOT" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[#2105-4] a disabled persona is absent even at the canonical path" "1" "$rc"
rm -f "$ZBUILD_DISABLED_FILE"; unset ZBUILD_DISABLED_FILE
discovery_cache_flush

# ─── [#2105-5] a direct consumer fills the memo in the caller's shell ────────
: > "$WALKS"
discovery_cache_flush
find_plugin_for_role "orchestrator-backend" "local" >/dev/null 2>&1 || true
assert_eq "[#2105-5] find_plugin_for_role performed 1 walk" "1" "$(_walks)"
assert_eq "[#2105-5] the memo is populated in the calling shell afterwards" "1" "${#_ZBUILD_DISCOVERY_CACHE[@]}"
find_plugin_for_role "orchestrator-backend" "local" >/dev/null 2>&1 || true
assert_eq "[#2105-5] the second call is a memo hit (still 1 walk)" "1" "$(_walks)"

# ─── [#2105-6] sourcing runner.sh warms the memo in the sourcing shell ───────
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_MEMORY_BACKEND=file
n="$(bash -c "
    source '$REPO_ROOT/core/pipeline/runner.sh' >/dev/null 2>&1
    printf '%s' \"\${#_ZBUILD_DISCOVERY_CACHE[@]}\"
" 2>/dev/null || printf 'ERR')"
assert_eq "[#2105-6] after sourcing runner.sh the discovery memo is populated in that shell" "1" "$n"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
