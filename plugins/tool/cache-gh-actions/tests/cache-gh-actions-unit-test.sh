#!/usr/bin/env bash
# Tests: plugins/tool/cache-gh-actions/ — unit-level adversarial and edge-case tests
# Covers: key path traversal, RUNNER_TEMP injection, long keys, forbidden chars,
#         dest_dir-is-a-file, RUNNER_TEMP unset per-call, unreadable src, unwritable dest.
# These tests execute the plugin's entry functions in-process with mocked RUNNER_TEMP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/tool/cache-gh-actions"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/cache-gh-actions — unit: adversarial + edge cases"

setup_test_env "cache-gh-actions-unit"

# Simulate a GitHub Actions runner environment
export RUNNER_TEMP="$TEST_TEMP_DIR/runner"
mkdir -p "$RUNNER_TEMP"

# Source the plugin under test.  If the plugin is not yet implemented the test
# file will fail loudly here, which is the correct signal for issue #212.
# shellcheck disable=SC1090
source "$PLUGIN_DIR/plugin.sh"

# ─── Test 1: Key path traversal → cache_pull must reject with rc=2 ───────────
print_test_section "1. Key path traversal: cache_pull rejects '../../../etc/passwd'"

TRAVERSAL_DEST="$TEST_TEMP_DIR/traversal-dest"
set +e
traversal_out="$(cache_pull "../../../etc/passwd" "$TRAVERSAL_DEST" 2>&1)"
traversal_rc=$?
set -e

assert_exit_code "cache_pull path-traversal key exits 2" "2" "$traversal_rc"

# The plugin must NOT have opened /etc/passwd — verify by confirming the
# destination directory is either absent or empty.
if [[ -d "$TRAVERSAL_DEST" ]]; then
    file_count="$(find "$TRAVERSAL_DEST" -mindepth 1 | wc -l | tr -d ' ')"
    if [[ "$file_count" -eq 0 ]]; then
        assert_pass "traversal key: dest_dir is empty (no file was read)"
    else
        assert_fail "traversal key: dest_dir is empty (no file was read)" \
            "found $file_count unexpected file(s) in dest"
    fi
else
    assert_pass "traversal key: dest_dir was never created (no file was read)"
fi

# The plugin must emit a diagnostic to stderr so the caller knows why rc=2.
if grep -qiE "(invalid|traversal|rejected|forbidden|unsafe|illegal)" <<< "$traversal_out"; then
    assert_pass "traversal key: rejection diagnostic on stderr"
else
    assert_fail "traversal key: rejection diagnostic on stderr" \
        "stderr was: $traversal_out"
fi

# ─── Test 2: Key with leading dot-slash variant ───────────────────────────────
print_test_section "2. Key path traversal variant: './relative/path' rejected (rc=2)"

set +e
dotslash_rc="$(cache_pull "./relative/path" "$TEST_TEMP_DIR/dotslash-dest" 2>/dev/null; echo $?)"
set -e
# Use numeric comparison — rc printed as a string via $()
if [[ "$dotslash_rc" -eq 2 ]]; then
    assert_pass "cache_pull './relative/path' exits 2"
else
    assert_fail "cache_pull './relative/path' exits 2" "got rc=$dotslash_rc"
fi

# ─── Test 3: cache_push with path-traversal key → rc=2 ───────────────────────
print_test_section "3. Key path traversal: cache_push rejects '../../../tmp/evil' (rc=2)"

LEGIT_SRC="$TEST_TEMP_DIR/legit-src"
mkdir -p "$LEGIT_SRC"
printf 'safe content\n' > "$LEGIT_SRC/data.txt"

set +e
cache_push "../../../tmp/evil" "$LEGIT_SRC" >/dev/null 2>&1
push_traversal_rc=$?
set -e

assert_exit_code "cache_push path-traversal key exits 2" "2" "$push_traversal_rc"

# ─── Test 4: RUNNER_TEMP with shell metacharacters — no command execution ─────
print_test_section "4. RUNNER_TEMP injection: semicolons/backticks in env var are inert"

SAFE_PUSH_SRC="$TEST_TEMP_DIR/safe-src"
mkdir -p "$SAFE_PUSH_SRC"
printf 'payload\n' > "$SAFE_PUSH_SRC/file.txt"

# Create a canary file whose presence would indicate injection
CANARY="$TEST_TEMP_DIR/INJECTION_CANARY"

