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

print_test_section "13. _test_pattern_runall — includes mutation tier (#593 codex P2)"

# Codex P2 caught that `mutation: N/M passed` from run-mutation.sh was being
# silently dropped. The cycle's failure-count tracking then sees .failed=0
# when only mutation fails. Now must be aggregated like the other tiers.
MUTATION_FIXTURE="$(cat <<'EOF'
unit: 126/126 passed
integration: 80/80 passed
e2e: 7/7 passed
golden: 1/1 passed
mutation: FAIL /repo/tests/mutation/some-mutation.sh
mutation: 18/20 passed
EOF
)"

OUT="$(_split "$MUTATION_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "runall+mutation: recognized=1" "1" "$r"
assert_eq "runall+mutation: passed=232 (126+80+7+1+18)" "232" "$p"
assert_eq "runall+mutation: failed=1 (mutation FAIL file)" "1" "$f"
assert_contains "runall+mutation: summary mentions mutation 18/20" "$s" "mutation 18/20"

# ═════════════════════════════════════════════════════════════════════════════
# #1229 — exit-code-authoritative + repo-agnostic (shape not name)
# ═════════════════════════════════════════════════════════════════════════════
print_test_section "S1. runall — lint tier failure is attributed (not '0 file failures')"

# The #944 dogfood shape: every canonical tier green, but the `lint` tier (added
# to --tier all per ADR-012 amendment / #1129 Change C) failed and exited 1.
# The old parser hardcoded unit|integration|e2e|golden|mutation and dropped lint
# → "…mutation 22/22 · 0 file failures (exit 1)" (a lie). Must count by shape.
LINT_FAIL_FIXTURE="$(cat <<'EOF'
unit: 126/126 passed
integration: 80/80 passed
e2e: 7/7 passed
golden: 1/1 passed
mutation: 20/20 passed
lint: 0/1 passed
lint: FAIL (npm run lint)
EOF
)"

OUT="$(_split "$LINT_FAIL_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "S1: recognized=1" "1" "$r"
assert_eq "S1: verdict=fail" "fail" "$v"
assert_gt  "S1: failed>=1" "$f" "0"
assert_contains "S1: summary names the failing lint suite" "$s" "lint"
if grep -qF -- "0 file failures" <<< "$s"; then
    assert_fail "S1: summary must NOT contradict rc with '0 file failures'" "got: $s"
else
    assert_pass "S1: summary does not print '0 file failures'"
fi

print_test_section "S2. runall — unknown suite name counted by shape"

# A suite name outside the old hardcoded list still counts (pass-line shape).
SMOKE_FIXTURE="$(cat <<'EOF'
smoke: 3/4 passed
EOF
)"
OUT="$(_split "$SMOKE_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "S2: recognized=1" "1" "$r"
assert_eq "S2: verdict=fail" "fail" "$v"
assert_contains "S2: summary names smoke" "$s" "smoke"

# FAIL-marker variant with an arbitrary suite name + path.
WEIRD_FIXTURE="$(cat <<'EOF'
widget: 5/5 passed
weird-name: FAIL /repo/tests/x-test.sh
EOF
)"
OUT="$(_split "$WEIRD_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "S2b: recognized=1" "1" "$r"
assert_eq "S2b: verdict=fail" "fail" "$v"
assert_contains "S2b: summary names weird-name" "$s" "weird-name"

print_test_section "S3. runall — rc=0 all green with generic names → pass"

GENERIC_PASS="$(cat <<'EOF'
smoke: 5/5 passed
lint: 1/1 passed
EOF
)"
OUT="$(_split "$GENERIC_PASS" 0)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "S3: recognized=1" "1" "$r"
assert_eq "S3: verdict=pass" "pass" "$v"
assert_eq "S3: failed=0" "0" "$f"

print_test_section "S4. runall — rc≠0 but zero counted → honest, not '0 file failures'"

# Aborted tier: all parsed lines green, no FAIL marker, yet the process exited 1.
# Verdict must follow the exit code; the summary must say so honestly.
ABORTED_FIXTURE="$(cat <<'EOF'
unit: 126/126 passed
integration: 80/80 passed
EOF
)"
OUT="$(_split "$ABORTED_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "S4: recognized=1" "1" "$r"
assert_eq "S4: verdict=fail (exit authoritative)" "fail" "$v"
assert_contains "S4: summary says not attributable" "$s" "not attributable"
assert_contains "S4: summary points to the log" "$s" "see log"
if grep -qF -- "0 file failures" <<< "$s"; then
    assert_fail "S4: summary must NOT print '0 file failures'" "got: $s"
else
    assert_pass "S4: summary does not print '0 file failures'"
