#!/usr/bin/env bash
# Integration Tests: plugins/tool/cache-gh-actions/ — adversarial and correctness edge cases
# Covers: concurrent push race, pull-after-interrupted-push, unreadable src,
#         unwritable dest, RUNNER_TEMP env independence per-call.
# These tests spawn real subprocesses and exercise the filesystem layer.
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
        source "$REPO_ROOT/scripts/lib/helpers.sh"
        source "$REPO_ROOT/scripts/lib/test-helpers.sh"
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

# ─── Test 4-5: Pull after interrupted push → CACHE_MISS, not corrupt hit ──────
# Why it matters: if push writes directly to the final path (not via a tmp file
# + atomic rename), a kill mid-write leaves a partial tarball at the final
# location.  A subsequent pull must see CACHE_MISS, not extract corrupt data.
print_test_section "4-5. Pull after interrupted push: CACHE_MISS, no corrupt hit"

INTERRUPTED_KEY="interrupted-push-key-001"
INTERRUPTED_SRC="$TEST_TEMP_DIR/interrupted-src"
mkdir -p "$INTERRUPTED_SRC"
# Create a file large enough that the push is unlikely to complete before we kill it.
dd if=/dev/urandom bs=1024 count=512 2>/dev/null > "$INTERRUPTED_SRC/large-blob.bin" || \
    printf '%0512000d' 0 > "$INTERRUPTED_SRC/large-blob.bin"

# Start push in a subshell and kill it immediately after it launches.
(
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    source "$REPO_ROOT/scripts/lib/test-helpers.sh"
    # shellcheck disable=SC1090
    source "$PLUGIN_DIR/plugin.sh"
    export RUNNER_TEMP="$RUNNER_TEMP"
    cache_push "$INTERRUPTED_KEY" "$INTERRUPTED_SRC" 2>/dev/null || true
) &
INTERRUPTED_PID=$!
# Give the process a moment to start writing, then terminate it.
sleep 0.1
kill -KILL "$INTERRUPTED_PID" 2>/dev/null || true
wait "$INTERRUPTED_PID" 2>/dev/null || true

# Test 4: pull must not return CACHE_HIT on a partial write.
INTERRUPTED_PULL="$TEST_TEMP_DIR/interrupted-pull"
set +e
interrupted_out="$(cache_pull "$INTERRUPTED_KEY" "$INTERRUPTED_PULL" 2>/dev/null)"
interrupted_rc=$?
set -e

assert_exit_code "interrupted push: pull exits 0" "0" "$interrupted_rc"

# If the plugin uses atomic rename, the partial file lives in a tmp location
# and is never promoted — so the pull sees CACHE_MISS.
# If the plugin uses in-place writes, the partial file may appear but extracting
# it should fail → the plugin must treat extract failure as CACHE_MISS.
if [[ "$interrupted_out" == "CACHE_MISS" ]]; then
    assert_pass "interrupted push: pull returns CACHE_MISS (partial write not surfaced)"
elif [[ "$interrupted_out" == "CACHE_HIT" ]]; then
    # If the plugin claims a HIT, the pulled content must not be corrupt.
    # Verify the dest dir is non-empty and large-blob.bin is complete (512 KiB).
    if [[ -f "$INTERRUPTED_PULL/large-blob.bin" ]]; then
        blob_size="$(wc -c < "$INTERRUPTED_PULL/large-blob.bin" 2>/dev/null || echo 0)"
        if [[ "$blob_size" -eq 524288 ]]; then
            assert_pass "interrupted push: CACHE_HIT with complete content (512 KiB)"
        else
            assert_fail "interrupted push: CACHE_MISS or CACHE_HIT with complete content" \
                "CACHE_HIT returned but blob is $blob_size bytes (expected 524288) — CORRUPT"
        fi
    else
        assert_fail "interrupted push: CACHE_MISS or CACHE_HIT with complete content" \
            "CACHE_HIT returned but large-blob.bin is missing — CORRUPT"
    fi
else
    assert_fail "interrupted push: pull returns CACHE_MISS or CACHE_HIT" \
        "stdout was: $interrupted_out"
fi

# Test 5: no partial/tmp files left exposed under RUNNER_TEMP with the key's name
#         (tmp files should be cleaned up on failure)
_temp_leftover="$(find "$RUNNER_TEMP" \( -name "*.tmp" -o -name "*.partial" -o -name "*.tmp.*" \) 2>/dev/null)" || true
if grep -q . <<< "$_temp_leftover"; then
    assert_fail "interrupted push: no .tmp/.partial files left in RUNNER_TEMP" \
        "leftover temp files found; plugin did not clean up after kill"
else
    assert_pass "interrupted push: no .tmp/.partial files left in RUNNER_TEMP"
fi

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
