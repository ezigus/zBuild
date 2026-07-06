#!/usr/bin/env bash
# Integration Tests: core/cache — local backend full round-trips (ADR-011)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/cache/local — integration: full round-trips and collision safety"

setup_test_env "core-cache-local"

export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_CACHE_BACKEND="local"
export ZBUILD_CACHE_DIR="$TEST_TEMP_DIR/cache-store"
mkdir -p "$ZBUILD_CACHE_DIR"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"
# shellcheck source=../../core/cache/contract.sh
source "$REPO_ROOT/core/cache/contract.sh"

# ─── Tests 1-3: Full round-trip with nested artifacts dir ────────────────────
print_test_section "1-3. Full round-trip: nested artifacts, content integrity"

SRC_DIR="$TEST_TEMP_DIR/src-nested"
mkdir -p "$SRC_DIR/artifacts/reports"
printf 'stage: validate\nstatus: ok\n' > "$SRC_DIR/pipeline-state.yaml"
printf '{"event":"start"}\n' > "$SRC_DIR/events.jsonl"
printf 'PASS: 42\nFAIL: 0\n' > "$SRC_DIR/artifacts/reports/summary.txt"
printf 'build-output-data\n' > "$SRC_DIR/artifacts/build.bin"

KEY="nested-round-trip-001"
cache_push "$KEY" "$SRC_DIR"

PULL_DIR="$TEST_TEMP_DIR/dst-nested"
set +e
pull_out="$(cache_pull "$KEY" "$PULL_DIR" 2>/dev/null)"
pull_rc=$?
set -e

assert_exit_code "nested round-trip: cache_pull exits 0" "0" "$pull_rc"
assert_eq "nested round-trip: stdout is CACHE_HIT" "CACHE_HIT" "$pull_out"

# Test 1: diff -rq shows no differences
diff_out="$(diff -rq "$SRC_DIR" "$PULL_DIR" 2>&1 || true)"
if [[ -z "$diff_out" ]]; then
    assert_pass "full round-trip: diff -rq shows no differences"
else
    assert_fail "full round-trip: diff -rq shows no differences" "diff output: $diff_out"
fi

# Test 2: nested artifact file present after pull
if [[ -f "$PULL_DIR/artifacts/reports/summary.txt" ]]; then
    assert_pass "nested artifact file present after pull"
else
    assert_fail "nested artifact file present after pull" "missing: $PULL_DIR/artifacts/reports/summary.txt"
fi

# Test 3: nested artifact content matches
orig_summary="$(cat "$SRC_DIR/artifacts/reports/summary.txt")"
pulled_summary="$(cat "$PULL_DIR/artifacts/reports/summary.txt")"
assert_eq "nested artifact content matches original" "$orig_summary" "$pulled_summary"

# ─── Tests 4-6: cache_pull miss behavior ─────────────────────────────────────
print_test_section "4-6. cache_pull miss: dest created, empty, exit 0, CACHE_MISS"

MISS_DEST="$TEST_TEMP_DIR/miss-dest"
set +e
miss_out="$(cache_pull "key-that-does-not-exist-abc987" "$MISS_DEST" 2>/dev/null)"
miss_rc=$?
set -e

# Test 4a: dest_dir created on miss
if [[ -d "$MISS_DEST" ]]; then
    assert_pass "cache_pull miss: dest_dir created"
else
    assert_fail "cache_pull miss: dest_dir created" "directory not found: $MISS_DEST"
fi

# Test 4b: dest_dir is empty
miss_count="$(find "$MISS_DEST" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
assert_eq "cache_pull miss: dest_dir is empty" "0" "$miss_count"

# Test 4c: exit 0 on miss
assert_exit_code "cache_pull miss: exits 0" "0" "$miss_rc"

# Test 4d: stdout is CACHE_MISS
assert_eq "cache_pull miss: stdout is CACHE_MISS" "CACHE_MISS" "$miss_out"

