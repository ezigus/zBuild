#!/usr/bin/env bash
# Integration Tests: plugins/tool/cache-gh-actions/ — adversarial and correctness edge cases
# Covers: concurrent push race, pull-after-interrupted-push, unreadable src,
#         unwritable dest, RUNNER_TEMP env independence per-call.
# These tests exercise the filesystem layer; an interruption is faked, never raced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/tool/cache-gh-actions"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/cache-gh-actions — integration: adversarial edge cases"

setup_test_env "cache-gh-actions-integ"

# Simulate GitHub Actions runner environment
export RUNNER_TEMP="$TEST_TEMP_DIR/runner"
mkdir -p "$RUNNER_TEMP"

# Source the plugin under test.
# shellcheck disable=SC1090
source "$PLUGIN_DIR/plugin.sh"

# ─── Helper: invoke cache_push in an isolated subshell with plugin sourced ────
# This is necessary for concurrency tests so we don't share in-process state.
_subshell_push() {
    local key="$1"
    local src="$2"
    (
        # Each subshell gets a fresh source of the plugin
        # Not test-helpers.sh: its exit trap would kill the test's other
        # children (pkill -P $$), here the other push (#2497).
        source "$REPO_ROOT/scripts/lib/helpers.sh"
        # shellcheck disable=SC1090
        source "$PLUGIN_DIR/plugin.sh"
        export RUNNER_TEMP="$RUNNER_TEMP"
        cache_push "$key" "$src"
    )
}

# ─── Test 1-3: Concurrent push race — two parallel pushes, same key ───────────
# Why it matters: if the plugin writes a tarball in-place (not atomically),
# a concurrent push can leave a partial tarball that passes a pull as CACHE_HIT
# but delivers corrupt content.  Atomic write (tmp + rename) is the required
# discipline (mirroring core/state/atomic.sh).
print_test_section "1-3. Concurrent push race: same key, no corruption"

RACE_KEY="race-key-concurrent-001"
SRC_A="$TEST_TEMP_DIR/src-race-a"
SRC_B="$TEST_TEMP_DIR/src-race-b"
mkdir -p "$SRC_A" "$SRC_B"
printf 'writer-a-payload\n' > "$SRC_A/payload.txt"
printf 'writer-b-payload\n' > "$SRC_B/payload.txt"

# Launch two concurrent pushes in background subshells.
_subshell_push "$RACE_KEY" "$SRC_A" &
PID_A=$!
_subshell_push "$RACE_KEY" "$SRC_B" &
PID_B=$!

wait "$PID_A" 2>/dev/null || true
wait "$PID_B" 2>/dev/null || true

# Test 1: After both pushes complete, a pull must exit 0 with CACHE_HIT.
RACE_PULL="$TEST_TEMP_DIR/race-pull"
set +e
race_out="$(cache_pull "$RACE_KEY" "$RACE_PULL" 2>/dev/null)"
race_rc=$?
set -e

assert_exit_code "concurrent push: subsequent pull exits 0" "0" "$race_rc"
assert_eq "concurrent push: subsequent pull returns CACHE_HIT" "CACHE_HIT" "$race_out"

# Test 2: The pulled payload.txt must be one complete, non-empty file
#         (not a zero-byte artefact of a torn write).
if [[ -f "$RACE_PULL/payload.txt" ]]; then
    assert_pass "concurrent push: payload.txt present after pull"
else
    assert_fail "concurrent push: payload.txt present after pull" \
        "file missing: $RACE_PULL/payload.txt"
fi

payload_size="$(wc -c < "$RACE_PULL/payload.txt" 2>/dev/null || echo 0)"
if [[ "$payload_size" -gt 0 ]]; then
    assert_pass "concurrent push: payload.txt is non-empty (no torn write, rc=$race_rc)"
else
    assert_fail "concurrent push: payload.txt is non-empty (no torn write)" \
        "file is zero bytes — likely torn write or corrupt tarball"
fi

# Test 3: The content must be exactly one of the two valid payloads (last-write-wins).
pulled_payload="$(cat "$RACE_PULL/payload.txt" 2>/dev/null || true)"
if [[ "$pulled_payload" == "writer-a-payload" || "$pulled_payload" == "writer-b-payload" ]]; then
    assert_pass "concurrent push: content is one complete payload (last-write-wins: '$pulled_payload')"
else
    assert_fail "concurrent push: content is one complete payload" \
        "got corrupt/mixed content: '$pulled_payload'"
fi

# ─── Test 4-5: an interrupted push never becomes a cache entry (ADR-011) ─────
# Why it matters: a push writes into <key>.tmp.<pid> and renames it to <key>
# only when the copy is whole, so a pull never reads a partial copy. The
# interruption is faked rather than raced: a KILL timed against a ~35ms copy
# rarely lands, and when it does nothing can clean up after it (#2497).
print_test_section "4-5. Interrupted push: never a cache entry, never a corrupt hit"

INTERRUPTED_SRC="$TEST_TEMP_DIR/interrupted-src"
mkdir -p "$INTERRUPTED_SRC"
head -c 524288 /dev/urandom > "$INTERRUPTED_SRC/large-blob.bin"
_CACHE_ROOT="$RUNNER_TEMP/zbuild-cache"

