#!/usr/bin/env bash
# Integration test: #511 F2 — concrete build/test cycle wiring.
#
# Verifies (without invoking the real build agent / LLM):
#   1) simple.yaml declares cycle:build_test_cycle and the runner enters
#      cycle-aware dispatch when ZBUILD_CYCLES_ENABLED is unset (auto-enable).
#      (#979: re-pointed from the retired standard.yaml to the shipped default
#      simple.yaml, which carries the same inner build_test_cycle.)
#   2) The test plugin emits test-failures-summary.md WHEN failures present,
#      and the file is ABSENT when verdict=pass (missing == empty semantics).
#   3) _cycle_apply_feedback resolves the from-path through the test plugin's
#      manifest (Pin 2 — manifest-driven, not legacy stage/output path).
#   4) The build plugin reads $ZBUILD_CYCLE_FEEDBACK_DIR/prior_test_failures.txt
#      and prepends a preamble at BYTE 0 of build-prompt.txt when present.
#   5) Empty/missing feedback file → NO preamble emitted (silent-failure guard).
#   6) `--from-stage build` is refused when simple.yaml declares a cycle
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

# ─── T1: simple.yaml template parsed; cycle declared + auto-detected ────────
# #979: standard.yaml retired. simple.yaml (the shipped default) declares 2
# cycles — design_verify_cycle (ADR-046) and the inner build_test_cycle (this
# test's focus). Its build_test_cycle converges on gate-aggregator and wires the
# consolidated gate feedback (gate-aggregator:gate_feedback → build) — the
# composable-gate successor to standard's test_assessment feedback edge.
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml"
assert_eq "T1: simple.yaml declares 2 cycles (design_verify + inner build_test)" \
    "2" "${#_TPL_CYCLES[@]}"
has_inner=0
for c in "${_TPL_CYCLES[@]}"; do
    [[ "$c" == "build_test_cycle" ]] && has_inner=1
done
assert_eq "T1: inner build_test_cycle is registered" "1" "$has_inner"
# build_test_cycle is a top-level dispatch unit; design_verify_cycle precedes it.
has_cyc=0
has_design_verify=0
for u in "${_TPL_DISPATCH_UNITS[@]}"; do
    [[ "$u" == "cycle:build_test_cycle" ]] && has_cyc=1
    [[ "$u" == "cycle:design_verify_cycle" ]] && has_design_verify=1
done
assert_eq "T1: dispatch units include cycle:build_test_cycle" \
    "1" "$has_cyc"
assert_eq "T1: dispatch units include cycle:design_verify_cycle (ADR-046)" \
    "1" "$has_design_verify"
# ADR-040 (#1138): the inner cycle's feedback edge is now the consolidated
# gate-aggregator payload (gate-aggregator:gate_feedback → build:gate_feedback)
# — the composable-gate successor to standard's test_assessment feedback.
fb_var="_TPL_CYCLE_FEEDBACK_build_test_cycle"
fb_value="${!fb_var:-}"
assert_contains "T1: feedback wires gate-aggregator:gate_feedback" "$fb_value" "gate-aggregator:gate_feedback"
assert_contains "T1: feedback wires build:gate_feedback" "$fb_value" "build:gate_feedback"

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

# ─── T3: build feedback section — present when prior_test_assessment non-empty
# (#571 renamed _build_read_prior_failures → _build_read_prior_assessment;
# file: prior_test_failures.txt → prior_test_assessment.txt to match #568.)
# shellcheck disable=SC1090
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
FB_DIR="$TEST_TEMP_DIR/fb-iter-2"
mkdir -p "$FB_DIR"
printf '## Test assessment\n\n- verdict: fail\n- failed: 2\n' \
    > "$FB_DIR/prior_test_assessment.txt"
export ZBUILD_CYCLE_ITER=2
export ZBUILD_CYCLE_FEEDBACK_DIR="$FB_DIR"
assessment_body="$(_build_read_prior_assessment)"
if [[ -n "$assessment_body" ]]; then
    assert_pass "T3a: prior assessment present → body returned"
else
    assert_fail "T3a: prior assessment present → body should be returned" "got empty"
fi
# Body is returned RAW (the framing wraps it with the CURRENT ITERATION
# FEEDBACK header in _build_stage_run_inner — see #571 prompt v2 framing).
assert_contains "T3b: returned body contains the assessment content" \
    "$assessment_body" "verdict: fail"

# T3d: empty file → body ABSENT (silent-failure guard, `-s` not `-f`)
: > "$FB_DIR/prior_test_assessment.txt"
empty_body="$(_build_read_prior_assessment)"
if [[ -z "$empty_body" ]]; then
    assert_pass "T3d: empty feedback file → body OMITTED (silent-failure guard)"
else
    assert_fail "T3d: empty feedback → body should be empty" "got non-empty"
fi

# T3e: no cycle context (ZBUILD_CYCLE_ITER unset) → body ABSENT
unset ZBUILD_CYCLE_ITER
no_cyc_body="$(_build_read_prior_assessment)"
if [[ -z "$no_cyc_body" ]]; then
    assert_pass "T3e: outside cycle → body OMITTED"
