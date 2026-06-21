#!/usr/bin/env bash
# Unit: scripts/lib/artifact-render.sh locale hardening (#830).
#
# The two sed -E sites in _artifact_md_escape_inline (~line 115) and
# _artifact_md_escape_block (~line 134) had the same illegal-byte-abort
# vulnerability as the test-output sanitizer — they process LLM-controlled
# titles/bodies that can contain non-UTF-8 bytes from prompt-injection
# attempts, captured stderr fragments, or binary diff hunks.
#
# This test asserts both escape helpers accept arbitrary bytes without
# aborting, regardless of caller locale.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: artifact-render escape helpers locale safety (#830)"
setup_test_env "artifact-render-locale-830"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# ─── T1: _artifact_md_escape_inline tolerates invalid bytes ─────────────────
# \xC0\x80 = overlong-NUL; \x1b[1m...\x1b[0m = ANSI bold sequence.
INPUT_INLINE="$(printf '\xc0\x80\x1b[1mbold\x1b[0m')"
set +e
OUT_INLINE="$(_artifact_md_escape_inline "$INPUT_INLINE" 2>/dev/null)"
rc_inline=$?
set -e
assert_eq "T1: _artifact_md_escape_inline rc=0 on ANSI + invalid byte" \
    "0" "$rc_inline"
if [[ "$OUT_INLINE" == *bold* ]]; then
    assert_pass "T1: 'bold' content survived inline escape"
else
    assert_fail "T1: inline escape dropped content" "got: $OUT_INLINE"
fi
if grep -q $'\x1b' 2>/dev/null <<< "$OUT_INLINE"; then
    assert_fail "T1: inline escape left ANSI sequence intact" \
        "got bytes: $(printf '%s' "$OUT_INLINE" | od -c | head -2)"
else
    assert_pass "T1: ANSI stripped from inline output"
fi

# ─── T2: _artifact_md_escape_block tolerates invalid bytes ──────────────────
INPUT_BLOCK="$(printf 'line1\xc0\x80\n\x1b[31mline2 red\x1b[0m\nline3\n')"
set +e
OUT_BLOCK="$(_artifact_md_escape_block "$INPUT_BLOCK" 2>/dev/null)"
rc_block=$?
set -e
assert_eq "T2: _artifact_md_escape_block rc=0 on multi-line invalid bytes" \
    "0" "$rc_block"
# Block escape preserves newlines; line2 should be visible without ANSI.
if [[ "$OUT_BLOCK" == *'line2 red'* ]]; then
    assert_pass "T2: 'line2 red' content survived block escape"
else
    assert_fail "T2: block escape dropped content" "got: $OUT_BLOCK"
fi
if grep -q $'\x1b' 2>/dev/null <<< "$OUT_BLOCK"; then
    assert_fail "T2: block escape left ANSI sequence intact"
else
    assert_pass "T2: ANSI stripped from block output"
fi

# ─── T3: hostile caller locale — both helpers honor per-invocation prefix ──
set +e
HOSTILE_INLINE="$(LC_ALL=invalid.bogus _artifact_md_escape_inline "$(printf '\x1b[31mz\x1b[0m')" 2>/dev/null)"
rc_h_inline=$?
HOSTILE_BLOCK="$(LC_ALL=invalid.bogus _artifact_md_escape_block "$(printf '\x1b[31mz\x1b[0m\n')" 2>/dev/null)"
rc_h_block=$?
set -e
assert_eq "T3: inline escape under hostile caller LC_ALL → rc=0" \
    "0" "$rc_h_inline"
assert_eq "T3: block escape under hostile caller LC_ALL → rc=0" \
    "0" "$rc_h_block"

# ─── T4: source-line guard — both sites carry LC_ALL=C prefix ──────────────
TARGET="$REPO_ROOT/scripts/lib/artifact-render.sh"
hits=$(grep -cE 'LC_ALL=C[[:space:]]+sed[[:space:]]+-E' "$TARGET" 2>/dev/null || echo 0)
if [[ "$hits" -ge 2 ]]; then
    assert_pass "T4: source carries LC_ALL=C on both escape helpers (hits=$hits)"
else
    assert_fail "T4: expected ≥2 LC_ALL=C sed sites in artifact-render.sh" \
        "got: $hits"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
