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

_tmpdir="$(mktemp -d)"
_state_file="$_tmpdir/state.json"
_artifacts_dir="$_tmpdir/artifacts"
printf '{"issue":"969"}\n' > "$_state_file"
mkdir -p "$_artifacts_dir"

# Trap to clean up the temp dir on test exit.
trap 'rm -rf "$_tmpdir"' EXIT

# ─── SPEC-2: test suite failure → verdict=fail, rc=1 ─────────────────────────
# CHANGE: at merge-base plugin.sh did not exist → functions undefined → call
# failed. Now objective_gate_run must return 1 and write verdict=fail when the
# test command exits non-zero.

rm -f "$_artifacts_dir/objective-gate-result.json"
_ZBUILD_TEST_CMD_save="${ZBUILD_TEST_CMD:-}"
_ZBUILD_LINT_CMD_save="${ZBUILD_LINT_CMD:-}"
export ZBUILD_TEST_CMD="false"
export ZBUILD_LINT_CMD="true"
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec2_rc=$?
set -e
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
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec3_rc=$?
set -e
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
set +e
objective_gate_run "objective-gate" "$_state_file"
_spec4_rc=$?
set -e
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

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
