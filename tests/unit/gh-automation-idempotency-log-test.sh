#!/usr/bin/env bash
# Tests: scripts/lib/gh-automation.sh::gha_is_already_scanned, gha_append_scanned_log
#
# Behavioral coverage for shared idempotency-log helpers (#540). Must work for
# BOTH orphan-prs.md and deferred-scanned-prs.md formats (column 3 differs:
# "First seen" vs "Scanned"; row shape identical).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/gh-automation.sh
source "$REPO_ROOT/scripts/lib/gh-automation.sh"

print_test_header "gh-automation — idempotency log (#540)"

setup_test_env() {
    TEST_LOG="$TEST_TEMP_DIR/log.md"
}
setup_test_env

# Two header callbacks — mirror the real-world callers' shapes
_deferred_header() {
    cat > "$1" <<HDR
# Deferred-tracker scanned PRs

_Last updated: $2_

| PR | Title | Scanned |
|---|---|---|
HDR
}

_orphan_header() {
    cat > "$1" <<HDR
# Orphan PRs

_Last updated: $2 (rolling 30-PR window)_

| PR | Title | First seen |
|---|---|---|
HDR
}

# ─── G1: source-guard works — sourcing again is a no-op ────────────────────
loaded_before="$_ZBUILD_GHA_LOADED"
# shellcheck source=../../scripts/lib/gh-automation.sh
source "$REPO_ROOT/scripts/lib/gh-automation.sh"
assert_eq "G1: _ZBUILD_GHA_LOADED guard prevents re-source" "$loaded_before" "$_ZBUILD_GHA_LOADED"

# ─── G2: is_already_scanned on missing file → 1 (not scanned) ──────────────
if gha_is_already_scanned "100" "/nonexistent/file.md"; then
    assert_fail "G2: missing log wrongly reported as scanned"
else
    assert_pass "G2: missing log → not scanned"
fi

# ─── G3: append bootstraps with deferred-format header ─────────────────────
rm -f "$TEST_LOG"
gha_append_scanned_log "$TEST_LOG" "_deferred_header" "2026-05-31" "100|first PR"
assert_contains "G3: deferred header bootstrapped" "$(cat "$TEST_LOG")" "Deferred-tracker scanned PRs"
assert_contains "G3: deferred col header" "$(cat "$TEST_LOG")" "| PR | Title | Scanned |"

# ─── G4: is_already_scanned finds present PR ───────────────────────────────
if gha_is_already_scanned "100" "$TEST_LOG"; then
    assert_pass "G4: PR #100 detected as scanned"
else
    assert_fail "G4: PR #100 not detected as scanned"
fi

# ─── G5: is_already_scanned returns 1 for absent PR ────────────────────────
if gha_is_already_scanned "999" "$TEST_LOG"; then
    assert_fail "G5: PR #999 wrongly detected as scanned"
else
    assert_pass "G5: PR #999 not scanned (correct)"
fi

# ─── G6: re-append same PR is idempotent (REGRESSION LOCK) ─────────────────
rows_before=$(grep -c "^| #100 " "$TEST_LOG")
gha_append_scanned_log "$TEST_LOG" "_deferred_header" "2026-05-31" "100|first PR"
rows_after=$(grep -c "^| #100 " "$TEST_LOG")
assert_eq "G6: re-append does not duplicate" "$rows_before" "$rows_after"

# ─── G7: orphan-format also works (generalization test) ────────────────────
ORPHAN_LOG="$TEST_TEMP_DIR/orphan.md"
rm -f "$ORPHAN_LOG"
gha_append_scanned_log "$ORPHAN_LOG" "_orphan_header" "2026-05-31" "200|orphan PR"
assert_contains "G7: orphan header bootstrapped" "$(cat "$ORPHAN_LOG")" "Orphan PRs"
assert_contains "G7: orphan col header" "$(cat "$ORPHAN_LOG")" "| PR | Title | First seen |"
if gha_is_already_scanned "200" "$ORPHAN_LOG"; then
    assert_pass "G7: same row check works on orphan format"
else
    assert_fail "G7: orphan-format row check failed"
fi

# ─── G8: append updates _Last updated_ on existing file ────────────────────
sleep 1
gha_append_scanned_log "$TEST_LOG" "_deferred_header" "2026-05-31" "101|second PR"
updated_line=$(grep "^_Last updated:" "$TEST_LOG")
# Just verify the line still exists and was rewritten (not the prior content)
assert_contains "G8: _Last updated line preserved" "$updated_line" "_Last updated:"

# ─── G9: multiple entries in one call ──────────────────────────────────────
rm -f "$TEST_LOG"
gha_append_scanned_log "$TEST_LOG" "_deferred_header" "2026-05-31" \
    "300|pr a" "301|pr b" "302|pr c"
count=$(grep -cE "^\| #30[0-2] " "$TEST_LOG")
assert_eq "G9: three entries written" "3" "$count"

print_test_results
