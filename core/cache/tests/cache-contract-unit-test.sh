#!/usr/bin/env bash
# Tests: core/cache/contract.sh — co-located unit tests (Wave 4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/cache/contract.sh — co-located unit tests"
setup_test_env "cache-contract-colocated"

export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_CACHE_BACKEND="local"
export ZBUILD_CACHE_DIR="$TEST_TEMP_DIR/cache-store"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_CACHE_DIR" "$TEST_TEMP_DIR/events"

# shellcheck source=../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"
# shellcheck source=../../../core/cache/contract.sh
source "$REPO_ROOT/core/cache/contract.sh"

# ── cache_pull miss → CACHE_MISS + exit 0 ────────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
set +e; pull_out="$(cache_pull "no-such-key" "$TEST_TEMP_DIR/miss-dest" 2>/dev/null)"; rc=$?; set -e
assert_eq "cache_pull miss → rc=0" "0" "$rc"
assert_eq "cache_pull miss → stdout CACHE_MISS" "CACHE_MISS" "$pull_out"

# ── cache_push → cache_pull hit ───────────────────────────────────────────────
SRC="$TEST_TEMP_DIR/push-src"; mkdir -p "$SRC"
printf 'hello-cache\n' > "$SRC/test.txt"
: > "$ZBUILD_EVENTS_JSONL"
cache_push "test-key-001" "$SRC" 2>/dev/null
set +e; hit_out="$(cache_pull "test-key-001" "$TEST_TEMP_DIR/hit-dest" 2>/dev/null)"; rc=$?; set -e
assert_eq "cache_pull hit → rc=0" "0" "$rc"
assert_eq "cache_pull hit → stdout CACHE_HIT" "CACHE_HIT" "$hit_out"
assert_eq "cache_pull hit → content matches" "hello-cache" "$(cat "$TEST_TEMP_DIR/hit-dest/test.txt")"

# ── cache_has_capability: local_filesystem → 0; distributed → 1 ──────────────
set +e; cache_has_capability "local_filesystem"; rc=$?; set -e
assert_eq "cache_has_capability local_filesystem → 0" "0" "$rc"
set +e; cache_has_capability "distributed"; rc=$?; set -e
assert_eq "cache_has_capability distributed → 1" "1" "$rc"

# ── cache_derive_key is deterministic ─────────────────────────────────────────
k1="$(cache_derive_key "github.com/org/repo" "main" "build")"
k2="$(cache_derive_key "github.com/org/repo" "main" "build")"
assert_eq "cache_derive_key is deterministic" "$k1" "$k2"

# ── cache_derive_key different branches → different keys ─────────────────────
k_main="$(cache_derive_key "r" "main" "build")"
k_dev="$(cache_derive_key "r" "dev" "build")"
if [[ "$k_main" != "$k_dev" ]]; then
    assert_pass "different branches → different keys"
else
    assert_fail "different branches → different keys" "keys are equal: $k_main"
fi

cleanup_test_env
print_test_results
