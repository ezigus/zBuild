#!/usr/bin/env bash
# Tests: plugins/tool/test/lib/parse.sh — pattern bank + orchestrator (#584)
#
# Validates that _test_parse_summary correctly recognizes 6 known test runner
# output shapes and emits an honest fail-safe (no fabricated counts) for
# unrecognized output. Mutual exclusivity is enforced by structural anchors.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: test/lib/parse.sh — pattern bank (#584)"

setup_test_env "test-parse-pattern-bank"

# shellcheck source=../../../../plugins/tool/test/lib/parse.sh
source "$REPO_ROOT/plugins/tool/test/lib/parse.sh"

# ─── helper: split orchestrator output ───────────────────────────────────────
_split() {
    local raw="$1" rc="$2"
    _test_parse_summary "$raw" "$rc"
}

# ═════════════════════════════════════════════════════════════════════════════
# Pattern 1: zbuild run-all.sh
# ═════════════════════════════════════════════════════════════════════════════
print_test_section "1. _test_pattern_runall — real shape (mixed fail)"

RUNALL_FIXTURE="$(cat <<'EOF'
unit: FAIL /repo/tests/unit/foo-test.sh
+ /tmp/zbuild-test-unit.XXX: line 4: bar: command not found
unit: 108/126 passed
integration: FAIL /repo/tests/integration/baz-test.sh
integration: 75/77 passed
e2e: 7/7 passed
golden: 1/1 passed
EOF
)"

OUT="$(_split "$RUNALL_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "runall: recognized=1" "1" "$r"
assert_eq "runall: verdict=fail" "fail" "$v"
assert_eq "runall: passed=191"  "191" "$p"
assert_eq "runall: failed=2 (file failures)" "2" "$f"
assert_contains "runall: summary mentions unit 108/126" "$s" "unit 108/126"

print_test_section "2. _test_pattern_runall — all suites pass"

RUNALL_PASS="$(cat <<'EOF'
unit: 126/126 passed
integration: 77/77 passed
e2e: 7/7 passed
golden: 1/1 passed
EOF
)"

OUT="$(_split "$RUNALL_PASS" 0)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "runall pass: recognized=1" "1" "$r"
assert_eq "runall pass: verdict=pass" "pass" "$v"
assert_eq "runall pass: passed=211" "211" "$p"
assert_eq "runall pass: failed=0"   "0"   "$f"

print_test_section "3. _test_pattern_runall — empty tier tolerated"

RUNALL_EMPTY="$(cat <<'EOF'
unit: 0/0 passed (empty tier)
integration: 5/5 passed
e2e: 0/0 passed (empty tier)
golden: 0/0 passed (empty tier)
EOF
)"

OUT="$(_split "$RUNALL_EMPTY" 0)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "runall empty tier: recognized=1" "1" "$r"
assert_eq "runall empty tier: passed=5"     "5" "$p"
assert_eq "runall empty tier: failed=0"     "0" "$f"

# ═════════════════════════════════════════════════════════════════════════════
# Pattern 2: jest
# ═════════════════════════════════════════════════════════════════════════════
print_test_section "4. _test_pattern_jest — failing run"

JEST_FIXTURE="$(cat <<'EOF'
Test Suites: 3 failed, 12 passed, 15 total
Tests:       18 failed, 108 passed, 126 total
Snapshots:   0 total
Time:        4.213 s
EOF
)"

OUT="$(_split "$JEST_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "jest: recognized=1" "1" "$r"
assert_eq "jest: verdict=fail" "fail" "$v"
assert_eq "jest: passed=108"   "108" "$p"
assert_eq "jest: failed=18"    "18"  "$f"

# ═════════════════════════════════════════════════════════════════════════════
# Pattern 3: mocha
# ═════════════════════════════════════════════════════════════════════════════
print_test_section "5. _test_pattern_mocha — failing run"

MOCHA_FIXTURE="$(cat <<'EOF'

  108 passing (2s)
  18 failing

  1) foo bar:
     AssertionError: expected 5 to equal 4
EOF
)"

OUT="$(_split "$MOCHA_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "mocha: recognized=1" "1" "$r"
assert_eq "mocha: verdict=fail" "fail" "$v"
assert_eq "mocha: passed=108"   "108" "$p"
assert_eq "mocha: failed=18"    "18"  "$f"

# ═════════════════════════════════════════════════════════════════════════════
# Pattern 4: pytest
# ═════════════════════════════════════════════════════════════════════════════
print_test_section "6. _test_pattern_pytest — failing run"

