#!/usr/bin/env bash
# Tests: ZBUILD_TEST_QUIET=1 suppresses per-assertion echoes in test-helpers
# (#600). Failures ALWAYS echo regardless of the env var. Counters unchanged.
# print_test_results emits a compact one-liner when quiet.
# No `set -e`: subshells that invoke print_test_results exit with $FAIL,
# which would otherwise trip errexit on the enclosing assignment.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test-helpers in the OUTER process so we have working asserts for the
# meta-test. The behaviors we exercise must be tested in CLEAN subshells (so
# the env var and counter mutations cannot leak between cases).
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ZBUILD_TEST_QUIET mode (#600)"

HELPERS_PATH="$REPO_ROOT/scripts/lib/test-helpers.sh"

# Run a snippet in a fresh bash subshell that sources test-helpers.sh, then
# captures all stdout. Stderr is dropped to keep assertions on stdout content.
# Usage: run_in_subshell <env_setup> <snippet>
run_in_subshell() {
    local env_setup="$1"
    local snippet="$2"
    bash -c "
        set +e
        $env_setup
        # shellcheck disable=SC1090
        source '$HELPERS_PATH' >/dev/null 2>&1
        $snippet
    " 2>/dev/null
}

# ─── V1: quiet=1 → assert_pass produces NO output ────────────────────────────
out="$(run_in_subshell 'export ZBUILD_TEST_QUIET=1' 'assert_pass "T1 sample"')"
if [[ -z "$out" ]]; then
    assert_pass "V1 quiet=1: assert_pass emits no output"
else
    assert_fail "V1 quiet=1: assert_pass emits no output" "got: $out"
fi

# ─── V2: quiet=1 → assert_fail STILL emits output ─────────────────────────────
out="$(run_in_subshell 'export ZBUILD_TEST_QUIET=1' 'assert_fail "T2 broke" "boom"')"
if [[ "$out" == *"T2 broke"* ]]; then
    assert_pass "V2 quiet=1: assert_fail still emits"
else
    assert_fail "V2 quiet=1: assert_fail still emits" "got: $out"
fi

# ─── V3: quiet=1 → counters still increment correctly ────────────────────────
out="$(run_in_subshell 'export ZBUILD_TEST_QUIET=1' '
    assert_pass "a"; assert_pass "b"; assert_fail "c"
    printf "PASS=%s FAIL=%s TOTAL=%s\n" "$PASS" "$FAIL" "$TOTAL"')"
if [[ "$out" == *"PASS=2 FAIL=1 TOTAL=3"* ]]; then
    assert_pass "V3 quiet=1: counters increment normally"
else
    assert_fail "V3 quiet=1: counters increment normally" "got: $out"
fi

# ─── V4: unset → assert_pass DOES emit (default behavior preserved) ──────────
out="$(run_in_subshell 'unset ZBUILD_TEST_QUIET' 'assert_pass "T4 verbose"')"
if [[ "$out" == *"T4 verbose"* ]]; then
    assert_pass "V4 unset: assert_pass emits (default)"
else
    assert_fail "V4 unset: assert_pass emits (default)" "got: $out"
fi

# ─── V5: quiet=0 → assert_pass DOES emit (explicit off) ──────────────────────
out="$(run_in_subshell 'export ZBUILD_TEST_QUIET=0' 'assert_pass "T5 explicit-off"')"
if [[ "$out" == *"T5 explicit-off"* ]]; then
    assert_pass "V5 quiet=0: assert_pass emits (default)"
else
    assert_fail "V5 quiet=0: assert_pass emits (default)" "got: $out"
fi

# ─── V6: quiet=1 → print_test_results emits compact summary line ─────────────
# Override exit at end of print_test_results to avoid killing capture.
out="$(run_in_subshell 'export ZBUILD_TEST_QUIET=1' '
    PASS=47; FAIL=0; TOTAL=47
    print_test_results || true')"
# Strip ANSI for matching
clean="$(printf '%s' "$out" | sed -E $'s/\x1b\\[[0-9;]*m//g')"
if [[ "$clean" == *"47/47"* ]] && [[ "$clean" == *"passed"* ]]; then
    assert_pass "V6 quiet=1: compact summary on all-pass"
else
    assert_fail "V6 quiet=1: compact summary on all-pass" "got: $clean"
fi

# ─── V7: quiet=1 + failures → compact summary shows FAILED count ─────────────
out="$(run_in_subshell 'export ZBUILD_TEST_QUIET=1' '
    PASS=45; FAIL=2; TOTAL=47
    FAILURES=("a failure" "another failure")
    print_test_results || true')"
clean="$(printf '%s' "$out" | sed -E $'s/\x1b\\[[0-9;]*m//g')"
if [[ "$clean" == *"45/47"* ]] && [[ "$clean" == *"2"* ]] && [[ "$clean" == *"FAIL"* ]]; then
    assert_pass "[SPEC-5] V7 quiet=1: compact summary on failures (guard: FAIL path unaffected by SKIP branch)"
else
    assert_fail "[SPEC-5] V7 quiet=1: compact summary on failures (guard: FAIL path unaffected by SKIP branch)" "got: $clean"
fi

# ─── V8: per-process scope — outer process unaffected by inner quiet=1 ────────
# Source-time and reset our own counters. The inner subshell using quiet=1
# must not leak the variable into our (outer) process.
run_in_subshell 'export ZBUILD_TEST_QUIET=1' 'assert_pass "inner"' >/dev/null
if [[ -z "${ZBUILD_TEST_QUIET:-}" ]]; then
    assert_pass "V8 quiet env does not leak to parent"
else
    assert_fail "V8 quiet env does not leak to parent" "leaked=$ZBUILD_TEST_QUIET"
fi

print_test_results
