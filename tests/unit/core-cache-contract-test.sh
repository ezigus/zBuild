#!/usr/bin/env bash
# Tests: core/cache/contract.sh — cache backend contract layer (ADR-011)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/cache/contract.sh — cache backend contract + local backend"

setup_test_env "core-cache-contract"

# Isolation env vars
export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_CACHE_BACKEND="local"
export ZBUILD_CACHE_DIR="$TEST_TEMP_DIR/cache-store"
mkdir -p "$ZBUILD_CACHE_DIR"

# Source chain
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"
# shellcheck source=../../core/cache/contract.sh
source "$REPO_ROOT/core/cache/contract.sh"

# ─── Test 1: cache_has_capability: local_filesystem → exit 0 ─────────────────
print_test_section "1. cache_has_capability: local_filesystem → exit 0"
set +e
cache_has_capability "local_filesystem"
rc=$?
set -e
assert_exit_code "cache_has_capability local_filesystem exits 0" "0" "$rc"

# ─── Test 2: cache_has_capability: distributed → exit 1 ──────────────────────
print_test_section "2. cache_has_capability: distributed → exit 1"
set +e
cache_has_capability "distributed"
rc=$?
set -e
assert_exit_code "cache_has_capability distributed exits 1" "1" "$rc"

# ─── Test 3: cache_pull miss → exit 0, stdout == CACHE_MISS ──────────────────
print_test_section "3. cache_pull miss → exit 0, stdout CACHE_MISS"
DEST_DIR="$TEST_TEMP_DIR/pull-dest-miss"
set +e
pull_out="$(cache_pull "no-such-key-xyz123" "$DEST_DIR" 2>/dev/null)"
pull_rc=$?
set -e
assert_exit_code "cache_pull miss exits 0" "0" "$pull_rc"
assert_eq "cache_pull miss stdout is CACHE_MISS" "CACHE_MISS" "$pull_out"

# ─── Test 4: dest_dir exists after miss, is empty ────────────────────────────
print_test_section "4. dest_dir exists after miss, is empty"
if [[ -d "$DEST_DIR" ]]; then
    assert_pass "dest_dir created on miss"
else
    assert_fail "dest_dir created on miss" "directory not found: $DEST_DIR"
fi
file_count="$(find "$DEST_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
assert_eq "dest_dir is empty after miss" "0" "$file_count"

# ─── Test 5 & 6 & 7: cache_push then cache_pull → CACHE_HIT + content matches ─
print_test_section "5-7. cache_push then cache_pull → CACHE_HIT + content"
SRC_DIR="$TEST_TEMP_DIR/push-src"
mkdir -p "$SRC_DIR"
printf 'stage: build\nstatus: complete\n' > "$SRC_DIR/pipeline-state.yaml"
printf '{"event":"test","ts":1}\n{"event":"build","ts":2}\n' > "$SRC_DIR/events.jsonl"

cache_push "round-trip-key-001" "$SRC_DIR"

PULL_DIR="$TEST_TEMP_DIR/pull-dest-hit"
set +e
hit_out="$(cache_pull "round-trip-key-001" "$PULL_DIR" 2>/dev/null)"
hit_rc=$?
set -e
assert_exit_code "cache_pull hit exits 0" "0" "$hit_rc"
assert_eq "cache_pull hit stdout is CACHE_HIT" "CACHE_HIT" "$hit_out"

# Test 6: pipeline-state.yaml content matches
orig_state="$(cat "$SRC_DIR/pipeline-state.yaml")"
pulled_state="$(cat "$PULL_DIR/pipeline-state.yaml")"
assert_eq "pulled pipeline-state.yaml content matches original" "$orig_state" "$pulled_state"

# Test 7: events.jsonl content matches
orig_events="$(cat "$SRC_DIR/events.jsonl")"
pulled_events="$(cat "$PULL_DIR/events.jsonl")"
assert_eq "pulled events.jsonl content matches original" "$orig_events" "$pulled_events"