PYTEST_FIXTURE="$(cat <<'EOF'
============================= test session starts =============================
....FFF.......
=========================== 3 failed, 42 passed in 1.23s =========================
EOF
)"

OUT="$(_split "$PYTEST_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "pytest: recognized=1" "1" "$r"
assert_eq "pytest: verdict=fail" "fail" "$v"
assert_eq "pytest: passed=42"    "42" "$p"
assert_eq "pytest: failed=3"     "3"  "$f"

# ═════════════════════════════════════════════════════════════════════════════
# Pattern 5: go test
# ═════════════════════════════════════════════════════════════════════════════
print_test_section "7. _test_pattern_gotest — mixed run"

GOTEST_FIXTURE="$(cat <<'EOF'
=== RUN   TestFoo
--- PASS: TestFoo (0.00s)
=== RUN   TestBar
--- FAIL: TestBar (0.01s)
    bar_test.go:42: expected 5 got 4
=== RUN   TestBaz
--- PASS: TestBaz (0.00s)
FAIL	github.com/x/y	0.02s
EOF
)"

OUT="$(_split "$GOTEST_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "gotest: recognized=1" "1" "$r"
assert_eq "gotest: verdict=fail" "fail" "$v"
assert_eq "gotest: passed=2"     "2"  "$p"
assert_eq "gotest: failed=1"     "1"  "$f"

# ═════════════════════════════════════════════════════════════════════════════
# Pattern 6: cargo test
# ═════════════════════════════════════════════════════════════════════════════
print_test_section "8. _test_pattern_cargo — single crate"

CARGO_FIXTURE="$(cat <<'EOF'
running 2 tests
test foo ... ok
test bar ... FAILED
test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out
EOF
)"

OUT="$(_split "$CARGO_FIXTURE" 101)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "cargo: recognized=1" "1" "$r"
assert_eq "cargo: verdict=fail" "fail" "$v"
assert_eq "cargo: passed=1"     "1"  "$p"
assert_eq "cargo: failed=1"     "1"  "$f"

print_test_section "9. _test_pattern_cargo — multi-crate sum"

CARGO_MULTI="$(cat <<'EOF'
running 3 tests
test a ... ok
test b ... ok
test c ... ok
test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out

running 4 tests
test d ... ok
test e ... ok
test f ... ok
test g ... FAILED
test result: FAILED. 3 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out
EOF
)"

OUT="$(_split "$CARGO_MULTI" 101)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "cargo multi: recognized=1" "1" "$r"
assert_eq "cargo multi: passed=6 (3+3)" "6" "$p"
assert_eq "cargo multi: failed=1"       "1" "$f"

# ═════════════════════════════════════════════════════════════════════════════
# Fail-safe path
# ═════════════════════════════════════════════════════════════════════════════
print_test_section "10. fail-safe: empty output"

OUT="$(_split "" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "failsafe empty: recognized=0"        "0"     "$r"
assert_eq "failsafe empty: verdict=error"       "error" "$v"
assert_eq "failsafe empty: passed=null"         "null"  "$p"
assert_eq "failsafe empty: failed=null"         "null"  "$f"
assert_contains "failsafe empty: summary mentions summary unavailable" "$s" "summary unavailable"

print_test_section "11. fail-safe: gibberish (compiler error)"

GIBBERISH="$(cat <<'EOF'
make: *** [Makefile:42: test] Error 1
ld: symbol not found: __foo
EOF
)"

OUT="$(_split "$GIBBERISH" 2)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "failsafe gibberish: recognized=0" "0" "$r"
assert_eq "failsafe gibberish: verdict=error" "error" "$v"
assert_eq "failsafe gibberish: passed=null"   "null" "$p"
assert_eq "failsafe gibberish: failed=null"   "null" "$f"
assert_contains "failsafe gibberish: banner has first failure" "$s" "first failure:"

print_test_section "12. fail-safe: prose containing literal 'passed'"

# Output containing the literal word 'passed' in narrative context but NO
# anchored summary line must NOT trick any pattern. Tests that anchors are
# load-bearing.
PROSE="$(cat <<'EOF'
the patch has not yet passed review
some other prose with the word failed in it
EOF
)"

OUT="$(_split "$PROSE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "failsafe prose: recognized=0 (anchors held)" "0" "$r"
assert_eq "failsafe prose: passed=null"                 "null" "$p"

print_test_results