else
    assert_fail "T3e: outside cycle → body should be empty" "got non-empty"
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
# parse simple.yaml + walk our refusal logic. Drive via runner.sh subprocess.
# (#979: re-pointed from standard → simple; build lives inside simple.yaml's
# build_test_cycle, so the same Pin-14 refusal applies.)
: > "$ZBUILD_EVENTS_JSONL"
T5_STATE="$TEST_TEMP_DIR/t5-state.json"
jq -n '{schema_version:1,status:"in_progress",stage_statuses:{intake:"complete",plan:"complete"}}' > "$T5_STATE"
set +e
ZBUILD_STATE_FILE="$T5_STATE" \
ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins" \
    bash "$REPO_ROOT/core/pipeline/runner.sh" \
    --issue 0 --resume --from-stage build --template simple \
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

# NB (#979): the former T6 asserted that the retired standard.yaml's outer
# build_review_cycle dispatched its `review` member on an unconverged inner
# cycle (ADR-026 / Wave 18-B #707). simple.yaml has no build_review_cycle and no
# `review` stage (its post-cycle review is the ADVISORY review_lenses group +
# review-aggregator, never a merge-blocking container). That review-on-unconverged
# container semantic no longer exists, so T6 was removed with the lattice.

# ─── T6 (#1757): a MIXED gate failure reaches build across the real seam ─────
# Unit coverage pins the aggregator's two payloads; this walks the whole chain
# the #1831 run walked and found broken end-to-end: real gate_aggregator_run →
# real _cycle_apply_feedback (manifest-driven, gate-aggregator:gate_feedback →
# build:gate_feedback) → real _build_read_prior_gate. Before #1757 the chain
# produced an EMPTY body whenever any gate carried a route_target, and build
# was handed a prompt with no failure section at all.
# shellcheck disable=SC1090
source "$REPO_ROOT/plugins/tool/gate-aggregator/plugin.sh"

T6_STATE_DIR="$TEST_TEMP_DIR/t6-state"
T6_ART_DIR="$T6_STATE_DIR/artifacts"
mkdir -p "$T6_ART_DIR"
for _g in test-results shape-floor-result acceptance-gate-result lint-result \
          coverage-result mutation-result secret-scan-result; do
    printf '{"verdict":"pass"}\n' > "$T6_ART_DIR/$_g.json"
done
# shape-floor escalates to design; the suite and the tautology are build-fixable.
printf '{"verdict":"fail","reason":"missing_floor_files","route_target":"design"}\n' \
    > "$T6_ART_DIR/shape-floor-result.json"
printf '{"verdict":"fail","disposition":"recoverable","failures":["tautology:SPEC-1"]}\n' \
    > "$T6_ART_DIR/acceptance-gate-result.json"
printf '{"verdict":"fail","test_output":"FAIL tests/unit/sigpipe-antipattern-guard-test.sh"}\n' \
    > "$T6_ART_DIR/test-results.json"

gate_aggregator_run "gate-aggregator" "$T6_STATE_DIR/state.json" >/dev/null 2>&1 || true

assert_json_key "T6: mixed failure set still routes to design" \
    "$(cat "$T6_ART_DIR/gate-aggregator-result.json")" '.verdict' "route_design"
assert_file_exists "T6: aggregator wrote the build-facing gate-feedback.md" \
    "$T6_ART_DIR/gate-feedback.md"

_CYCLE_TRAP_CYCLE_ID="build_test_cycle"
_CYCLE_FEEDBACK=("gate-aggregator:gate_feedback|build:gate_feedback:false")
set +e
_cycle_apply_feedback 3 "$T6_STATE_DIR"
t6_rc=$?
set -e
assert_eq "T6: feedback edge applied rc=0" "0" "$t6_rc"

T6_FB="$T6_STATE_DIR/cycle-build_test_cycle/iter-3/feedback"
assert_file_exists "T6: gate_feedback.txt staged into the iter feedback dir" \
    "$T6_FB/gate_feedback.txt"

ZBUILD_CYCLE_ITER=3 ZBUILD_CYCLE_FEEDBACK_DIR="$T6_FB" \
    _build_read_prior_gate > "$TEST_TEMP_DIR/t6-body.txt" 2>/dev/null || true
T6_BODY="$(cat "$TEST_TEMP_DIR/t6-body.txt")"

assert_gt "T6: build reads a NON-EMPTY prior-gate body (the #1831 regression)" \
    "${#T6_BODY}" "0"
assert_contains "T6: body carries the failing suite" \
    "$T6_BODY" "sigpipe-antipattern-guard-test.sh"
assert_contains "T6: body carries the tautology build must re-author" \
    "$T6_BODY" "tautology:SPEC-1"
assert_contains "T6: body names the design-routed gate as handled elsewhere" \
    "$T6_BODY" "Handled elsewhere"

print_test_results