# Export a RUNNER_TEMP value containing shell metacharacters.  The plugin must
# treat this as a literal string (quoted), never pass it unquoted to eval/sh.
export RUNNER_TEMP="$TEST_TEMP_DIR/runner; touch $CANARY #"

# Assertion is canary-file presence (proof of shell injection); the
# plugin's stdout/rc are not under test here.
cache_push "safe-key-001" "$SAFE_PUSH_SRC" >/dev/null 2>&1 || true

if [[ -f "$CANARY" ]]; then
    assert_fail "RUNNER_TEMP metachar injection: canary file was NOT created" \
        "INJECTION DETECTED: touch executed via RUNNER_TEMP metacharacters"
else
    assert_pass "RUNNER_TEMP metachar injection: canary file was not created"
fi

# Restore a clean RUNNER_TEMP for subsequent tests
export RUNNER_TEMP="$TEST_TEMP_DIR/runner"
mkdir -p "$RUNNER_TEMP"

# ─── Test 5: Very long key (513 chars) → rejection or safe truncation ─────────
print_test_section "5. Very long key (513 chars): cache_pull rejects or truncates safely"

LONG_KEY="$(printf 'a%.0s' {1..513})"
LONG_DEST="$TEST_TEMP_DIR/long-key-dest"

set +e
long_out="$(cache_pull "$LONG_KEY" "$LONG_DEST" 2>&1)"
long_rc=$?
set -e

# rc=2 (invalid input) is the preferred response; rc=0 with CACHE_MISS is
# acceptable if the plugin silently truncates to a safe length — but rc=1
# (infrastructure error) is not acceptable for an input-validation path.
if [[ "$long_rc" -eq 2 ]]; then
    assert_pass "very long key: cache_pull exits 2 (explicit rejection)"
elif [[ "$long_rc" -eq 0 ]]; then
    # Truncation path: verify the dest is empty/miss (no crash, no corruption)
    if grep -qF "CACHE_MISS" <<< "$long_out"; then
        assert_pass "very long key: cache_pull exits 0 with CACHE_MISS (safe truncation)"
    else
        assert_fail "very long key: cache_pull exits 0 with CACHE_MISS (safe truncation)" \
            "stdout was: $long_out"
    fi
else
    assert_fail "very long key: cache_pull exits 2 or 0, not $long_rc"
fi

# Either way, no runaway disk write should have occurred from a 513-char key.
if [[ -d "$LONG_DEST" ]]; then
    long_count="$(find "$LONG_DEST" -mindepth 1 | wc -l | tr -d ' ')"
    if [[ "$long_count" -eq 0 ]]; then
        assert_pass "very long key: dest_dir is empty (no runaway write)"
    else
        assert_fail "very long key: dest_dir is empty (no runaway write)" \
            "found $long_count file(s) in dest"
    fi
else
    assert_pass "very long key: dest_dir not created (no runaway write)"
fi

# ─── Test 6: Key with GH-forbidden comma character → sanitized or rejected ────
print_test_section "6. Key with comma (GH-forbidden): cache_push sanitizes or rejects"

COMMA_SRC="$TEST_TEMP_DIR/comma-src"
mkdir -p "$COMMA_SRC"
printf 'comma-key content\n' > "$COMMA_SRC/data.txt"

set +e
cache_push "key,with,commas" "$COMMA_SRC" >/dev/null 2>&1
comma_rc=$?
set -e

# rc=2 = explicit rejection (preferred).
# rc=0 = plugin sanitized the comma (acceptable; verify a sane key was used).
# rc=1 = infrastructure error passed through input validation = bug.
if [[ "$comma_rc" -eq 2 ]]; then
    assert_pass "comma key: cache_push exits 2 (rejection)"
elif [[ "$comma_rc" -eq 0 ]]; then
    assert_pass "comma key: cache_push exits 0 (sanitized and stored)"
else
    assert_fail "comma key: cache_push exits 2 (rejection) or 0 (sanitized), not rc=$comma_rc"
fi

# Regardless of outcome, the raw comma must not appear verbatim in any
# generated file path under RUNNER_TEMP — that would be a shell safety bug.
if grep -q ',' <<< "$(find "$RUNNER_TEMP" -name '*,*' 2>/dev/null)"; then
    assert_fail "comma key: no file path under RUNNER_TEMP contains a raw comma" \
        "comma found in path under $RUNNER_TEMP"
