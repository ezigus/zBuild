#!/usr/bin/env bash
# Tests: scripts/deferred-backfill.sh::is_in_presented_log, append_presented_log (#541)
#
# Re-run safety: candidates already presented but not filed don't re-surface
# unless --include-presented is passed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/deferred-backfill.sh
source "$REPO_ROOT/scripts/deferred-backfill.sh"

print_test_header "deferred-backfill — presented log (#541)"

setup_test_env() {
    PLOG="$TEST_TEMP_DIR/presented.md"
}
setup_test_env

# ─── Missing log → nothing presented ────────────────────────────────────────
rm -f "$PLOG"
if is_in_presented_log "100" "follow-up" "$PLOG"; then
    assert_fail "L1: empty log wrongly reports presented"
else
    assert_pass "L1: missing log → not presented"
fi

# ─── Append + detect ────────────────────────────────────────────────────────
append_presented_log "$PLOG" "100" "follow-up"
if is_in_presented_log "100" "follow-up" "$PLOG"; then
    assert_pass "L2: appended entry detected"
else
    assert_fail "L2: appended entry not detected"
fi

# ─── Different PR not detected ──────────────────────────────────────────────
if is_in_presented_log "999" "follow-up" "$PLOG"; then
    assert_fail "L3: PR #999 wrongly detected"
else
    assert_pass "L3: PR #999 not detected"
fi

# ─── Different phrase on same PR not detected ───────────────────────────────
if is_in_presented_log "100" "out of scope" "$PLOG"; then
    assert_fail "L4: different phrase wrongly detected"
else
    assert_pass "L4: (PR,phrase) granularity preserved"
fi

# ─── Phrase with regex special chars (REGRESSION LOCK) ──────────────────────
append_presented_log "$PLOG" "200" "TODO(followup)"
if is_in_presented_log "200" "TODO(followup)" "$PLOG"; then
    assert_pass "L5 REGRESSION: phrase with parens detected (regex escape)"
else
    assert_fail "L5 REGRESSION: regex metachars broke detection"
fi

# ─── Header bootstrapped ────────────────────────────────────────────────────
assert_contains "L6: header bootstrapped" "$(cat "$PLOG")" "Deferred-backfill presented candidates"

print_test_results
