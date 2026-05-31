#!/usr/bin/env bash
# Tests: scripts/deferred-backfill.sh::parse_index_spec (#541)
#
# CRITICAL UX safeguard: `--file 1-5` and `--file 1,5` mean different things;
# parser must reject ambiguity and accept the canonical forms.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/deferred-backfill.sh
source "$REPO_ROOT/scripts/deferred-backfill.sh"

print_test_header "deferred-backfill — parse_index_spec (#541)"

# ─── Single index ──────────────────────────────────────────────────────────
out="$(parse_index_spec "1")"
assert_eq "P1: single index" "1" "$out"

# ─── Comma list ────────────────────────────────────────────────────────────
out="$(parse_index_spec "1,3")"
assert_eq "P2: comma list" "1 3" "$out"

# ─── Range ─────────────────────────────────────────────────────────────────
out="$(parse_index_spec "1-3")"
assert_eq "P3: range expands" "1 2 3" "$out"

# ─── Mixed ─────────────────────────────────────────────────────────────────
out="$(parse_index_spec "1,3-5,7")"
assert_eq "P4: mixed comma+range" "1 3 4 5 7" "$out"

# ─── Sort and dedup ────────────────────────────────────────────────────────
out="$(parse_index_spec "3,2,2")"
assert_eq "P5: sorted and deduped" "2 3" "$out"

# ─── REGRESSION LOCK: empty rejected ───────────────────────────────────────
if parse_index_spec "" >/dev/null 2>&1; then
    assert_fail "P6: empty spec wrongly accepted"
else
    assert_pass "P6: empty spec rejected"
fi

# ─── REGRESSION LOCK: non-numeric rejected ─────────────────────────────────
if parse_index_spec "abc" >/dev/null 2>&1; then
    assert_fail "P7: 'abc' wrongly accepted"
else
    assert_pass "P7: 'abc' rejected"
fi

# ─── REGRESSION LOCK: reverse range rejected ───────────────────────────────
if parse_index_spec "5-3" >/dev/null 2>&1; then
    assert_fail "P8: reverse range wrongly accepted"
else
    assert_pass "P8: reverse range '5-3' rejected"
fi

# ─── REGRESSION LOCK: malformed range rejected ─────────────────────────────
if parse_index_spec "1-" >/dev/null 2>&1; then
    assert_fail "P9: '1-' wrongly accepted"
else
    assert_pass "P9: '1-' rejected"
fi

if parse_index_spec "-1" >/dev/null 2>&1; then
    assert_fail "P10: '-1' wrongly accepted"
else
    assert_pass "P10: '-1' rejected"
fi

# ─── Whitespace tolerant ───────────────────────────────────────────────────
out="$(parse_index_spec "1, 3, 5")"
assert_eq "P11: whitespace around commas accepted" "1 3 5" "$out"

print_test_results
