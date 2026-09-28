#!/usr/bin/env bash
# Tests: scripts/lib/test-helpers.sh re-entrancy guard (#971)
# A test invoked from inside another test run must abort fast (exit 2) instead of
# fork-bombing the pipeline test stage (the #929/#983/#971 recursion class). A
# fixture-isolated nested run (ZBUILD_TESTS_DIR set) is exempt, and a clean
# top-level run is unaffected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
# Sourcing this sets ZBUILD_TEST_EXEC_ACTIVE=1 in THIS process, so any child test
# we spawn below inherits it — exactly the nested-invocation condition under test.
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/test-helpers.sh — re-entrancy guard (#971)"
setup_test_env "reentry-guard"
_test_cleanup_hook() { cleanup_test_env; }

# Minimal nested "test" that sources the REAL test-helpers.sh (triggering the
# guard) and would print FIXTURE_RAN if allowed to proceed.
_fixture="$TEST_TEMP_DIR/nested-fixture-test.sh"
cat > "$_fixture" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
echo "FIXTURE_RAN"
exit 0
EOF
chmod +x "$_fixture"

# ─── SPEC-1: nested invocation (sentinel set, no TESTS_DIR) → abort exit 2 ────
# CHANGE: at baseline the guard does not exist → the child runs (FIXTURE_RAN, rc=0).
# Now the inherited ZBUILD_TEST_EXEC_ACTIVE makes the child refuse with exit 2.
set +e
_s1_out="$(bash "$_fixture" 2>&1)"; _s1_rc=$?
set -e
assert_eq "[SPEC-1] nested test aborts with exit 2" "2" "$_s1_rc"
assert_contains "[SPEC-1] refusal names the re-entrancy guard" "$_s1_out" "re-entrancy guard"
if grep -q FIXTURE_RAN <<< "$_s1_out"; then
    assert_fail "[SPEC-1] nested test body must NOT execute" "FIXTURE_RAN present"
else
    assert_pass "[SPEC-1] nested test body did not execute"
fi

# ─── SPEC-2: fixture-isolated nested run (ZBUILD_TESTS_DIR set) → exempt ──────
# GUARD: legitimate nested runs (run-tests.sh against a fixture dir) set
# ZBUILD_TESTS_DIR and must NOT be refused — mirrors the #983 exemption.
set +e
_s2_out="$(ZBUILD_TESTS_DIR="$TEST_TEMP_DIR/fix" bash "$_fixture" 2>&1)"; _s2_rc=$?
set -e
assert_eq "[SPEC-2] fixture-isolated nested run is exempt (exit 0)" "0" "$_s2_rc"
assert_contains "[SPEC-2] exempt fixture ran its body" "$_s2_out" "FIXTURE_RAN"

# ─── SPEC-3: clean top-level invocation (no sentinel) → runs normally ─────────
# GUARD: a test run with no sentinel set (the normal top-level case) is unaffected.
set +e
_s3_out="$(env -u ZBUILD_TEST_EXEC_ACTIVE bash "$_fixture" 2>&1)"; _s3_rc=$?
set -e
assert_eq "[SPEC-3] clean top-level test runs (exit 0)" "0" "$_s3_rc"
assert_contains "[SPEC-3] clean test ran its body" "$_s3_out" "FIXTURE_RAN"

print_test_results
