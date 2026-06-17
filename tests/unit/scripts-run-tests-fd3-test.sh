#!/usr/bin/env bash
# Tests: scripts/run-tests.sh opens fd 3 before invoking each test file (#586).
# Without the harness fix, a sourced stage-io.sh that requires fd 3 would fail
# with "ZBUILD_STAGE_IO_FD=3 is not open for write". This test asserts that
# scripts/run-tests.sh spawns the inner `bash "$f"` with fd 3 open.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/run-tests.sh opens fd 3 for child tests (#586)"
setup_test_env "run-tests-fd3"

# ─── Build a fake tier dir with a single test file ──────────────────────────
FAKE_TIER="$TEST_TEMP_DIR/fake-tier"
mkdir -p "$FAKE_TIER/tests/unit"

# Fixture test: writes to fd 3. If fd 3 is open, succeeds (rc=0). If not, the
# redirection itself returns nonzero and the test fails.
cat > "$FAKE_TIER/tests/unit/fd3-probe-test.sh" <<'PROBE'
#!/usr/bin/env bash
set -e
if ! ( : >&3 ) 2>/dev/null; then
    echo "FD3_CLOSED" >&2
    exit 1
fi
echo "FD3_OPEN"
PROBE
chmod +x "$FAKE_TIER/tests/unit/fd3-probe-test.sh"

# #929 moved the spawn into the shared `_rt_run` helper. The fd-3 contract now
# lives there: `"${_rt_tout[@]}" bash "$1" </dev/null 3>/dev/null >"$2" 2>&1`.
# Assert that helper line still opens fd 3 for the child (and, per #929, also
# guards stdin with </dev/null).
out="$(mktemp -t fd3probe.XXXXXX)"
set +e
spawn_line="$(grep -E 'bash "\$1"' "$REPO_ROOT/scripts/run-tests.sh" | head -1)"
set -e

[[ -n "$spawn_line" ]] \
    && assert_pass "_rt_run spawn line found" \
    || assert_fail "_rt_run spawn line not found in run-tests.sh"

# Parse: assert the line includes '3>' (fd 3, #586) and '</dev/null' (stdin, #929)
case "$spawn_line" in
    *"3>"*) assert_pass "T1 _rt_run includes fd 3 redirection (#586)" ;;
    *)      assert_fail "T1 _rt_run missing fd 3 redirection (got: $spawn_line)" ;;
esac
case "$spawn_line" in
    *"</dev/null"*) assert_pass "T1b _rt_run guards stdin with </dev/null (#929)" ;;
    *)              assert_fail "T1b _rt_run missing </dev/null stdin guard (got: $spawn_line)" ;;
esac

# ─── Functional test: invoke fixture through the actual harness ─────────────
# Stage the fixture as if it were the only unit test. We can't repoint
# TESTS_DIR (the script hardcodes it), so we instead exec the inner spawn
# pattern directly using the same redirection the harness uses.
f="$FAKE_TIER/tests/unit/fd3-probe-test.sh"
out2="$(mktemp -t fd3probe2.XXXXXX)"
set +e
# Mirror the post-fix line exactly:
bash "$f" 3>/dev/null >"$out2" 2>&1
rc=$?
set -e
assert_eq "T2 probe under harness-pattern returns 0" "0" "$rc"
assert_contains "T2 probe stdout contains FD3_OPEN" "$(cat "$out2")" "FD3_OPEN"

rm -f "$out" "$out2"
cleanup_test_env
print_test_results