# 4a. A copy that fails partway: the fake cp writes half the blob, then fails.
FAKE_BIN="$TEST_TEMP_DIR/fake-cp-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/cp" <<'EOF'
#!/usr/bin/env bash
src="${*: -2:1}"; dest="${*: -1}"
head -c 262144 "$src/large-blob.bin" > "$dest/large-blob.bin"
exit 1
EOF
chmod +x "$FAKE_BIN/cp"

set +e
half_err="$(PATH="$FAKE_BIN:$PATH" cache_push "interrupted-copy-key" "$INTERRUPTED_SRC" 2>&1 >/dev/null)"
half_rc=$?
set -e
assert_exit_code "copy fails partway: push exits 1" "1" "$half_rc"
assert_contains "copy fails partway: push says the copy failed" "$half_err" "copy failed"
# The cache root is the plugin's; if it moves, the find below would find nothing
# and pass, so its being there is asserted first (review on #2498).
if [[ -d "$_CACHE_ROOT" ]]; then
    assert_pass "copy fails partway: the cache root the checks look in exists"
else
    assert_fail "copy fails partway: the cache root the checks look in exists" "no $_CACHE_ROOT"
fi
half_left="$(find "$_CACHE_ROOT" -maxdepth 1 -name 'interrupted-copy-key*' 2>/dev/null)" || true
assert_eq "copy fails partway: no <key> or <key>.tmp.* folder is left" "" "$half_left"
set +e
half_pull="$(cache_pull "interrupted-copy-key" "$TEST_TEMP_DIR/interrupted-copy-pull" 2>/dev/null)"
set -e
assert_eq "copy fails partway: a later pull returns CACHE_MISS" "CACHE_MISS" "$half_pull"

# 4b. A push that died partway, no earlier entry: only its tmp folder is left.
mkdir -p "$_CACHE_ROOT/interrupted-dead-key.tmp.99999"
head -c 262144 "$INTERRUPTED_SRC/large-blob.bin" > "$_CACHE_ROOT/interrupted-dead-key.tmp.99999/large-blob.bin"
set +e
dead_pull="$(cache_pull "interrupted-dead-key" "$TEST_TEMP_DIR/interrupted-dead-pull" 2>/dev/null)"
set -e
assert_eq "push died partway: pull returns CACHE_MISS" "CACHE_MISS" "$dead_pull"
if [[ -e "$TEST_TEMP_DIR/interrupted-dead-pull/large-blob.bin" ]]; then
    assert_fail "push died partway: pull writes no blob" "the partial blob was pulled"
else
    assert_pass "push died partway: pull writes no blob"
fi

# 5. A push that died partway beside a good entry: the good entry is pulled whole.
cache_push "interrupted-good-key" "$INTERRUPTED_SRC" >/dev/null 2>&1 || true
mkdir -p "$_CACHE_ROOT/interrupted-good-key.tmp.99999"
head -c 262144 "$INTERRUPTED_SRC/large-blob.bin" > "$_CACHE_ROOT/interrupted-good-key.tmp.99999/large-blob.bin"
set +e
good_pull="$(cache_pull "interrupted-good-key" "$TEST_TEMP_DIR/interrupted-good-pull" 2>/dev/null)"
set -e
assert_eq "push died beside a good entry: pull returns CACHE_HIT" "CACHE_HIT" "$good_pull"
good_size="$(wc -c < "$TEST_TEMP_DIR/interrupted-good-pull/large-blob.bin" 2>/dev/null | tr -d ' ')" || good_size=0
assert_eq "push died beside a good entry: the whole blob is pulled (524288 bytes)" "524288" "$good_size"

# ─── Test 6: cache_push with unreadable src_dir → rc=1 + stderr diagnostic ────
# Why it matters: a world-unreadable directory must produce a clear error to
# stderr (rc=1), not a silent zero exit or a tarball of zero bytes.
print_test_section "6. cache_push unreadable src_dir: exits rc=1 with diagnostic"

# Skip this test when running as root (root bypasses read permissions).
if [[ "$(id -u)" -eq 0 ]]; then
    assert_pass "cache_push unreadable src_dir: SKIPPED (running as root)"
else
    UNREADABLE_SRC="$TEST_TEMP_DIR/unreadable-src"
    mkdir -p "$UNREADABLE_SRC"
    printf 'secret data\n' > "$UNREADABLE_SRC/secret.txt"
    chmod 000 "$UNREADABLE_SRC"

    set +e
    unreadable_out="$(cache_push "key-unreadable-src" "$UNREADABLE_SRC" 2>&1)"
    unreadable_rc=$?
    set -e

    # Restore permissions so cleanup_test_env can remove the directory.
    chmod 755 "$UNREADABLE_SRC" 2>/dev/null || true

    assert_exit_code "unreadable src_dir: cache_push exits 1" "1" "$unreadable_rc"

    if grep -qiE "(permission|denied|cannot|unreadable|error|failed)" <<< "$unreadable_out"; then
        assert_pass "unreadable src_dir: stderr contains diagnostic keyword"
    else
        assert_fail "unreadable src_dir: stderr contains diagnostic keyword" \
            "stderr was: $unreadable_out"
    fi

    # Verify nothing was written to the cache for this key.
    UNREADABLE_PULL="$TEST_TEMP_DIR/unreadable-pull"
    set +e
    unr_pull_out="$(cache_pull "key-unreadable-src" "$UNREADABLE_PULL" 2>/dev/null)"
    set -e
    assert_eq "unreadable src_dir: no cache entry written (CACHE_MISS after failed push)" \
        "CACHE_MISS" "$unr_pull_out"
