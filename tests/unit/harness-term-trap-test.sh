#!/usr/bin/env bash
# Unit: #1611 — test-harness TERM/INT trap re-raise fix
# SPEC-1: SIGTERM delivered mid-test exits with rc=143, no bogus assertion failures
# SPEC-2: SIGTERM triggers cleanup of AUTO_TEST_TEMP_DIR before exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-harness TERM trap: rc=143, no bogus failures, temp cleanup (#1611)"

# ─── Witness dir (reaped by this script's EXIT trap via _test_cleanup_hook) ──
WITNESS_DIR="$AUTO_TEST_TEMP_DIR/witness"
mkdir -p "$WITNESS_DIR"

# ─── SPEC-1 + SPEC-2: fork interruptible child, deliver SIGTERM ──────────────
print_test_section "SPEC-1/SPEC-2: fork child that installs harness, interrupt with SIGTERM"

CHILD_OUTPUT="$WITNESS_DIR/child-output.txt"
CHILD_TEMPDIR_FILE="$WITNESS_DIR/child-tempdir.txt"

# The child sources test-helpers (installs the fixed TERM trap), records
# AUTO_TEST_TEMP_DIR, emits one passing assert, then loops so TERM can fire
# mid-test. $0 is 'bash' (not *-test.sh) so the re-entrancy guard is silent.
bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/scripts/lib/test-helpers.sh'
    printf '%s' \"\$AUTO_TEST_TEMP_DIR\" > '$CHILD_TEMPDIR_FILE'
    assert_pass 'T0: pre-signal assertion (expected in output)'
    while true; do sleep 0.05; done
" >"$CHILD_OUTPUT" 2>&1 &
CHILD_PID=$!

# Poll until child has written its temp dir path (up to 5 s)
_setup_ok=0
for (( _i = 0; _i < 100; _i++ )); do
    if [[ -f "$CHILD_TEMPDIR_FILE" && -s "$CHILD_TEMPDIR_FILE" ]]; then
        _setup_ok=1
        break
    fi
    sleep 0.05
done

if [[ $_setup_ok -eq 0 ]]; then
    kill "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null && true || true
    assert_fail "[SPEC-1] child setup completed before timeout" "timed out"
    assert_fail "[SPEC-2] child setup completed before timeout" "timed out"
    print_test_results
    exit $((FAIL > 0))
fi

# Deliver SIGTERM to the child bash process
kill -TERM "$CHILD_PID" 2>/dev/null || true

# Capture child exit status (128+15=143 expected).
# Use && ... || $? pattern: set -e ignores failure in the left side of ||.
wait "$CHILD_PID" 2>/dev/null && CHILD_RC=0 || CHILD_RC=$?

# SPEC-1a: exit code must be 143
assert_eq "[SPEC-1] SIGTERM yields exit code 143 (128+SIGTERM)" "143" "$CHILD_RC"

# SPEC-1b: no spurious assertion-failure (✗) lines after TERM fires
SPURIOUS_FAILS="$(grep -c '✗' "$CHILD_OUTPUT" 2>/dev/null || true)"
assert_eq "[SPEC-1] no bogus assertion-failure lines in output after SIGTERM" "0" "$SPURIOUS_FAILS"

# SPEC-2: AUTO_TEST_TEMP_DIR must be cleaned by the TERM trap
CHILD_TEMPDIR="$(cat "$CHILD_TEMPDIR_FILE" 2>/dev/null || true)"
if [[ -z "$CHILD_TEMPDIR" ]]; then
    assert_fail "[SPEC-2] child surfaced AUTO_TEST_TEMP_DIR path" "no path in witness file"
elif [[ -d "$CHILD_TEMPDIR" ]]; then
    assert_fail "[SPEC-2] AUTO_TEST_TEMP_DIR cleaned on SIGTERM" \
        "directory still exists: $CHILD_TEMPDIR"
    rm -rf "$CHILD_TEMPDIR" 2>/dev/null || true
else
    assert_pass "[SPEC-2] AUTO_TEST_TEMP_DIR cleaned on SIGTERM"
fi

# ─── Normal-exit guard: EXIT path cleans up and exits 0 ─────────────────────
print_test_section "Normal exit: EXIT trap cleans up and child exits 0"

CHILD2_OUTPUT="$WITNESS_DIR/child2-output.txt"
CHILD2_TEMPDIR_FILE="$WITNESS_DIR/child2-tempdir.txt"

bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/scripts/lib/test-helpers.sh'
    setup_test_env 'harness-term-normal-exit'
    printf '%s' \"\$AUTO_TEST_TEMP_DIR\" > '$CHILD2_TEMPDIR_FILE'
    assert_pass 'T0: normal-exit assertion'
    print_test_results
" >"$CHILD2_OUTPUT" 2>&1
CHILD2_RC=$?

assert_eq "normal exit: exit code is 0" "0" "$CHILD2_RC"
CHILD2_TEMPDIR="$(cat "$CHILD2_TEMPDIR_FILE" 2>/dev/null || true)"
if [[ -n "$CHILD2_TEMPDIR" && -d "$CHILD2_TEMPDIR" ]]; then
    assert_fail "normal exit: AUTO_TEST_TEMP_DIR cleaned by EXIT trap" \
        "still exists: $CHILD2_TEMPDIR"
    rm -rf "$CHILD2_TEMPDIR" 2>/dev/null || true
elif [[ -z "$CHILD2_TEMPDIR" ]]; then
    assert_fail "normal exit: child surfaced AUTO_TEST_TEMP_DIR path" "no path"
else
    assert_pass "normal exit: AUTO_TEST_TEMP_DIR cleaned by EXIT trap"
fi

print_test_results
exit $((FAIL > 0))