# ─── Test 8: Second cache_push overwrites (idempotent) ───────────────────────
print_test_section "8. Second cache_push overwrites (idempotent)"
printf 'stage: deploy\nstatus: complete\n' > "$SRC_DIR/pipeline-state.yaml"
cache_push "round-trip-key-001" "$SRC_DIR"

PULL_DIR2="$TEST_TEMP_DIR/pull-dest-hit2"
set +e
hit_out2="$(cache_pull "round-trip-key-001" "$PULL_DIR2" 2>/dev/null)"
hit_rc2=$?
set -e
assert_exit_code "second push then pull exits 0" "0" "$hit_rc2"
assert_eq "second push then pull is CACHE_HIT" "CACHE_HIT" "$hit_out2"
updated_state="$(cat "$PULL_DIR2/pipeline-state.yaml")"
assert_eq "second push overwrites: new content is present" "stage: deploy
status: complete" "$updated_state"

# ─── Test 9: cache_derive_key is deterministic ────────────────────────────────
print_test_section "9. cache_derive_key is deterministic"
key1="$(cache_derive_key "github.com/org/repo" "main" "build")"
key2="$(cache_derive_key "github.com/org/repo" "main" "build")"
assert_eq "cache_derive_key same inputs → same key" "$key1" "$key2"

# ─── Test 10: cache_derive_key output is non-empty ───────────────────────────
print_test_section "10. cache_derive_key output is non-empty"
key_out="$(cache_derive_key "github.com/org/repo" "main" "test")"
if [[ -n "$key_out" ]]; then
    assert_pass "cache_derive_key output is non-empty"
else
    assert_fail "cache_derive_key output is non-empty" "got empty string"
fi

# ─── Test 11: cache_derive_key output is filesystem-safe ─────────────────────
print_test_section "11. cache_derive_key output matches ^[A-Za-z0-9_.-]+"
key_safe="$(cache_derive_key "github.com/org/repo" "feature/my-branch" "build")"
if [[ "$key_safe" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    assert_pass "cache_derive_key output is filesystem-safe (no slashes or special chars)"
else
    assert_fail "cache_derive_key output is filesystem-safe" "unsafe key: $key_safe"
fi

# ─── Test 12: Different branches produce different keys ──────────────────────
print_test_section "12. Different branches → different keys"
key_main="$(cache_derive_key "github.com/org/repo" "main" "build")"
key_dev="$(cache_derive_key "github.com/org/repo" "develop" "build")"
if [[ "$key_main" != "$key_dev" ]]; then
    assert_pass "different branches produce different keys"
else
    assert_fail "different branches produce different keys" "keys are equal: $key_main"
fi

# ─── Test 13: Different slots produce different keys ─────────────────────────
print_test_section "13. Different slots → different keys"
key_build="$(cache_derive_key "github.com/org/repo" "main" "build")"
key_test="$(cache_derive_key "github.com/org/repo" "main" "test")"
if [[ "$key_build" != "$key_test" ]]; then
    assert_pass "different slots produce different keys"
else
    assert_fail "different slots produce different keys" "keys are equal: $key_build"
fi

# ─── Test 14: cache_push with non-existent src_dir → exits non-zero ──────────
print_test_section "14. cache_push with non-existent src_dir → exits non-zero"
set +e
push_err="$(cache_push "bad-key" "$TEST_TEMP_DIR/does-not-exist" 2>&1)"
push_rc=$?
set -e
if [[ $push_rc -ne 0 ]]; then
    assert_pass "cache_push with missing src exits non-zero (rc=$push_rc)"
else
    assert_fail "cache_push with missing src exits non-zero" "got rc=0"
fi
if [[ -n "$push_err" ]]; then
    assert_pass "cache_push with missing src produces diagnostic output"
else
    assert_fail "cache_push with missing src produces diagnostic output" "no stderr output"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