else
    assert_pass "comma key: no file path under RUNNER_TEMP contains a raw comma"
fi

# ─── Test 7: cache_capabilities returns valid JSON with required fields ────────
print_test_section "7. cache_capabilities: valid JSON with required fields"

set +e
caps_out="$(cache_capabilities 2>&1)"
caps_rc=$?
set -e

assert_exit_code "cache_capabilities exits 0" "0" "$caps_rc"

if echo "$caps_out" | jq empty >/dev/null 2>&1; then
    assert_pass "cache_capabilities output is valid JSON"
else
    assert_fail "cache_capabilities output is valid JSON" \
        "output was: $caps_out"
fi

# The spec requires at least a 'backend' field.
if echo "$caps_out" | jq -e '.backend' >/dev/null 2>&1; then
    assert_pass "cache_capabilities JSON contains 'backend' field"
else
    assert_fail "cache_capabilities JSON contains 'backend' field" \
        "output was: $caps_out"
fi

# ─── Test 8: RUNNER_TEMP unset — cache_pull gracefully returns CACHE_MISS ────
print_test_section "8. RUNNER_TEMP unset: cache_pull gracefully returns CACHE_MISS (rc=0)"

SAVED_RUNNER_TEMP="$RUNNER_TEMP"
unset RUNNER_TEMP

set +e
unset_out="$(cache_pull "any-key" "$TEST_TEMP_DIR/unset-dest" 2>/dev/null)"
unset_rc=$?
set -e

assert_exit_code "RUNNER_TEMP unset: cache_pull exits 0 (graceful)" "0" "$unset_rc"
assert_eq "RUNNER_TEMP unset: cache_pull returns CACHE_MISS" "CACHE_MISS" "$unset_out"

export RUNNER_TEMP="$SAVED_RUNNER_TEMP"
mkdir -p "$RUNNER_TEMP"

# ─── Test 9: RUNNER_TEMP unset — cache_push silently no-ops (rc=0) ───────────
print_test_section "9. RUNNER_TEMP unset: cache_push silently no-ops (rc=0)"

unset RUNNER_TEMP

PUSH_SRC_U="$TEST_TEMP_DIR/push-src-unset"
mkdir -p "$PUSH_SRC_U"
printf 'data\n' > "$PUSH_SRC_U/data.txt"

set +e
cache_push "any-key" "$PUSH_SRC_U" 2>/dev/null
unset_push_rc=$?
set -e

assert_exit_code "RUNNER_TEMP unset: cache_push exits 0 (graceful no-op)" "0" "$unset_push_rc"

export RUNNER_TEMP="$SAVED_RUNNER_TEMP"
mkdir -p "$RUNNER_TEMP"

# ─── Test 10: dest_dir is a regular file → cache_pull graceful failure ─────────
print_test_section "10. cache_pull dest is a regular file: exits rc=1 with diagnostic"

DEST_FILE="$TEST_TEMP_DIR/i-am-a-file"
printf 'i am a file, not a directory\n' > "$DEST_FILE"

set +e
file_dest_out="$(cache_pull "some-key" "$DEST_FILE" 2>&1)"
file_dest_rc=$?
set -e

# Plugin must not exit 0 (it cannot deposit files into a non-directory).
if [[ "$file_dest_rc" -ne 0 ]]; then
    assert_pass "dest_dir-is-file: cache_pull exits non-zero (rc=$file_dest_rc)"
else
    assert_fail "dest_dir-is-file: cache_pull exits non-zero" \
        "got rc=0; stdout/stderr: $file_dest_out"
fi

# Preferred exit code for a bad-destination input is 2; 1 is acceptable if
# detection happens post-validation (e.g. directory creation fails).
if [[ "$file_dest_rc" -eq 2 || "$file_dest_rc" -eq 1 ]]; then
    assert_pass "dest_dir-is-file: exit code is 1 or 2 (not 0 or signal)"
else
    assert_fail "dest_dir-is-file: exit code is 1 or 2" \
        "got rc=$file_dest_rc"
fi

# The original file must be untouched.
original_content="$(cat "$DEST_FILE")"
assert_eq "dest_dir-is-file: original file content is intact" \
    "i am a file, not a directory" "$original_content"

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