# ─── Tests 5-6: cache_push with missing src → non-zero + diagnostic ──────────
print_test_section "5-6. cache_push missing src: exits non-zero + diagnostic"

set +e
bad_push_err="$(cache_push "some-key" "$TEST_TEMP_DIR/nonexistent-src-dir" 2>&1)"
bad_push_rc=$?
set -e

# Test 5: exits non-zero
if [[ $bad_push_rc -ne 0 ]]; then
    assert_pass "cache_push missing src: exits non-zero (rc=$bad_push_rc)"
else
    assert_fail "cache_push missing src: exits non-zero" "got rc=0"
fi

# Test 6: error output contains a diagnostic keyword
if grep -qiE "(not found|does not exist|no such|missing|error)" <<< "$bad_push_err"; then
    assert_pass "cache_push missing src: error output contains diagnostic keyword"
else
    assert_fail "cache_push missing src: error output contains diagnostic keyword" \
        "stderr was: $bad_push_err"
fi

# ─── Tests 7-8: Slash-in-branch sanitization ─────────────────────────────────
print_test_section "7-8. Slash-in-branch sanitization for cache_derive_key"

# Test 7: key with slash branch has no slash in output
slash_key="$(cache_derive_key "github.com/org/repo" "feat/my-feature/sub" "build")"
if [[ "$slash_key" != *"/"* ]]; then
    assert_pass "cache_derive_key with slash branch: no slash in output"
else
    assert_fail "cache_derive_key with slash branch: no slash in output" "key=$slash_key"
fi

# Test 8: slash-derived key works for push/pull
SLASH_SRC="$TEST_TEMP_DIR/slash-src"
mkdir -p "$SLASH_SRC"
printf 'branch-feature-data\n' > "$SLASH_SRC/data.txt"

cache_push "$slash_key" "$SLASH_SRC"

SLASH_PULL="$TEST_TEMP_DIR/slash-pull"
set +e
slash_out="$(cache_pull "$slash_key" "$SLASH_PULL" 2>/dev/null)"
slash_rc=$?
set -e
assert_exit_code "slash-derived key: cache_pull exits 0" "0" "$slash_rc"
assert_eq "slash-derived key: cache_pull returns CACHE_HIT" "CACHE_HIT" "$slash_out"

# ─── Tests 9-10: Key collision safety ────────────────────────────────────────
print_test_section "9-10. Key collision safety: different slots don't collide"

KEY_A="$(cache_derive_key "github.com/org/repo" "main" "build")"
KEY_B="$(cache_derive_key "github.com/org/repo" "main" "test")"

# Push distinct content under each key
SRC_A="$TEST_TEMP_DIR/src-a"
SRC_B="$TEST_TEMP_DIR/src-b"
mkdir -p "$SRC_A" "$SRC_B"
printf 'content-from-build-slot\n' > "$SRC_A/slot.txt"
printf 'content-from-test-slot\n' > "$SRC_B/slot.txt"

cache_push "$KEY_A" "$SRC_A"
cache_push "$KEY_B" "$SRC_B"

PULL_A="$TEST_TEMP_DIR/pull-a"
PULL_B="$TEST_TEMP_DIR/pull-b"
cache_pull "$KEY_A" "$PULL_A" >/dev/null 2>&1
cache_pull "$KEY_B" "$PULL_B" >/dev/null 2>&1

# Test 9: KEY_A slot returns A content
a_content="$(cat "$PULL_A/slot.txt")"
assert_eq "KEY_A slot returns A content" "content-from-build-slot" "$a_content"

b_content="$(cat "$PULL_B/slot.txt")"
assert_eq "KEY_B slot returns B content" "content-from-test-slot" "$b_content"

# Test 10: keys for different slots are different strings
if [[ "$KEY_A" != "$KEY_B" ]]; then
    assert_pass "keys for different slots (build vs test) are different strings"
else
    assert_fail "keys for different slots (build vs test) are different strings" \
        "both keys are: $KEY_A"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
