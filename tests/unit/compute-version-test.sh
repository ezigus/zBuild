#!/usr/bin/env bash
# Tests: scripts/lib/versioning/initiative-count.sh — pure compute_version (ADR-048, #873)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/versioning/initiative-count.sh
source "$REPO_ROOT/scripts/lib/versioning/initiative-count.sh"

print_test_header "compute_version — pure 4-part A.B.C.D assembly (#873)"

# ─── SPEC-1: canonical assembly ─────────────────────────────────────────────
print_test_section "SPEC-1: assembles A.B.C.D"
assert_eq "1.0,1,12 -> 1.0.1.12"  "1.0.1.12"  "$(compute_version 1.0 1 12)"
assert_eq "1.0,0,0 -> 1.0.0.0 (initiative release)" "1.0.0.0" "$(compute_version 1.0 0 0)"
assert_eq "1.0,2,13 -> 1.0.2.13" "1.0.2.13" "$(compute_version 1.0 2 13)"
assert_eq "1.1,0,0 -> 1.1.0.0 (rolled initiative)" "1.1.0.0" "$(compute_version 1.1 0 0)"

# ─── SPEC-2: multi-digit parts ──────────────────────────────────────────────
print_test_section "SPEC-2: multi-digit parts"
assert_eq "12.34,56,789 -> 12.34.56.789" "12.34.56.789" "$(compute_version 12.34 56 789)"

# ─── SPEC-3: malformed anchor fails loud ────────────────────────────────────
print_test_section "SPEC-3: malformed anchor -> fail-loud rc=1"
set +e
compute_version "1" 0 0 >/dev/null 2>&1;      assert_eq "anchor '1' (not A.B) fails"        "1" "$?"
compute_version "1.0.0" 0 0 >/dev/null 2>&1;  assert_eq "anchor '1.0.0' (3-part) fails"     "1" "$?"
compute_version "x.y" 0 0 >/dev/null 2>&1;    assert_eq "anchor 'x.y' (non-numeric) fails"  "1" "$?"
compute_version "1." 0 0 >/dev/null 2>&1;     assert_eq "anchor '1.' fails"                 "1" "$?"
set -e

# ─── SPEC-4: malformed C / D fail loud ──────────────────────────────────────
print_test_section "SPEC-4: malformed C/D -> fail-loud rc=1"
set +e
compute_version 1.0 "x" 0 >/dev/null 2>&1;    assert_eq "release_count 'x' fails"  "1" "$?"
compute_version 1.0 0 "y" >/dev/null 2>&1;    assert_eq "issues_since 'y' fails"   "1" "$?"
compute_version 1.0 "1.2" 0 >/dev/null 2>&1;  assert_eq "release_count '1.2' fails" "1" "$?"
compute_version 1.0 "-1" 0 >/dev/null 2>&1;   assert_eq "release_count '-1' fails" "1" "$?"
set -e

# ─── SPEC-5: wrong arg count fails loud ─────────────────────────────────────
print_test_section "SPEC-5: wrong arity -> fail-loud rc=1"
set +e
compute_version 1.0 1 >/dev/null 2>&1;         assert_eq "2 args fails"  "1" "$?"
compute_version 1.0 1 2 3 >/dev/null 2>&1;     assert_eq "4 args fails"  "1" "$?"
compute_version >/dev/null 2>&1;               assert_eq "0 args fails"  "1" "$?"
set -e

# ─── SPEC-6: purity — no git/gh required ────────────────────────────────────
print_test_section "SPEC-6: pure (runs with PATH stripped of git/gh)"
out="$(PATH=/nonexistent compute_version 1.0 3 7 2>/dev/null)"
assert_eq "compute_version works with empty PATH" "1.0.3.7" "$out"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
