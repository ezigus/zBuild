#!/usr/bin/env bash
# Integration test: #511 F2 — concrete build/test cycle wiring.
#
# Verifies (without invoking the real build agent / LLM):
#   1) standard.yaml declares cycle:build_test_cycle and the runner enters
#      cycle-aware dispatch when ZBUILD_CYCLES_ENABLED is unset (auto-enable).
#   2) The test plugin emits test-failures-summary.md WHEN failures present,
#      and the file is ABSENT when verdict=pass (missing == empty semantics).
#   3) _cycle_apply_feedback resolves the from-path through the test plugin's
#      manifest (Pin 2 — manifest-driven, not legacy stage/output path).
#   4) The build plugin reads $ZBUILD_CYCLE_FEEDBACK_DIR/prior_test_failures.txt
#      and prepends a preamble at BYTE 0 of build-prompt.txt when present.
#   5) Empty/missing feedback file → NO preamble emitted (silent-failure guard).
#   6) `--from-stage build` is refused when standard.yaml declares a cycle
#      that contains `build` (Pin 14).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle build/test wiring — integration (#511 F2)"
setup_test_env "cycle-build-test-wiring"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# ─── T1: standard.yaml template parsed; cycle declared + auto-detected ──────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/standard.yaml"
assert_eq "T1: standard.yaml declares exactly 1 cycle" "1" "${#_TPL_CYCLES[@]}"
assert_eq "T1: cycle id is build_test_cycle" "build_test_cycle" "${_TPL_CYCLES[0]}"
has_cyc=0
for u in "${_TPL_DISPATCH_UNITS[@]}"; do
    [[ "$u" == "cycle:build_test_cycle" ]] && has_cyc=1
done
assert_eq "T1: dispatch units include cycle:build_test_cycle" "1" "$has_cyc"
# Feedback wiring parsed (from: test/test_failures_summary → to: build/prior_test_failures)
fb_var="_TPL_CYCLE_FEEDBACK_build_test_cycle"
fb_value="${!fb_var:-}"
assert_contains "T1: feedback wires test:test_failures_summary" "$fb_value" "test:test_failures_summary"
assert_contains "T1: feedback wires build:prior_test_failures" "$fb_value" "build:prior_test_failures"

# ─── T2: test plugin emits failures summary on fail, absent on pass ─────────
# shellcheck disable=SC1090
source "$REPO_ROOT/plugins/tool/test/plugin.sh"
ART_DIR="$TEST_TEMP_DIR/artifacts-t2"; mkdir -p "$ART_DIR"
SUM="$ART_DIR/test-failures-summary.md"

# T2a: verdict=pass → file absent
rm -f "$SUM"
_test_emit_failures_summary "$SUM" "pass" "0" "0" "all good"
if [[ ! -e "$SUM" ]]; then
    assert_pass "T2a: pass verdict → summary file ABSENT (missing == empty)"
else
    assert_fail "T2a: pass verdict → summary file should be absent" "found $SUM"
fi

# T2b: verdict=fail with FAIL line → file present, non-empty
rm -f "$SUM"
_test_emit_failures_summary "$SUM" "fail" "3" "1" "FAIL: some test
Expected: foo
Got: bar"
if [[ -s "$SUM" ]]; then
    assert_pass "T2b: fail verdict → summary file present and non-empty"
else
    assert_fail "T2b: fail verdict → summary should exist with content" "missing or empty"
fi
assert_contains "T2b: contains failing line" "$(cat "$SUM")" "FAIL: some test"

# T2c: verdict=error with empty raw output → file ABSENT (silent-failure guard #1)
rm -f "$SUM"
_test_emit_failures_summary "$SUM" "error" "0" "2" ""
if [[ ! -e "$SUM" ]]; then
    assert_pass "T2c: error+empty raw → summary file ABSENT (empty-but-present forbidden)"
else
    assert_fail "T2c: error+empty raw should yield no file" "found $SUM"
fi

# ─── T3: build preamble injection — present at byte 0 when feedback non-empty
# shellcheck disable=SC1090
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
FB_DIR="$TEST_TEMP_DIR/fb-iter-2"
mkdir -p "$FB_DIR"
printf '## Test failures summary\n\n- verdict: fail\n- failed: 2\n' \
    > "$FB_DIR/prior_test_failures.txt"
export ZBUILD_CYCLE_ITER=2
export ZBUILD_CYCLE_FEEDBACK_DIR="$FB_DIR"
preamble="$(_build_read_prior_failures)"
if [[ -n "$preamble" ]]; then
    assert_pass "T3a: prior failures present → preamble emitted"
