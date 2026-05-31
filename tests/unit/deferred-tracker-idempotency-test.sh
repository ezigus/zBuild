#!/usr/bin/env bash
# Tests: scripts/deferred-tracker.sh::read_scanned_prs, compute_since_anchor,
#                                    is_already_scanned, append_to_log
#
# Behavioral coverage for ADR-020 §Idempotency. CRITICAL invariants:
# - PR in log → never re-scanned
# - "since last run" anchored to max(mergedAt) in log, not wall-clock
# - append is idempotent (no duplicate rows)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/deferred-tracker.sh
source "$REPO_ROOT/scripts/deferred-tracker.sh"

print_test_header "deferred-tracker — idempotency (ADR-020 / #531)"

setup_test_env() {
    TEST_LOG="$TEST_TEMP_DIR/scanned-prs.md"
}
setup_test_env

# ─── Empty log → empty read ──────────────────────────────────────────────────
out="$(read_scanned_prs "$TEST_LOG")"
assert_eq "I1: missing log returns empty" "" "$out"

# ─── Populated log → returns PR numbers ──────────────────────────────────────
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
| #510 | first PR | 2026-05-29 |
| #520 | second PR | 2026-05-30 |
| #530 | third PR | 2026-05-31 |
EOF
out="$(read_scanned_prs "$TEST_LOG")"
expected="510
520
530"
assert_eq "I2: three entries parsed" "$expected" "$out"

# ─── is_already_scanned: PR in log → 0 (true) ────────────────────────────────
if is_already_scanned "520" "$TEST_LOG"; then
    assert_pass "I3: #520 detected as scanned"
else
    assert_fail "I3: #520 should be scanned but wasn't detected"
fi

# ─── is_already_scanned: PR NOT in log → 1 (false) ───────────────────────────
if is_already_scanned "999" "$TEST_LOG"; then
    assert_fail "I4: #999 wrongly detected as scanned"
else
    assert_pass "I4: #999 correctly not detected as scanned"
fi

# ─── Append idempotency: same PR twice doesn't duplicate ─────────────────────
append_to_log "$TEST_LOG" "540|fourth PR"
rows_before=$(grep -c "^| #540" "$TEST_LOG")
append_to_log "$TEST_LOG" "540|fourth PR"
rows_after=$(grep -c "^| #540" "$TEST_LOG")
assert_eq "I5: re-append doesn't duplicate (REGRESSION LOCK)" "$rows_before" "$rows_after"

# ─── Append new entry ────────────────────────────────────────────────────────
append_to_log "$TEST_LOG" "550|fifth PR"
out="$(read_scanned_prs "$TEST_LOG")"
assert_contains "I6: #550 appended" "$out" "550"

# ─── compute_since_anchor returns max date when log has dates ────────────────
# Use a log with column 4 dates that match our format
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
| #510 | first PR | 2026-05-29 |
| #520 | second PR | 2026-05-30 |
| #530 | third PR | 2026-05-31 |
EOF
out="$(compute_since_anchor "$TEST_LOG")"
assert_eq "I7: anchor = max date from log (NOT wall-clock)" "2026-05-31" "$out"

# ─── compute_since_anchor returns empty for empty log ────────────────────────
echo '' > "$TEST_LOG"
out="$(compute_since_anchor "$TEST_LOG")"
assert_eq "I8: empty log → empty anchor (triggers bootstrap)" "" "$out"

print_test_results
