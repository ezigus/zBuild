#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh — cycle banner helpers (#524, ADR-015 §v6, ADR-021).
#
# Covers four new operator-fd-2 chrome helpers added alongside _render_stage_divider:
#   - _render_cycle_entry <cycle_id> <max> <stages_csv>
#     heavy ═ LIGHT_BLUE divider + ▸ Entering line + DIM trailer
#   - _render_cycle_iter_divider <cycle_id> <iter> <max>
#     light ─ CYAN sub-divider `─── iter N/M ───────`
#   - _render_cycle_iter_complete <iter> <verdict> <score> <failure_count> <elapsed_s>
#     DIM `↳ iter N complete: verdict=X score=Y ...` (#1254: was `velocity=`)
#   - _render_cycle_exit <cycle_id> <reason> <iter> <max>
#     heavy ═ divider + verdict glyph line (✓ converged | ✗ max_iterations/plateau/
#     divergence/blocked | ⚠ aborted/verdict_missing)
#
# Determinism env:
#   ZBUILD_TERM_WIDTH_OVERRIDE=100  ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
# Goldens regen via ZBUILD_REGEN_GOLDENS=1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOLDEN_DIR="$REPO_ROOT/tests/golden/cycle-banners"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/runner — cycle banner helpers (#524)"
setup_test_env "runner-cycle-banners"

mkdir -p "$GOLDEN_DIR"

# emit_cycle_banner <mode> <variant>
# Runs in a clean subshell so helpers.sh re-initializes color palette under
# NO_COLOR=1 (layout) or FORCE_COLOR=1 (colored).
emit_cycle_banner() {
    local mode="$1" variant="$2"
    local env_pre=""
    if [[ "$mode" == "layout" ]]; then
        env_pre="unset FORCE_COLOR; export NO_COLOR=1"
    else
        env_pre="unset NO_COLOR; export FORCE_COLOR=1"
    fi

    bash -c "
        $env_pre
        export ZBUILD_TERM_WIDTH_OVERRIDE=100
        export ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
        export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/state'
        export ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/events'
        export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/events/events.jsonl'
        mkdir -p \"\$ZBUILD_STATE_DIR\" \"\$ZBUILD_EVENTS_DIR\"
        source '$REPO_ROOT/core/pipeline/runner.sh'

        case '$variant' in
            entry-build-test)
                _render_cycle_entry build-test 5 'build,test'
                ;;
            iter-divider-2-5)
                _render_cycle_iter_divider build-test 2 5
                ;;
            iter-divider-2-5-nested)
                ZBUILD_SEQ_PREFIX='4.1' _render_cycle_iter_divider build-test 2 5
                ;;
            iter-complete-pass)
                _render_cycle_iter_complete 2 pass -1 1 4
                ;;
            exit-converged)
                _render_cycle_exit build-test converged 2 5
                ;;
            exit-max-iterations)
                _render_cycle_exit build-test max_iterations 5 5
                ;;
            exit-plateau)
                _render_cycle_exit build-test plateau 3 5
                ;;
            exit-divergence)
                _render_cycle_exit build-test divergence 3 5
                ;;
            exit-aborted)
                _render_cycle_exit build-test aborted 2 5
                ;;
            exit-verdict-missing)
                _render_cycle_exit build-test verdict_missing 2 5
                ;;
            exit-blocked)
                _render_cycle_exit build-test blocked 2 5
                ;;
            exit-error)
                _render_cycle_exit build-test error 2 5
                ;;
            exit-config-invalid)
                _render_cycle_exit build-test config_invalid 0 5
                ;;
            exit-unknown)
                _render_cycle_exit build-test some_typo_reason 2 5
                ;;
        esac
    " 2>&1
}

# Pair table: variant
declare -a VARIANTS=(
    "entry-build-test"
    "iter-divider-2-5"
    "iter-divider-2-5-nested"
    "iter-complete-pass"
    "exit-converged"
    "exit-max-iterations"
    "exit-plateau"
    "exit-divergence"
    "exit-aborted"
    "exit-verdict-missing"
    "exit-blocked"
    "exit-error"
    "exit-config-invalid"
    "exit-unknown"
)
declare -a MODES=("layout" "colored")

