#!/usr/bin/env bash
# Unit: #752 follow-up — the tmpdir pattern list must have a single source
# of truth shared by the scanner and the apply step. The list drifted twice
# (#628 added zb-loop-iters.* to the scanner only; #749 added zb-test-auto.*
# and zb-test.* to the scanner only), each time making `--apply` a silent
# no-op for the new patterns while dry-run looked correct.
#
# These tests derive their fixtures from ZBUILD_TMPDIR_PATTERNS itself, so
# any pattern added to the array in the future is covered automatically —
# a scan/apply gap can no longer ship unnoticed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/cleanup.sh
source "$REPO_ROOT/scripts/lib/cleanup.sh"
print_test_header "tmpdir patterns: single source of truth for scan + apply (#752)"
setup_test_env "cleanup-tmpdir-patterns"
_test_cleanup_hook() { cleanup_test_env; }

SYNTH_TMP="$TEST_TEMP_DIR/synth-tmp"
mkdir -p "$SYNTH_TMP"

local_backdate() {
    local p="$1"
    local stamp
    stamp="$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M 2>/dev/null)"
    [[ -n "$stamp" ]] && touch -t "$stamp" "$p" 2>/dev/null || true
}

print_test_section "pattern list is a non-empty array"

pattern_count=0
if declare -p ZBUILD_TMPDIR_PATTERNS 2>/dev/null | grep -q 'declare -a'; then
    assert_pass "T1: ZBUILD_TMPDIR_PATTERNS is an array"
    pattern_count="${#ZBUILD_TMPDIR_PATTERNS[@]}"
else
    assert_fail "T1: ZBUILD_TMPDIR_PATTERNS must be an array in cleanup.sh" \
        "$(declare -p ZBUILD_TMPDIR_PATTERNS 2>&1 || echo 'not declared')"
fi

if [[ "$pattern_count" -ge 1 ]]; then
    assert_pass "T2: pattern list is non-empty ($pattern_count patterns)"
else
    assert_fail "T2: pattern list must be non-empty" "empty or undeclared"
fi

print_test_section "every pattern in the array round-trips scan -> apply"

# One fixture dir per pattern, name derived from the pattern itself.
for pattern in "${ZBUILD_TMPDIR_PATTERNS[@]}"; do
    fixture="${pattern//\*/FIXTURE}"
    mkdir -p "$SYNTH_TMP/$fixture"
    local_backdate "$SYNTH_TMP/$fixture"
done
# Negative control — must survive both scan and apply.
mkdir -p "$SYNTH_TMP/unrelated.SAFE"
local_backdate "$SYNTH_TMP/unrelated.SAFE"

# Subshell-scoped TMPDIR so we never scan the real one.
plan="$(TMPDIR="$SYNTH_TMP" _cleanup_scan_zbuild_tmpdirs 24 2>/dev/null || true)"

for pattern in "${ZBUILD_TMPDIR_PATTERNS[@]}"; do
    fixture="${pattern//\*/FIXTURE}"
    if grep -qF "$SYNTH_TMP/$fixture" <<<"$plan"; then
        assert_pass "T3[$pattern]: scanner emits fixture"
    else
        assert_fail "T3[$pattern]: scanner must emit fixture" "plan: $plan"
    fi
done

_cleanup_apply_tmpdir_plan "$plan" "false"

for pattern in "${ZBUILD_TMPDIR_PATTERNS[@]}"; do
    fixture="${pattern//\*/FIXTURE}"
    if [[ ! -d "$SYNTH_TMP/$fixture" ]]; then
        assert_pass "T4[$pattern]: apply reclaims fixture"
    else
        assert_fail "T4[$pattern]: apply must reclaim fixture" "still present"
    fi
done

if [[ -d "$SYNTH_TMP/unrelated.SAFE" ]]; then
    assert_pass "T5: negative control survives apply"
else
    assert_fail "T5: negative control must survive apply" "deleted"
fi

print_test_section "apply re-validates targets (defence in depth)"

# A plan line pointing at a non-whitelisted dir must be refused even if it
# somehow reaches the applier (e.g. a future scanner bug or injected plan).
mkdir -p "$SYNTH_TMP/evil-dir.INJECTED"
forged_plan="$(printf '%s\tprune\tpattern=forged age=99h\n' "$SYNTH_TMP/evil-dir.INJECTED")"
_cleanup_apply_tmpdir_plan "$forged_plan" "false"
if [[ -d "$SYNTH_TMP/evil-dir.INJECTED" ]]; then
    assert_pass "T6: non-whitelisted plan line is refused"
else
    assert_fail "T6: applier must refuse non-whitelisted targets" "deleted forged target"
fi

print_test_section "dry-run applies nothing"

first_pattern="${ZBUILD_TMPDIR_PATTERNS[0]}"
dry_fixture="${first_pattern//\*/DRYRUN}"
mkdir -p "$SYNTH_TMP/$dry_fixture"
local_backdate "$SYNTH_TMP/$dry_fixture"
dry_plan="$(TMPDIR="$SYNTH_TMP" _cleanup_scan_zbuild_tmpdirs 24 2>/dev/null || true)"
_cleanup_apply_tmpdir_plan "$dry_plan" "true"
if [[ -d "$SYNTH_TMP/$dry_fixture" ]]; then
    assert_pass "T7: dry-run leaves matching dirs in place"
else
    assert_fail "T7: dry-run must not delete" "deleted $dry_fixture"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
