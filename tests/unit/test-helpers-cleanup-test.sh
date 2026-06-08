#!/usr/bin/env bash
# Unit: Wave 19-L (#749) — setup_test_env's TEST_TEMP_DIR must be cleaned
# up by the master EXIT trap, even when the test does NOT explicitly call
# cleanup_test_env or set _test_cleanup_hook.
#
# Audit (2026-06-08) found 245 tests call setup_test_env, 201 call
# cleanup_test_env — 44-test gap relying on trap to clean. But the master
# trap (test-helpers.sh:85) only rm's AUTO_TEST_TEMP_DIR; the named dir
# created at line 205 is leaked, producing 1,261 stages / ~13GB.
#
# Fix: setup_test_env must register its new TEST_TEMP_DIR for cleanup in
# the master trap (e.g., by appending to a tracked list the trap reads,
# or by defaulting _test_cleanup_hook to cleanup_test_env when unset).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "setup_test_env: master trap cleans named TEST_TEMP_DIR (Wave 19-L, #749)"

# Spawn a child shell that (a) sources test-helpers.sh, (b) calls
# setup_test_env "foo" without setting _test_cleanup_hook, then exits.
# After the child returns, the child's TEST_TEMP_DIR must NOT exist.
print_test_section "named TEST_TEMP_DIR is cleaned up on child exit"

WITNESS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zb-l-witness.XXXXXX")"
trap "rm -rf '$WITNESS_DIR'" EXIT

CHILD_OUT="$WITNESS_DIR/child-tempdir.txt"
bash -c "
    set -euo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/scripts/lib/test-helpers.sh'
    setup_test_env 'wave-19-l-child'
    # Surface the temp dir path so we can check it from the parent.
    printf '%s' \"\$TEST_TEMP_DIR\" > '$CHILD_OUT'
    # Intentionally NO cleanup_test_env call, NO _test_cleanup_hook override.
    # The master EXIT trap must handle cleanup.
" 2>/dev/null || true

CHILD_TEMPDIR="$(cat "$CHILD_OUT" 2>/dev/null || true)"

if [[ -z "$CHILD_TEMPDIR" ]]; then
    assert_fail "T1: child surfaced its TEST_TEMP_DIR path" "no path"
    print_test_results
    exit 1
fi
assert_pass "T1: child surfaced its TEST_TEMP_DIR path ($CHILD_TEMPDIR)"

# After the child exited, the named TEST_TEMP_DIR must NOT exist on disk.
if [[ -d "$CHILD_TEMPDIR" ]]; then
    # Diagnostic — show what's still there.
    leaked_size="$(du -sh "$CHILD_TEMPDIR" 2>/dev/null | awk '{print $1}')"
    assert_fail "T2: named TEST_TEMP_DIR cleaned by master EXIT trap" \
        "leaked at $CHILD_TEMPDIR ($leaked_size)"
    # Clean it up so this test itself doesn't contribute.
    rm -rf "$CHILD_TEMPDIR" 2>/dev/null || true
else
    assert_pass "T2: named TEST_TEMP_DIR cleaned by master EXIT trap"
fi

# T3: AUTO_TEST_TEMP_DIR cleanup is also exercised (regression guard).
# Spawn another child that does NOT call setup_test_env at all.
CHILD_AUTO_OUT="$WITNESS_DIR/child-auto-tempdir.txt"
bash -c "
    set -euo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/scripts/lib/test-helpers.sh'
    printf '%s' \"\$AUTO_TEST_TEMP_DIR\" > '$CHILD_AUTO_OUT'
" 2>/dev/null || true

CHILD_AUTO_TEMPDIR="$(cat "$CHILD_AUTO_OUT" 2>/dev/null || true)"
if [[ -n "$CHILD_AUTO_TEMPDIR" && -d "$CHILD_AUTO_TEMPDIR" ]]; then
    assert_fail "T3: AUTO_TEST_TEMP_DIR cleaned (regression guard)" \
        "leaked at $CHILD_AUTO_TEMPDIR"
    rm -rf "$CHILD_AUTO_TEMPDIR" 2>/dev/null || true
else
    assert_pass "T3: AUTO_TEST_TEMP_DIR cleaned (regression guard)"
fi

print_test_results
exit $((FAIL > 0))