fi

# ─── Test 7: cache_pull with unwritable dest_dir → rc=1 + stderr diagnostic ───
# Why it matters: if the dest directory exists but is not writable, the plugin
# must fail cleanly (rc=1) and surface the error rather than silently returning
# CACHE_HIT with an empty directory.
print_test_section "7. cache_pull unwritable dest_dir: exits rc=1 with diagnostic"

if [[ "$(id -u)" -eq 0 ]]; then
    assert_pass "cache_pull unwritable dest_dir: SKIPPED (running as root)"
else
    # First push a valid entry so there is something to pull.
    WRITABLE_SRC="$TEST_TEMP_DIR/writable-src"
    mkdir -p "$WRITABLE_SRC"
    printf 'writable src content\n' > "$WRITABLE_SRC/data.txt"
    cache_push "key-writable-001" "$WRITABLE_SRC" >/dev/null 2>&1

    # Create the dest dir, lock it, then attempt the pull.
    LOCKED_DEST="$TEST_TEMP_DIR/locked-dest"
    mkdir -p "$LOCKED_DEST"
    chmod 555 "$LOCKED_DEST"  # traversable+readable but not writable

    set +e
    locked_out="$(cache_pull "key-writable-001" "$LOCKED_DEST" 2>&1)"
    locked_rc=$?
    set -e

    # Restore permissions for cleanup.
    chmod 755 "$LOCKED_DEST" 2>/dev/null || true

    assert_exit_code "unwritable dest_dir: cache_pull exits 1" "1" "$locked_rc"

    if grep -qiE "(permission|denied|cannot|write|error|failed)" <<< "$locked_out"; then
        assert_pass "unwritable dest_dir: stderr contains diagnostic keyword"
    else
        assert_fail "unwritable dest_dir: stderr contains diagnostic keyword" \
            "stderr was: $locked_out"
    fi

    # The dest directory must not have gained any files (pull did not partially extract).
    locked_count="$(find "$LOCKED_DEST" -mindepth 1 | wc -l | tr -d ' ')"
    if [[ "$locked_count" -eq 0 ]]; then
        assert_pass "unwritable dest_dir: no partial extraction occurred"
    else
        assert_fail "unwritable dest_dir: no partial extraction occurred" \
            "found $locked_count file(s) in locked dest — partial write detected"
    fi
fi

# ─── Test 8-9: RUNNER_TEMP independence — each call checks env independently ──
# Why it matters: the contract says every invocation must independently validate
# RUNNER_TEMP.  A cached/stale reference set during a previous call that then
# becomes invalid must not silently succeed on the next call.
print_test_section "8-9. RUNNER_TEMP independence per call"

# Test 8: pull with valid RUNNER_TEMP succeeds first.
INDEP_SRC="$TEST_TEMP_DIR/indep-src"
mkdir -p "$INDEP_SRC"
printf 'independence test\n' > "$INDEP_SRC/data.txt"
export RUNNER_TEMP="$TEST_TEMP_DIR/runner"
mkdir -p "$RUNNER_TEMP"
cache_push "indep-key-001" "$INDEP_SRC" >/dev/null 2>&1

INDEP_PULL="$TEST_TEMP_DIR/indep-pull"
set +e
indep_out="$(cache_pull "indep-key-001" "$INDEP_PULL" 2>/dev/null)"
indep_rc=$?
set -e
assert_exit_code "RUNNER_TEMP independence: pull with valid RUNNER_TEMP exits 0" "0" "$indep_rc"
assert_eq "RUNNER_TEMP independence: pull with valid RUNNER_TEMP returns CACHE_HIT" \
    "CACHE_HIT" "$indep_out"

# Test 9: now unset RUNNER_TEMP; second call must degrade gracefully (CACHE_MISS rc=0),
# not silently reuse a previously validated path.
SAVED_RT="$RUNNER_TEMP"
unset RUNNER_TEMP

INDEP_PULL2="$TEST_TEMP_DIR/indep-pull2"
set +e
indep2_out="$(cache_pull "indep-key-001" "$INDEP_PULL2" 2>/dev/null)"
indep2_rc=$?
set -e

assert_exit_code "RUNNER_TEMP independence: second call exits 0 (graceful)" "0" "$indep2_rc"
assert_eq "RUNNER_TEMP independence: second call returns CACHE_MISS (not CACHE_HIT)" \
    "CACHE_MISS" "$indep2_out"

export RUNNER_TEMP="$SAVED_RT"
mkdir -p "$RUNNER_TEMP"

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