for variant in "${VARIANTS[@]}"; do
    for mode in "${MODES[@]}"; do
        golden_file="$GOLDEN_DIR/${variant}.${mode}.txt"
        actual="$(emit_cycle_banner "$mode" "$variant" || true)"

        if [[ "${ZBUILD_REGEN_GOLDENS:-0}" == "1" ]]; then
            printf '%s' "$actual" > "$golden_file"
            assert_pass "REGEN: $(basename "$golden_file") rewritten"
            continue
        fi

        if [[ ! -f "$golden_file" ]]; then
            assert_fail "$(basename "$golden_file") missing" \
                "run with ZBUILD_REGEN_GOLDENS=1 to create"
            continue
        fi

        expected="$(cat "$golden_file")"
        if [[ "$actual" == "$expected" ]]; then
            assert_pass "byte-exact match: $(basename "$golden_file")"
        else
            assert_fail "byte-exact match: $(basename "$golden_file")" \
                "diff (see ZBUILD_REGEN_GOLDENS=1 to regen)"
            diff <(printf '%s' "$expected") <(printf '%s' "$actual") || true
        fi
    done
done

# ── Behavior tests (not golden-driven) ────────────────────────────────────────

# B1: NO_COLOR strips ANSI but keeps glyphs/text intact (verdict glyph survives).
out="$(emit_cycle_banner layout exit-converged || true)"
if [[ "$out" == *"converged"* && "$out" == *"✓"* && "$out" != *$'\033'* ]]; then
    assert_pass "B1: NO_COLOR strips ANSI; glyph + reason text preserved"
else
    assert_fail "B1: NO_COLOR strip" "got: $out"
fi

# B2: Narrow terminal degrade — width=20 → no crash, banner still emitted.
out="$(
    bash -c "
        unset FORCE_COLOR; export NO_COLOR=1
        export ZBUILD_TERM_WIDTH_OVERRIDE=20
        export ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
        export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/state'
        export ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/events'
        export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/events/events.jsonl'
        mkdir -p \"\$ZBUILD_STATE_DIR\" \"\$ZBUILD_EVENTS_DIR\"
        source '$REPO_ROOT/core/pipeline/runner.sh'
        _render_cycle_entry build-test 5 'build,test' 2>&1
    " || true
)"
if [[ -n "$out" && "$out" == *"build-test"* ]]; then
    assert_pass "B2: narrow terminal (w=20) degrades cleanly, banner still has cycle_id"
else
    assert_fail "B2: narrow degrade" "got: $out"
fi

# B3: All four helpers write to fd 2 (stderr) — fd 1 must be empty.
stdout_capture="$(
    bash -c "
        unset FORCE_COLOR; export NO_COLOR=1
        export ZBUILD_TERM_WIDTH_OVERRIDE=100
        export ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
        export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/state'
        export ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/events'
        export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/events/events.jsonl'
        mkdir -p \"\$ZBUILD_STATE_DIR\" \"\$ZBUILD_EVENTS_DIR\"
        source '$REPO_ROOT/core/pipeline/runner.sh'
        _render_cycle_entry build-test 5 'build,test'
        _render_cycle_iter_divider build-test 1 5
        _render_cycle_iter_complete 1 pass 0 0 1
        _render_cycle_exit build-test converged 1 5
    " 2>/dev/null || true
)"
if [[ -z "$stdout_capture" ]]; then
    assert_pass "B3: all 4 helpers write to fd 2 only (fd 1 empty)"
else
    assert_fail "B3: fd 1 leakage" "stdout was: $stdout_capture"
fi

# B4: Exit banner reason→glyph mapping invariants (colored mode).
verify_glyph() {
    local reason="$1" expect_glyph="$2" label="$3"
    local got
    got="$(emit_cycle_banner colored "exit-$reason" || true)"
    if [[ "$got" == *"$expect_glyph"* ]]; then
        assert_pass "B4: $label → '$expect_glyph' present"
    else
        assert_fail "B4: $label → '$expect_glyph'" "got: $got"
    fi
}
verify_glyph "converged" "✓" "converged"
verify_glyph "max-iterations" "✗" "max_iterations"
verify_glyph "plateau" "✗" "plateau"
verify_glyph "divergence" "✗" "divergence"
verify_glyph "aborted" "⚠" "aborted"
verify_glyph "verdict-missing" "⚠" "verdict_missing"
verify_glyph "blocked" "✗" "blocked"
verify_glyph "error" "✗" "error/default"

cleanup_test_env
print_test_results
exit "$FAIL"
