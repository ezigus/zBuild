#!/usr/bin/env bash
# Unit: _render_cycle_iter_divider surfaces cycle_id and (when nested)
# ZBUILD_SEQ_PREFIX so operators can tell which outer iter the inner
# divider belongs to (#832).
#
#   outer (no prefix): `─── build_review_cycle iter 1/2 ───`
#   inner (prefix set): `─── [4.1] build_test_cycle iter 1/3 ───`
#
# Reuses ZBUILD_SEQ_PREFIX from Wave 19-B #718 (set by cycle-orchestrator
# at member-stage dispatch); no hook-signature change.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: hierarchical iter divider (#832)"
setup_test_env "runner-iter-divider-hierarchical-832"

export ZBUILD_TERM_WIDTH_OVERRIDE=120
unset FORCE_COLOR
export NO_COLOR=1

# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"

# ─── T1: outer cycle (no ZBUILD_SEQ_PREFIX) → cycle_id present, no chip ──
OUT1="$TEST_TEMP_DIR/outer.stderr"
unset ZBUILD_SEQ_PREFIX
_render_cycle_iter_divider build_review_cycle 1 2 2> "$OUT1"
if grep -q 'build_review_cycle iter 1/2' "$OUT1"; then
    assert_pass "T1: outer divider contains 'build_review_cycle iter 1/2'"
else
    assert_fail "T1: outer divider missing cycle_id+iter" "got: $(cat "$OUT1")"
fi
if grep -q '\[' "$OUT1"; then
    assert_fail "T1: outer divider should NOT contain '[' (no prefix chip)" \
        "got: $(cat "$OUT1")"
else
    assert_pass "T1: outer divider has no '[<prefix>]' chip"
fi

# ─── T2: inner cycle (ZBUILD_SEQ_PREFIX=4.1) → chip + cycle_id present ──
OUT2="$TEST_TEMP_DIR/inner.stderr"
ZBUILD_SEQ_PREFIX='4.1' _render_cycle_iter_divider build_test_cycle 2 3 2> "$OUT2"
if grep -q '\[4\.1\] build_test_cycle iter 2/3' "$OUT2"; then
    assert_pass "T2: inner divider has '[4.1] build_test_cycle iter 2/3'"
else
    assert_fail "T2: inner divider shape wrong" "got: $(cat "$OUT2")"
fi

# ─── T3: deeper nesting (ZBUILD_SEQ_PREFIX=4.1.1.2) ─────────────────────
OUT3="$TEST_TEMP_DIR/deeper.stderr"
ZBUILD_SEQ_PREFIX='4.1.1.2' _render_cycle_iter_divider sub_cycle 1 5 2> "$OUT3"
if grep -q '\[4\.1\.1\.2\] sub_cycle iter 1/5' "$OUT3"; then
    assert_pass "T3: 4-level prefix surfaced verbatim"
else
    assert_fail "T3: deep prefix not rendered" "got: $(cat "$OUT3")"
fi

# ─── T4: hook arity unchanged (3 args), back-compat with callers ─────────
# The orchestrator at cycle-orchestrator.sh:1285 calls
# cycle_iter_begin_hook with 3 args; runner registers the hook to call
# _render_cycle_iter_divider with those 3 args verbatim. This PR adds NO
# new args — the seq prefix is read from the env. Lock in the arity.
OUT4="$TEST_TEMP_DIR/arity.stderr"
unset ZBUILD_SEQ_PREFIX
# Should succeed with exactly 3 args (no extra args needed).
if _render_cycle_iter_divider any_cycle 1 1 2> "$OUT4"; then
    assert_pass "T4: 3-arg call still works (no hook-signature change)"
else
    assert_fail "T4: 3-arg call rejected" "rc=$?; got: $(cat "$OUT4")"
fi

# ─── T5: empty ZBUILD_SEQ_PREFIX (set but empty) treated as outer ───────
OUT5="$TEST_TEMP_DIR/emptyprefix.stderr"
ZBUILD_SEQ_PREFIX='' _render_cycle_iter_divider design_impact_cycle 3 5 2> "$OUT5"
if grep -qF 'design_impact_cycle iter 3/5' "$OUT5" && ! grep -qF '[]' "$OUT5"; then
    assert_pass "T5: empty seq prefix → no empty '[]' chip, just cycle_id"
else
    assert_fail "T5: empty prefix renders incorrectly" "got: $(cat "$OUT5")"
fi

# ─── T6: narrow terminal degrade — bar still padded to ≥2 chars ─────────
OUT6="$TEST_TEMP_DIR/narrow.stderr"
ZBUILD_TERM_WIDTH_OVERRIDE=10 _render_cycle_iter_divider deep_cycle_with_long_id 99 99 2> "$OUT6"
if grep -q 'deep_cycle_with_long_id iter 99/99' "$OUT6"; then
    assert_pass "T6: narrow terminal (w=10) still emits full label"
else
    assert_fail "T6: narrow degrade dropped label" "got: $(cat "$OUT6")"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
