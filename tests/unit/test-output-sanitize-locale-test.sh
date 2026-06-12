#!/usr/bin/env bash
# Unit: scripts/lib/test-output-sanitize.sh locale hardening (#830).
#
# Dogfood evidence: a triple-timeout build run captured npm test output
# containing non-UTF-8 bytes. The sanitizer's `sed -E` aborted on macOS BSD
# sed with "RE error: illegal byte sequence", which cascaded to a malformed
# test_output JSON value and a fatal test stage exit. Fix: LC_ALL=C prefix.
#
# This test exercises the locale-safety contract directly: the sanitizer
# must accept ARBITRARY byte input and never abort, regardless of caller
# locale env.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: test-output-sanitize locale safety (#830)"
setup_test_env "sanitize-locale-830"

# shellcheck source=../../scripts/lib/test-output-sanitize.sh
source "$REPO_ROOT/scripts/lib/test-output-sanitize.sh"

# ─── T1: dogfood scenario — ANSI + invalid UTF-8 byte ────────────────────────
# \xC0\x80 is the overlong-NUL — universally rejected by every UTF-8
# validator. Without LC_ALL=C, BSD sed aborts with "illegal byte sequence".
F1="$TEST_TEMP_DIR/dogfood-mixed-bytes.txt"
printf '\xc0\x80 leading\n\x1b[31mred\x1b[0m line\n' > "$F1"
OUT1="$TEST_TEMP_DIR/dogfood-out.txt"
ERR1="$TEST_TEMP_DIR/dogfood-err.txt"
set +e
< "$F1" _zbuild_sanitize_for_llm > "$OUT1" 2> "$ERR1"
rc1=$?
set -e
assert_eq "T1: sanitizer rc=0 on ANSI + invalid UTF-8 (no abort)" "0" "$rc1"
if [[ -s "$ERR1" ]]; then
    assert_fail "T1: sanitizer wrote to stderr (should be silent on bad bytes)" \
        "stderr: $(head -c 200 "$ERR1")"
else
    assert_pass "T1: sanitizer stderr is empty"
fi
if grep -q 'red line' "$OUT1" 2>/dev/null; then
    assert_pass "T1: ANSI stripped, content 'red line' survived"
else
    assert_fail "T1: content lost in output" "got: $(head -c 200 "$OUT1")"
fi

# ─── T2: random bytes (8KB urandom) — contract test, never abort ────────────
F2="$TEST_TEMP_DIR/urandom.bin"
head -c 8192 /dev/urandom > "$F2"
OUT2="$TEST_TEMP_DIR/urandom-out.txt"
set +e
< "$F2" _zbuild_sanitize_for_llm > "$OUT2" 2>/dev/null
rc2=$?
set -e
assert_eq "T2: sanitizer rc=0 on 8KB /dev/urandom (contract — never abort)" \
    "0" "$rc2"

# ─── T3: hostile caller locale — LC_ALL set to invalid value ───────────────
# Proves POSIX command-prefix scoping works: even when the calling shell has
# a bogus LC_ALL, the per-invocation prefix in the sanitizer wins.
OUT3="$TEST_TEMP_DIR/hostile-locale-out.txt"
set +e
LC_ALL=invalid.bogus _zbuild_sanitize_for_llm <<< $'\x1b[31mx\x1b[0m' > "$OUT3" 2>/dev/null
rc3=$?
set -e
assert_eq "T3: hostile caller LC_ALL=invalid → sanitizer rc=0" "0" "$rc3"
val3="$(cat "$OUT3" 2>/dev/null)"
assert_eq "T3: hostile-locale ANSI still stripped to bare content" "x" "$val3"

# ─── T4: clean UTF-8 multi-byte preserved ───────────────────────────────────
# Under LC_ALL=C, sed processes raw bytes — but a valid UTF-8 multi-byte
# sequence (e.g. ✓ = E2 9C 93) cannot contain 0x1b, so the ANSI strip regex
# never matches inside the multi-byte char. Result: char preserved.
OUT4="$TEST_TEMP_DIR/utf8-out.txt"
printf '\x1b[32m✓\x1b[0m passed\n' | _zbuild_sanitize_for_llm > "$OUT4"
val4="$(cat "$OUT4")"
assert_eq "T4: clean UTF-8 multi-byte char preserved under LC_ALL=C" \
    "✓ passed" "$val4"

# ─── T5: source-line guard — LC_ALL=C prefix MUST be in the sed line ───────
# Regression guard: future refactors must keep the LC_ALL=C prefix on the
# sanitizer's sed invocation. String-match against the source.
TARGET="$REPO_ROOT/scripts/lib/test-output-sanitize.sh"
if grep -E '^[[:space:]]*LC_ALL=C[[:space:]]+sed[[:space:]]+-E[[:space:]]+\$' "$TARGET" >/dev/null 2>&1; then
    assert_pass "T5: source line carries LC_ALL=C prefix on sed"
else
    assert_fail "T5: source line missing LC_ALL=C prefix on sed (regression?)" \
        "grep target: $TARGET"
fi
if grep -E '^[[:space:]]*\|[[:space:]]+LC_ALL=C[[:space:]]+awk' "$TARGET" >/dev/null 2>&1 || \
   grep -E 'LC_ALL=C[[:space:]]+awk' "$TARGET" >/dev/null 2>&1; then
    assert_pass "T5: source line carries LC_ALL=C prefix on awk"
else
    assert_fail "T5: source line missing LC_ALL=C prefix on awk"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
