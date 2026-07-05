#!/usr/bin/env bash
# Tests: byte-exact golden snapshots of the kind=cycle stage-io banner (#833).
#
# Pairs cover layout (NO_COLOR=1, exact bytes, no ANSI) + colored
# (FORCE_COLOR=1 + ZBUILD_STAGE_IO_FORCE_COLOR=1, exact bytes incl ANSI):
#   - cycle-io-input   (INPUT-phase banner: feedback-edge digest)
#   - cycle-io-output  (OUTPUT-phase banner: predicate eval + multi-axis health)
# Determinism env (per ADR-015 §v5/§G):
#   ZBUILD_TERM_WIDTH_OVERRIDE=100, ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
# Goldens regenerate by running this file with ZBUILD_REGEN_GOLDENS=1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOLDEN_DIR="$REPO_ROOT/tests/golden/cycle-banners"

# Force colors populated so the colored variant can emit ANSI.
export FORCE_COLOR=1
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/output/stage-io — kind=cycle banner goldens (#833)"
setup_test_env "stage-io-cycle-kind-goldens"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="goldens-cycle"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

mkdir -p "$GOLDEN_DIR"

# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"
# Cycles have NO io: block — return empty so the kind=cycle dest-override is the
# only path that produces a banner.
template_stage_io_dests()      { printf ''; }
template_stage_io_tail_lines() { printf ''; }
template_stage_io_redact()     { printf ''; }

_reset_pending() {
    local k
    for k in "${!_STAGE_IO_PENDING[@]}";       do unset '_STAGE_IO_PENDING[$k]';       done
    for k in "${!_STAGE_IO_PENDING_INPUT[@]}"; do unset '_STAGE_IO_PENDING_INPUT[$k]'; done
    for k in "${!_STAGE_IO_PENDING_KIND[@]}";  do unset '_STAGE_IO_PENDING_KIND[$k]';  done
    for k in "${!_STAGE_IO_PENDING_DESTS[@]}"; do unset '_STAGE_IO_PENDING_DESTS[$k]'; done
    for k in "${!_STAGE_IO_PENDING_LABEL[@]}"; do unset '_STAGE_IO_PENDING_LABEL[$k]'; done
    for k in "${!_STAGE_IO_START_NS[@]}";      do unset '_STAGE_IO_START_NS[$k]';      done
}

# emit_cycle_banner <mode> <phase>
#   mode: "layout" (NO_COLOR=1) | "colored" (force colors)
#   phase: "input" (begin only) | "output" (begin + end, capture end banner)
# Prints captured banner bytes (fd 3) to stdout.
emit_cycle_banner() {
    local mode="$1" phase="$2"
    local fd_file="$TEST_TEMP_DIR/cyc-banner.$$.fd"
    : > "$fd_file"
    exec 3>"$fd_file"
    local force=0 nocolor=
    [[ "$mode" == "colored" ]] && force=1
    [[ "$mode" == "layout"  ]] && nocolor=1
    _reset_pending
    rm -rf "$ZBUILD_STATE_DIR/artifacts"

    local in_body="prior_test_assessment(fail, 3 changes)"
    local out_body="exit_when stage=test_assessment field=verdict op=eq value=pass → NOT MATCHED (got=fail)
health: progress=186 (3 files, +184/-2) - defects=3 → score=183"

    NO_COLOR="$nocolor" ZBUILD_STAGE_IO_FORCE_COLOR="$force" ZBUILD_STAGE_IO_FD=3 \
    ZBUILD_TERM_WIDTH_OVERRIDE=100 ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
        stage_io_begin --kind cycle --stage build_test_cycle --seq-label "2" \
            --input "$in_body" >/dev/null

    if [[ "$phase" == "output" ]]; then
        # Discard the begin (input) banner so the output golden captures only
        # the output phase. Re-truncate the fd file.
        exec 3>&-
        : > "$fd_file"
        exec 3>"$fd_file"
        NO_COLOR="$nocolor" ZBUILD_STAGE_IO_FORCE_COLOR="$force" ZBUILD_STAGE_IO_FD=3 \
        ZBUILD_TERM_WIDTH_OVERRIDE=100 ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=13345000 \
            stage_io_end --stage build_test_cycle --kind cycle --seq "$_STAGE_IO_LAST_SEQ" \
                --output "$out_body" >/dev/null
    fi

    exec 3>&-
    cat "$fd_file"
    rm -f "$fd_file"
}

# Pair table: <pair_id> <phase>
declare -a PAIRS=(
    "cycle-io-input|input"
    "cycle-io-output|output"
)
declare -a MODES=("layout" "colored")

for spec in "${PAIRS[@]}"; do
    IFS='|' read -r pair phase <<<"$spec"
    for mode in "${MODES[@]}"; do
        golden_file="$GOLDEN_DIR/${pair}.${mode}.txt"
        actual="$(emit_cycle_banner "$mode" "$phase")"

        if [[ "${ZBUILD_REGEN_GOLDENS:-0}" == "1" ]]; then
            printf '%s' "$actual" > "$golden_file"
            assert_pass "REGEN: $(basename "$golden_file") rewritten"
            continue
        fi

        if [[ ! -f "$golden_file" ]]; then
            assert_fail "golden file exists: $(basename "$golden_file")" \
                "missing — re-run with ZBUILD_REGEN_GOLDENS=1"
            continue
        fi
        expected="$(cat "$golden_file")"
        if [[ "$expected" == "$actual" ]]; then
            assert_pass "byte-exact: $(basename "$golden_file")"
        else
            local_diff="$(diff <(printf '%s' "$expected") <(printf '%s' "$actual") | head -20 || true)"
            assert_fail "byte-exact: $(basename "$golden_file")" "diff (first 20 lines):
$local_diff"
        fi
    done
done

cleanup_test_env
print_test_results
exit "$FAIL"
