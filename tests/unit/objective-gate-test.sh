#!/usr/bin/env bash
# Tests: plugins/tool/objective-gate/plugin.sh (issue #969, EPIC #966 I3)
# ADR-037 §1 (objective gate layer), ADR-013 (T0 tool, no LLM)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/objective-gate — suite-green + lint hard-gate (#969)"
setup_test_env "objective-gate"

_test_cleanup_hook() { cleanup_test_env; }

_PLUGIN_SH="$REPO_ROOT/plugins/tool/objective-gate/plugin.sh"

# ─── SPEC-1: plugin.sh sources without error ─────────────────────────────────
# CHANGE: file absent at merge-base → source fails. Now it must source cleanly.

set +e
# shellcheck source=../../plugins/tool/objective-gate/plugin.sh
source "$_PLUGIN_SH"
_spec1_rc=$?
set -e

assert_eq "[SPEC-1] plugin.sh sources without error (exit 0)" "0" "$_spec1_rc"

# ─── Shared test fixture ──────────────────────────────────────────────────────

# Use the harness-managed TEST_TEMP_DIR (setup_test_env) for fixtures so the
# harness EXIT trap (_test_cleanup_hook / tracked-tmpdir cleanup) is preserved
# — a custom `trap … EXIT` here would clobber it. (#998 review)
_tmpdir="$TEST_TEMP_DIR"
_state_file="$_tmpdir/state.json"
_artifacts_dir="$_tmpdir/artifacts"
printf '{"issue":"969"}\n' > "$_state_file"
mkdir -p "$_artifacts_dir"

# ─── SPEC-2: test suite failure → verdict=fail, rc=1 ─────────────────────────
# CHANGE: at merge-base plugin.sh did not exist → functions undefined → call
# failed. Now objective_gate_run must return 1 and write verdict=fail when the
# test command exits non-zero.

rm -f "$_artifacts_dir/objective-gate-result.json"
_ZBUILD_TEST_CMD_save="${ZBUILD_TEST_CMD:-}"
_ZBUILD_LINT_CMD_save="${ZBUILD_LINT_CMD:-}"
export ZBUILD_TEST_CMD="false"
export ZBUILD_LINT_CMD="true"
export ZBUILD_COVERAGE_CMD="true"
export ZBUILD_DIFF_CMD="true"
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec2_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