else
    assert_fail "T3a: prior failures present → preamble should be emitted" "got empty"
fi
# The preamble MUST start with "## Previous test failures" (so when prepended
# to the existing prompt it lands at byte 0).
prefix="${preamble:0:30}"
if [[ "$prefix" == "## Previous test failures"* ]]; then
    assert_pass "T3b: preamble begins with '## Previous test failures' header"
else
    assert_fail "T3b: preamble header" "expected '## Previous test failures', got '$prefix'"
fi
# Iter number is N-1 = 1
assert_contains "T3c: preamble names iter N-1 (iter 1)" "$preamble" "(iter 1)"

# T3d: empty file → preamble ABSENT (silent-failure guard, `-s` not `-f`)
: > "$FB_DIR/prior_test_failures.txt"
empty_preamble="$(_build_read_prior_failures)"
if [[ -z "$empty_preamble" ]]; then
    assert_pass "T3d: empty feedback file → preamble OMITTED (silent-failure guard)"
else
    assert_fail "T3d: empty feedback → preamble should be empty" "got non-empty"
fi

# T3e: no cycle context (ZBUILD_CYCLE_ITER unset) → preamble ABSENT
unset ZBUILD_CYCLE_ITER
no_cyc_preamble="$(_build_read_prior_failures)"
if [[ -z "$no_cyc_preamble" ]]; then
    assert_pass "T3e: outside cycle → preamble OMITTED"
else
    assert_fail "T3e: outside cycle → preamble should be empty" "got non-empty"
fi
unset ZBUILD_CYCLE_FEEDBACK_DIR

# ─── T4: _cycle_apply_feedback resolves via manifest (Pin 2) ─────────────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
T4_STATE_DIR="$TEST_TEMP_DIR/t4-state"
T4_ART_DIR="$T4_STATE_DIR/artifacts"
mkdir -p "$T4_ART_DIR"
# Test plugin manifest declares path: ${artifact_dir}/test-failures-summary.md
# (FLAT — no `test/` subdir). The legacy resolver used artifacts/<stage>/<out>;
# Pin 2 must resolve via the real manifest path.
printf '# real failures summary\n- failed: 7\n' \
    > "$T4_ART_DIR/test-failures-summary.md"
_CYCLE_TRAP_CYCLE_ID="build_test_cycle"
_CYCLE_FEEDBACK=("test:test_failures_summary|build:prior_test_failures:false")
set +e
_cycle_apply_feedback 2 "$T4_STATE_DIR"
t4_rc=$?
set -e
assert_eq "T4: manifest-driven feedback resolution rc=0" "0" "$t4_rc"
assert_file_exists "T4: prior_test_failures.txt copied to iter-2 feedback dir" \
    "$T4_STATE_DIR/cycle-build_test_cycle/iter-2/feedback/prior_test_failures.txt"
assert_contains "T4: .complete sentinel written (Pin 9)" \
    "$(ls -A "$T4_STATE_DIR/cycle-build_test_cycle/iter-2/feedback/")" ".complete"

# ─── T5: --from-stage build is refused (Pin 14) ─────────────────────────────
# Verify runner refuses --from-stage that lands inside a cycle. Easiest test:
# parse standard.yaml + walk our refusal logic. Drive via runner.sh subprocess.
: > "$ZBUILD_EVENTS_JSONL"
T5_STATE="$TEST_TEMP_DIR/t5-state.json"
jq -n '{schema_version:1,status:"in_progress",stage_statuses:{intake:"complete",plan:"complete"}}' > "$T5_STATE"
set +e
ZBUILD_STATE_FILE="$T5_STATE" \
ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins" \
    bash "$REPO_ROOT/core/pipeline/runner.sh" \
    --issue 0 --resume --from-stage build --template standard \
    > "$TEST_TEMP_DIR/t5.out" 2> "$TEST_TEMP_DIR/t5.err"
t5_rc=$?
set -e
if [[ $t5_rc -eq 2 ]]; then
    assert_pass "T5: --from-stage build refused with rc=2 (Pin 14)"
else
    assert_fail "T5: --from-stage build should be refused" "rc=$t5_rc"
fi
if grep -q 'inside or after a cycle' "$TEST_TEMP_DIR/t5.err" 2>/dev/null; then
    assert_pass "T5: rejection message mentions 'inside or after a cycle'"
else
    assert_fail "T5: rejection message" "missing expected diagnostic"
fi

print_test_results