fi

print_test_section "S5. runall shape anchor does not cross-capture other runners"

# The `<name>: N/M passed` slash shape is unique to run-tests.sh; jest and cargo
# bodies must NOT be captured by the generic runall anchor.
if _test_pattern_runall "$JEST_FIXTURE" 1 >/dev/null 2>&1; then
    assert_fail "S5: runall anchor must reject a jest body"
else
    assert_pass "S5: runall anchor rejects a jest body"
fi
if _test_pattern_runall "$CARGO_FIXTURE" 101 >/dev/null 2>&1; then
    assert_fail "S5: runall anchor must reject a cargo body"
else
    assert_pass "S5: runall anchor rejects a cargo body"
fi

print_test_section "S6. runall — 'total:' aggregate line is not double-counted (#1234)"

# run-tests.sh emits an AGGREGATE `total: P/T passed[ (N skipped)]` line after
# the per-suite lines (scripts/run-tests.sh:665). The shape-based genericization
# (#1229) matched it too → the parser summed the aggregate PLUS every per-suite
# line (double-count) and listed `total` as a suite. Only real per-suite lines
# must be summed; `total` is run-tests.sh's aggregate keyword, never a suite.
TOTAL_AGG_FIXTURE="$(cat <<'EOF'
unit: FAIL /repo/tests/unit/foo-test.sh
unit: 108/126 passed
integration: 77/77 passed
e2e: 7/7 passed
golden: 1/1 passed
total: 193/211 passed (5 skipped)
EOF
)"
OUT="$(_split "$TOTAL_AGG_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "S6: recognized=1" "1" "$r"
assert_eq "S6: verdict=fail" "fail" "$v"
# Sum of per-suite pass counts only: 108+77+7+1 = 193 (NOT 193+193=386).
assert_eq "S6: passed=193 (per-suite sum, not double-counted)" "193" "$p"
assert_contains "S6: summary names the failing unit suite" "$s" "unit"
# The aggregate must not appear as a suite in the summary parts nor as a failing
# suite (baseline listed `total 193/211` because 193<211 in the aggregate line).
if grep -qE 'total [0-9]+/[0-9]+' <<< "$s"; then
    assert_fail "S6: 'total' must NOT be shown as a suite" "got: $s"
else
    assert_pass "S6: 'total' aggregate is not shown as a suite"
fi

# ─── S7 (#1613): TIMEOUT is a non-passing marker, equal to FAIL ──────────────
# run-tests.sh labels a file killed at its per-file bound TIMEOUT rather than
# FAIL so a hang is distinguishable from an assertion failure. The parser must
# still treat it as a failure: recognising only FAIL would under-count failures
# and drop the timed-out file from the red set, so the targeted rerun would
# never re-run the very file that hung.
TIMEOUT_FIXTURE="$(cat <<'EOF'
unit: TIMEOUT /repo/tests/unit/hang-test.sh (exceeded 480s, rc=124)
unit: FAIL /repo/tests/unit/broken-test.sh
unit: 10/12 passed (1 timed out)
lint: FAIL (npm run lint)
total: 10/12 passed
EOF
)"
OUT="$(_split "$TIMEOUT_FIXTURE" 1)"
IFS='|' read -r v p f s r <<< "$OUT"
assert_eq "[SPEC-5] recognized=1 with a TIMEOUT marker present" "1" "$r"
assert_eq "[SPEC-5] verdict=fail when a file timed out" "fail" "$v"
# 3 markers: the TIMEOUT, the unit FAIL, and the file-less lint FAIL.
assert_eq "[SPEC-5] TIMEOUT counts toward the failure count" "3" "$f"
assert_contains "[SPEC-5] summary names the timed-out suite" "$s" "unit"

# Red set: the timed-out file must be present. Its line ends in
# `(exceeded 480s, rc=124)`, so a $NF-based extractor would yield `rc=124)`.
RED="$(_test_extract_failing_files "$TIMEOUT_FIXTURE")"
assert_contains "[SPEC-5] red set keeps the timed-out file" "$RED" "/repo/tests/unit/hang-test.sh"
assert_contains "[SPEC-5] red set keeps the genuinely failing file" "$RED" "/repo/tests/unit/broken-test.sh"
assert_eq "[SPEC-5] red set holds exactly the two real paths" "2" \
    "$(printf '%s\n' "$RED" | grep -c '/')"
if grep -q 'rc=' <<< "$RED"; then
    assert_fail "[SPEC-5] red set must not capture the TIMEOUT suffix" "got: $RED"
else
    assert_pass "[SPEC-5] red set does not capture the TIMEOUT suffix"
fi

print_test_results
