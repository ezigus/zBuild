#!/usr/bin/env bash
# Tests: scripts/lib/gh-automation.sh::gha_compute_similarity + gha_score_meets_threshold
#
# Behavioral coverage for shared Jaccard-similarity helper (#558, sub-1 of #555).
# Locks: stopword filter, <4-char token filter, case-insensitivity, punctuation
# stripping, multi-line handling, empty/zero-divisor safety, symmetry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/gh-automation.sh
source "$REPO_ROOT/scripts/lib/gh-automation.sh"

print_test_header "gh-automation — Jaccard similarity (#558)"

# ─── U1: identical inputs → 1.00 ────────────────────────────────────────────
got="$(gha_compute_similarity "phase cleanup foo" "phase cleanup foo")"
assert_eq "U1: identical strings → 1.00" "1.00" "$got"

# ─── U2: disjoint distinctive tokens → 0.00 ────────────────────────────────
got="$(gha_compute_similarity "phase cleanup foo" "router golden bench")"
assert_eq "U2: disjoint tokens → 0.00" "0.00" "$got"

# ─── U3: symmetric — sim(A,B) == sim(B,A) ──────────────────────────────────
ab="$(gha_compute_similarity "phase cleanup router" "phase router golden")"
ba="$(gha_compute_similarity "phase router golden" "phase cleanup router")"
assert_eq "U3: symmetric Jaccard" "$ab" "$ba"

# ─── U4: stopwords filtered (REGRESSION LOCK) ──────────────────────────────
got="$(gha_compute_similarity "the and that" "the and that")"
assert_eq "U4 LOCK: all-stopword inputs → 0.00" "0.00" "$got"

# ─── U5: tokens <4 chars filtered (REGRESSION LOCK) ────────────────────────
got="$(gha_compute_similarity "a bc cli" "a bc go")"
assert_eq "U5 LOCK: sub-4-char tokens filtered → 0.00" "0.00" "$got"

# ─── U6: case-insensitive (REGRESSION LOCK) ────────────────────────────────
got="$(gha_compute_similarity "Phase Cleanup Foo" "phase cleanup foo")"
assert_eq "U6 LOCK: case-insensitive → 1.00" "1.00" "$got"

# ─── U7: empty a, non-empty b → 0.00 ───────────────────────────────────────
got="$(gha_compute_similarity "" "phase cleanup foo")"
assert_eq "U7: empty a → 0.00" "0.00" "$got"

# ─── U8: both empty → 0.00 (REGRESSION LOCK: no NaN, no error exit) ────────
got="$(gha_compute_similarity "" "" || echo "ERR")"
assert_eq "U8 LOCK: both empty → 0.00 (no divide-by-zero)" "0.00" "$got"

# ─── U9: zero-tokens-after-filter on both sides → 0.00 ─────────────────────
got="$(gha_compute_similarity "the a it" "and is of")"
assert_eq "U9: both filter to empty → 0.00" "0.00" "$got"

# ─── U10: multi-line input treated like spaces ─────────────────────────────
got="$(gha_compute_similarity $'phase cleanup\nfoo bar' "phase cleanup foo bar")"
assert_eq "U10: newline == space → 1.00" "1.00" "$got"

# ─── U11: partial overlap — 2/6 jaccard → 0.33 ─────────────────────────────
# A={phase,cleanup,router,golden}, B={phase,cleanup,bench,harness} → |∩|=2, |∪|=6
got="$(gha_compute_similarity "phase cleanup router golden" "phase cleanup bench harness")"
assert_eq "U11: 2/6 Jaccard → 0.33" "0.33" "$got"

# ─── U12: punctuation stripped ─────────────────────────────────────────────
got="$(gha_compute_similarity "phase, cleanup. foo!" "phase cleanup foo")"
assert_eq "U12: punctuation stripped → 1.00" "1.00" "$got"

# ─── U13: threshold helper — score above threshold returns 0 ───────────────
if gha_score_meets_threshold "0.75" "0.50"; then
    assert_pass "U13: 0.75 >= 0.50 → meets threshold"
else
    assert_fail "U13: 0.75 should meet 0.50 threshold"
fi

# ─── U14: threshold helper — score below returns 1 (REGRESSION LOCK) ───────
# Locks float-comparison idiom: must NOT use integer -ge / -lt on "0.33".
if gha_score_meets_threshold "0.33" "0.50"; then
    assert_fail "U14 LOCK: 0.33 wrongly reported >= 0.50 (string-compare bug?)"
else
    assert_pass "U14 LOCK: 0.33 < 0.50 → below threshold"
fi

print_test_results
