#!/usr/bin/env bash
# Unit: scripts/lib/test-output-sanitize.sh — _zbuild_sanitize_test_output (Wave 15-C, #681)
#
# Asserts each of the 5 transforms + edge cases (empty input, idempotence,
# preservation of genuine test-failure signal).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "unit: test-output-sanitize _zbuild_sanitize_test_output (#681)"

# shellcheck source=../../scripts/lib/test-output-sanitize.sh
source "$REPO_ROOT/scripts/lib/test-output-sanitize.sh"

# ─── Transform 1: redaction-tag wrappers ─────────────────────────────────────
print_test_section "1. <out-of-scope-context> wrapper strip"

in1='at <out-of-scope-context>/var/folders/abc/tests/unit/foo.sh</out-of-scope-context>:42'
out1="$(printf '%s\n' "$in1" | _zbuild_sanitize_test_output)"
assert_eq "wrapper stripped, inner path preserved" \
    "at /var/folders/abc/tests/unit/foo.sh:42" "$out1"

# Multiple wrappers on same line
in1b='from <out-of-scope-context>/a/b</out-of-scope-context> to <out-of-scope-context>/c/d</out-of-scope-context>'
out1b="$(printf '%s\n' "$in1b" | _zbuild_sanitize_test_output)"
assert_eq "multiple wrappers per line both stripped" \
    "from /a/b to /c/d" "$out1b"

# ─── Transform 2: stage-io banner pairs ──────────────────────────────────────
print_test_section "2. stage-io banner line strip"

in2=$'before\n══ test [command] seq=1 input ══\nthe payload\n── end stage-io: test ✓ ──\nafter'
out2="$(printf '%s' "$in2" | _zbuild_sanitize_test_output)"
assert_contains "before-banner content preserved" "$out2" "before"
assert_contains "between-banners content preserved" "$out2" "the payload"
assert_contains "after-banner content preserved" "$out2" "after"
if grep -qF '══' <<< "$out2"; then
    assert_fail "heavy banner stripped" "still contains ══"
else
    assert_pass "heavy banner stripped"
fi
if grep -qF '──' <<< "$out2"; then
    assert_fail "light banner stripped" "still contains ──"
else
    assert_pass "light banner stripped"
fi

# ─── Transform 3: decorative separator lines ─────────────────────────────────
print_test_section "3. decorative separator strip (90%+ box-drawing)"

# 50-char ═ separator
sep_heavy=$'header\n══════════════════════════════════════════════════\ncontent'
out3a="$(printf '%s' "$sep_heavy" | _zbuild_sanitize_test_output)"
assert_contains "non-separator lines preserved (heavy)" "$out3a" "header"
assert_contains "non-separator lines preserved (heavy)" "$out3a" "content"
if grep -qE '^═+$' <<< "$out3a"; then
    assert_fail "heavy separator stripped" "still contains a ═-only line"
else
    assert_pass "heavy separator stripped"
fi

sep_light=$'header\n──────────────────────────────────────────────────\ncontent'
out3b="$(printf '%s' "$sep_light" | _zbuild_sanitize_test_output)"
if grep -qE '^─+$' <<< "$out3b"; then
    assert_fail "light separator stripped" "still contains a ─-only line"
else
    assert_pass "light separator stripped"
fi

# ─── Transform 4: ANSI CSI sequences ─────────────────────────────────────────
print_test_section "4. ANSI CSI escape strip"

in4=$'\x1b[38;2;74;222;128m✓\x1b[0m passed: my test'
out4="$(printf '%s\n' "$in4" | _zbuild_sanitize_test_output)"
assert_eq "ANSI stripped, ✓ + message preserved" \
    "✓ passed: my test" "$out4"

# ─── Transform 5: truncation footer ──────────────────────────────────────────
print_test_section "5. truncation footer strip"

in5=$'real output line\n↪ [56 more lines · full at /Users/x/test_assessment-3.json]\nafter'
out5="$(printf '%s' "$in5" | _zbuild_sanitize_test_output)"
assert_contains "real-output preserved" "$out5" "real output line"
assert_contains "after-footer preserved" "$out5" "after"
if grep -qF 'more lines' <<< "$out5"; then
    assert_fail "truncation footer stripped" "still contains footer"
else
    assert_pass "truncation footer stripped"
fi

# ─── Edge: empty input ───────────────────────────────────────────────────────
print_test_section "6. empty input"

out_e="$(printf '' | _zbuild_sanitize_test_output)"
assert_eq "empty input → empty output (no crash)" "" "$out_e"

# ─── Edge: idempotence ───────────────────────────────────────────────────────
print_test_section "7. idempotent (sanitize ∘ sanitize == sanitize)"

mixed=$'<out-of-scope-context>/p/x</out-of-scope-context>\n══ test input ══\n\x1b[31m✗\x1b[0m broke\n══════════════════════════════════════════════════\n↪ [9 more lines · full at /q/y.json]\nplain line'
once="$(printf '%s' "$mixed" | _zbuild_sanitize_test_output)"
twice="$(printf '%s' "$mixed" | _zbuild_sanitize_test_output | _zbuild_sanitize_test_output)"
assert_eq "second sanitize is a no-op" "$once" "$twice"

# ─── Edge: genuine test-failure signal preserved ─────────────────────────────
print_test_section "8. multi-line bash from a failed assertion preserved"

fail_block=$'FAIL: tests/unit/widget-test.sh\n  assert_eq: expected="abc"\n           got="xyz"\n  trace:\n    at widget.sh:42\n    at runner.sh:99\n  exit: 1'
out8="$(printf '%s' "$fail_block" | _zbuild_sanitize_test_output)"
assert_contains "FAIL header preserved" "$out8" "FAIL: tests/unit/widget-test.sh"
assert_contains "expected line preserved" "$out8" 'expected="abc"'
assert_contains "got line preserved" "$out8" 'got="xyz"'
assert_contains "trace frame preserved" "$out8" "at widget.sh:42"
assert_contains "exit code preserved" "$out8" "exit: 1"

print_test_results
