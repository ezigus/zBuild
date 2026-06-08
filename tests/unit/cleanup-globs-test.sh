#!/usr/bin/env bash
# Unit: Wave 19-L (#749) — _cleanup_scan_zbuild_tmpdirs must sweep the two
# patterns currently missing from its glob list, which collectively account
# for the 1,261-dir / ~13GB leak found during issue 12 dogfood (2026-06-08).
#
# Missing patterns:
#   - zb-test-auto.*  (test-helpers.sh line 46 — auto-init temp dir)
#   - zb-test.*       (default when setup_test_env called with no name)
#
# These are the actual filesystem-name shapes the test harness produces.
# Without sweeping them, `zbuild cleanup --apply` cannot reclaim the leak.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/cleanup.sh
source "$REPO_ROOT/scripts/lib/cleanup.sh"
print_test_header "_cleanup_scan_zbuild_tmpdirs sweeps test-leak patterns (Wave 19-L, #749)"
setup_test_env "cleanup-globs"
_test_cleanup_hook() { cleanup_test_env; }

# Use TEST_TEMP_DIR as a synthetic TMPDIR so we don't touch the real one.
SYNTH_TMP="$TEST_TEMP_DIR/synth-tmp"
mkdir -p "$SYNTH_TMP"

# Create three test-stage dirs — two that the current glob MISSES and one
# that it catches (regression guard).
mkdir -p "$SYNTH_TMP/zb-test-auto.ABC123"
mkdir -p "$SYNTH_TMP/zb-test.XYZ789"
mkdir -p "$SYNTH_TMP/zbuild-test-stage.OLD000"

# Backdate them all so age-cutoff lets them through (default cutoff 24h).
# Use touch -t with 2 days ago.
local_backdate() {
    local p="$1"
    # macOS + GNU touch both accept -t YYYYMMDDhhmm.
    local stamp
    stamp="$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M 2>/dev/null)"
    [[ -n "$stamp" ]] && touch -t "$stamp" "$p" 2>/dev/null || true
}
local_backdate "$SYNTH_TMP/zb-test-auto.ABC123"
local_backdate "$SYNTH_TMP/zb-test.XYZ789"
local_backdate "$SYNTH_TMP/zbuild-test-stage.OLD000"

# Also create a dir that must NOT be swept (negative control).
mkdir -p "$SYNTH_TMP/unrelated-dir.NOTOURS"
local_backdate "$SYNTH_TMP/unrelated-dir.NOTOURS"

print_test_section "scanner emits prune lines for all three leak patterns"

# Scope TMPDIR to the subshell only — bare `TMPDIR=… out=…` would persist
# TMPDIR for the rest of the script (Copilot review #751). Subshell isolates.
out="$(TMPDIR="$SYNTH_TMP" _cleanup_scan_zbuild_tmpdirs 24 2>/dev/null || true)"

if grep -q "zb-test-auto.ABC123" <<<"$out"; then
    assert_pass "T1: scanner finds zb-test-auto.* pattern"
else
    assert_fail "T1: scanner must find zb-test-auto.* pattern" "output: $out"
fi

if grep -q "zb-test.XYZ789" <<<"$out"; then
    assert_pass "T2: scanner finds zb-test.* pattern"
else
    assert_fail "T2: scanner must find zb-test.* pattern" "output: $out"
fi

if grep -q "zbuild-test-stage.OLD000" <<<"$out"; then
    assert_pass "T3: scanner still finds zbuild-test-stage.* pattern (regression guard)"
else
    assert_fail "T3: scanner must still find zbuild-test-stage.* pattern" "output: $out"
fi

if grep -q "unrelated-dir.NOTOURS" <<<"$out"; then
    assert_fail "T4: scanner must NOT sweep unrelated dirs" "output: $out"
else
    assert_pass "T4: scanner does not sweep unrelated dirs (negative control)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