assert_eq "[SPEC-2] objective_gate_run returns 1 on suite failure" "1" "$_spec2_rc"
_spec2_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec2_result" ]]; then
    _spec2_verdict="$(grep -o '"verdict":"[^"]*"' "$_spec2_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-2] verdict=fail written on suite failure" "fail" "$_spec2_verdict"
else
    assert_fail "[SPEC-2] objective-gate-result.json written on suite failure" \
        "file not found: $_spec2_result"
fi

# ─── SPEC-3: lint failure → verdict=fail, rc=1 ───────────────────────────────
# CHANGE: same as SPEC-2 baseline. Now objective_gate_run must return 1 and
# write verdict=fail when the lint command exits non-zero (suite passes).

rm -f "$_artifacts_dir/objective-gate-result.json"
export ZBUILD_TEST_CMD="true"
export ZBUILD_LINT_CMD="false"
export ZBUILD_COVERAGE_CMD="true"
export ZBUILD_DIFF_CMD="true"
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec3_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

assert_eq "[SPEC-3] objective_gate_run returns 1 on lint failure" "1" "$_spec3_rc"
_spec3_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec3_result" ]]; then
    _spec3_verdict="$(grep -o '"verdict":"[^"]*"' "$_spec3_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-3] verdict=fail written on lint failure" "fail" "$_spec3_verdict"
else
    assert_fail "[SPEC-3] objective-gate-result.json written on lint failure" \
        "file not found: $_spec3_result"
fi

# ─── SPEC-4: both pass → verdict=pass, rc=0 ──────────────────────────────────
# CHANGE: same as SPEC-2 baseline. Now objective_gate_run must return 0 and
# write verdict=pass when both suite and lint commands exit 0.

rm -f "$_artifacts_dir/objective-gate-result.json"
export ZBUILD_TEST_CMD="true"
export ZBUILD_LINT_CMD="true"
export ZBUILD_COVERAGE_CMD="true"
export ZBUILD_DIFF_CMD="true"   # AC-1: empty diff → ablation gates SKIP (no live test exec)
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec4_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

assert_eq "[SPEC-4] objective_gate_run returns 0 when both pass" "0" "$_spec4_rc"
_spec4_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec4_result" ]]; then
    _spec4_verdict="$(grep -o '"verdict":"[^"]*"' "$_spec4_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-4] verdict=pass written when both pass" "pass" "$_spec4_verdict"
else
    assert_fail "[SPEC-4] objective-gate-result.json written on both-pass" \
        "file not found: $_spec4_result"
fi

# ─── SPEC-5: no route_to_model / LLM call in plugin.sh ──────────────────────
# GUARD: ADR-037 §3 invariant — no objective gate is an LLM. Verified directly
# by grep. A future edit that accidentally adds route_to_model to plugin.sh
# will fail this assertion.

_spec5_count="$(grep -c 'route_to_model' "$_PLUGIN_SH" 2>/dev/null || true)"
assert_eq "[SPEC-5] plugin.sh contains zero route_to_model calls" "0" "$_spec5_count"

# ─── SPEC-6: coverage floor pass: ZBUILD_COVERAGE_CMD=true → verdict=pass, rc=0 ─
# CHANGE: coverage floor gate absent at merge-base. Now coverage_cmd=true (exit 0)
# → gate passes, overall verdict=pass.

rm -f "$_artifacts_dir/objective-gate-result.json"
export ZBUILD_TEST_CMD="true"
export ZBUILD_LINT_CMD="true"
export ZBUILD_COVERAGE_CMD="true"
export ZBUILD_DIFF_CMD="true"   # AC-1: empty diff → ablation gates SKIP (no live test exec)
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec6_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

assert_eq "[SPEC-6] objective_gate_run returns 0 when coverage_cmd passes" "0" "$_spec6_rc"
_spec6_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec6_result" ]]; then
    _spec6_verdict="$(grep -o '"verdict":"[^"]*"' "$_spec6_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-6] verdict=pass when coverage passes" "pass" "$_spec6_verdict"
else
    assert_fail "[SPEC-6] objective-gate-result.json written on coverage pass" \
        "file not found: $_spec6_result"
fi

# ─── SPEC-7: coverage floor fail: ZBUILD_COVERAGE_CMD=false → verdict=fail, rc=1 ─
# CHANGE: coverage floor gate absent at merge-base. Now coverage_cmd=false (exit 1)
# → gate fails, fail_reason=coverage_fail, verdict=fail.

rm -f "$_artifacts_dir/objective-gate-result.json"
export ZBUILD_TEST_CMD="true"
export ZBUILD_LINT_CMD="true"
export ZBUILD_COVERAGE_CMD="false"
export ZBUILD_DIFF_CMD="true"   # AC-1: empty diff → ablation gates SKIP (no live test exec)
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec7_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

assert_eq "[SPEC-7] objective_gate_run returns 1 when coverage_cmd fails" "1" "$_spec7_rc"
_spec7_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec7_result" ]]; then
    _spec7_verdict="$(grep -o '"verdict":"[^"]*"' "$_spec7_result" | cut -d'"' -f4 || echo 'ERROR')"
    _spec7_reason="$(grep -o '"reason":"[^"]*"' "$_spec7_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-7] verdict=fail when coverage fails" "fail" "$_spec7_verdict"
    assert_eq "[SPEC-7] reason=coverage_fail when coverage fails" "coverage_fail" "$_spec7_reason"
else
    assert_fail "[SPEC-7] objective-gate-result.json written on coverage fail" \
        "file not found: $_spec7_result"
fi

# ─── SPEC-8: scope-adherence no-op when plan.json absent ─────────────────────
# CHANGE: scope gate absent at merge-base. Now when plan.json is absent from
# artifacts_dir, the scope gate is silently skipped and verdict is unaffected.

rm -f "$_artifacts_dir/objective-gate-result.json"
rm -f "$_artifacts_dir/plan.json"
export ZBUILD_TEST_CMD="true"
export ZBUILD_LINT_CMD="true"
export ZBUILD_COVERAGE_CMD="true"
export ZBUILD_DIFF_CMD="true"   # AC-1: empty diff → ablation gates SKIP (no live test exec)
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec8_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

assert_eq "[SPEC-8] objective_gate_run returns 0 when plan.json absent (scope no-op)" "0" "$_spec8_rc"
_spec8_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec8_result" ]]; then
    _spec8_verdict="$(grep -o '"verdict":"[^"]*"' "$_spec8_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-8] verdict=pass when plan.json absent" "pass" "$_spec8_verdict"
else
    assert_fail "[SPEC-8] objective-gate-result.json written when plan.json absent" \
        "file not found: $_spec8_result"
fi

# ─── SPEC-9: scope-adherence fail when plan file not in diff ─────────────────
# CHANGE: scope gate absent at merge-base. Now when plan.json names a file not
# returned by ZBUILD_DIFF_CMD → verdict=fail, reason=scope_fail.

rm -f "$_artifacts_dir/objective-gate-result.json"
printf '{"steps":[{"files":["src/missing-file.sh"]}]}\n' > "$_artifacts_dir/plan.json"
export ZBUILD_TEST_CMD="true"
export ZBUILD_LINT_CMD="true"
export ZBUILD_COVERAGE_CMD="true"
# Diff returns no files — plan file will not be found.
export ZBUILD_DIFF_CMD="true"
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec9_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
rm -f "$_artifacts_dir/plan.json"
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

assert_eq "[SPEC-9] objective_gate_run returns 1 on scope failure" "1" "$_spec9_rc"
_spec9_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec9_result" ]]; then
    _spec9_verdict="$(grep -o '"verdict":"[^"]*"' "$_spec9_result" | cut -d'"' -f4 || echo 'ERROR')"
    _spec9_reason="$(grep -o '"reason":"[^"]*"' "$_spec9_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-9] verdict=fail on scope failure" "fail" "$_spec9_verdict"
    assert_eq "[SPEC-9] reason=scope_fail on scope failure" "scope_fail" "$_spec9_reason"
else
    assert_fail "[SPEC-9] objective-gate-result.json written on scope fail" \
        "file not found: $_spec9_result"
fi

# ─── SPEC-10: coverage_delta field present when coverage passes ───────────────
# CHANGE: coverage_delta field absent at merge-base (field not written). Now when
# coverage passes (ZBUILD_COVERAGE_CMD=true), coverage_delta key appears in the
# result JSON — confirms it is a report signal, not a gate.

rm -f "$_artifacts_dir/objective-gate-result.json"
export ZBUILD_TEST_CMD="true"
export ZBUILD_LINT_CMD="true"
export ZBUILD_COVERAGE_CMD="true"
export ZBUILD_DIFF_CMD="true"   # AC-1: empty diff → ablation gates SKIP (no live test exec)
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec10_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

_spec10_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec10_result" ]]; then
    _spec10_has_delta=0
    grep -q '"coverage_delta"' "$_spec10_result" && _spec10_has_delta=1
    assert_eq "[SPEC-10] coverage_delta field present in result JSON" "1" "$_spec10_has_delta"
else
    assert_fail "[SPEC-10] objective-gate-result.json written for coverage_delta check" \
        "file not found: $_spec10_result"
fi

# ─── SPEC-14: real coverage-parse path propagates coverage_pct to result JSON ─
# GUARD (regression for the #970 review's "nameref" concern): the coverage helper
# bare-assigns `coverage_pct`, relying on bash dynamic scoping to reach
# objective_gate_run's `local coverage_pct`. That is correct bash behavior (the
# helper does NOT shadow it with its own `local`), but a future `local coverage_pct`
# added to the helper would silently zero it. SPEC-6/7 use a coverage cmd that emits
# NO percentage (true/false), so the parse+propagate path is otherwise untested.
# Here the cmd EMITS a percentage; the parsed value must reach the result JSON.

rm -f "$_artifacts_dir/objective-gate-result.json"
rm -f "$_artifacts_dir/plan.json"
export ZBUILD_TEST_CMD="true"
export ZBUILD_LINT_CMD="true"
# Mimic check-coverage.sh output: a per-file table row FIRST, then the "Total:"
# summary. The parser must pick the Total (50.0), NOT the first per-file row
# (10.0) — Copilot #1009 finding. Also confirms quality_score reaches the JSON.
export ZBUILD_COVERAGE_CMD='printf "%s\n" "| a.sh | 1 | 10 | 10.0%" "Total: 10/20 lines (50.0%)"'
export ZBUILD_DIFF_CMD="true"   # AC-1: empty diff → ablation gates SKIP (no live test exec)
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec14_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

assert_eq "[SPEC-14] objective_gate_run returns 0 when coverage cmd emits a passing %" "0" "$_spec14_rc"
_spec14_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec14_result" ]]; then
    _spec14_cov="$(grep -o '"coverage_pct":[0-9.]*' "$_spec14_result" | grep -o '[0-9.]*$' || echo 'ERROR')"
    assert_eq "[SPEC-14] coverage_pct parses the Total line, not the first per-file row" "50.0" "$_spec14_cov"
    _spec14_has_quality=0
    grep -q '"quality_score"' "$_spec14_result" && _spec14_has_quality=1
    assert_eq "[SPEC-14] quality_score field written to result JSON (per design/manifest)" "1" "$_spec14_has_quality"
else
    assert_fail "[SPEC-14] objective-gate-result.json written for coverage-parse check" \
        "file not found: $_spec14_result"
fi

# ─── SPEC-11/12/13: ablation gates SKIP on empty diff → pass + verdict fields ─
# CHANGE: ablation verdict fields absent at merge-base; now SKIP when diff empty.
# ZBUILD_DIFF_CMD="true" → empty diff → all three ablation gates emit SKIP.
# Overall verdict must still be pass; result JSON must contain all three fields.

rm -f "$_artifacts_dir/objective-gate-result.json"
rm -f "$_artifacts_dir/plan.json"
export ZBUILD_TEST_CMD="true"
export ZBUILD_LINT_CMD="true"
export ZBUILD_COVERAGE_CMD="true"
export ZBUILD_DIFF_CMD="true"
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec11_rc=$?
set -e
unset ZBUILD_COVERAGE_CMD ZBUILD_DIFF_CMD
export ZBUILD_TEST_CMD="$_ZBUILD_TEST_CMD_save"
export ZBUILD_LINT_CMD="$_ZBUILD_LINT_CMD_save"

assert_eq "[SPEC-11] negctl skips on empty diff → overall rc=0" "0" "$_spec11_rc"
_spec_result="$_artifacts_dir/objective-gate-result.json"
if [[ -f "$_spec_result" ]]; then
    _s11_v="$(grep -o '"negctl_verdict":"[^"]*"' "$_spec_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-11] negctl_verdict=skip when diff is empty" "skip" "$_s11_v"
else
    assert_fail "[SPEC-11] objective-gate-result.json written for ablation skip check" \
        "file not found: $_spec_result"
fi

if [[ -f "$_spec_result" ]]; then
    _s12_v="$(grep -o '"reachability_verdict":"[^"]*"' "$_spec_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-12] reachability_verdict=skip when diff is empty" "skip" "$_s12_v"
else
    assert_fail "[SPEC-12] objective-gate-result.json written for reachability skip check" \
        "file not found: $_spec_result"
fi

if [[ -f "$_spec_result" ]]; then
    _s13_v="$(grep -o '"shape_floor_verdict":"[^"]*"' "$_spec_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-13] shape_floor_verdict=skip when diff is empty" "skip" "$_s13_v"
    _s13_verdict="$(grep -o '"verdict":"[^"]*"' "$_spec_result" | cut -d'"' -f4 || echo 'ERROR')"
    assert_eq "[SPEC-13] overall verdict=pass when all ablation gates skip" "pass" "$_s13_verdict"
else
    assert_fail "[SPEC-13] objective-gate-result.json written for shape floor skip check" \
        "file not found: $_spec_result"
fi

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
