#!/usr/bin/env bash
# tests/unit/change-scope-floor-test.sh — one scope list, and the shape floor is
# in it (#1874).
#
# Why: a change touching a pipeline-shape file (config/shape-change-paths.txt)
# must also update the event goldens and the tests that pin stage order — the
# "shape floor". shape-floor computes that list at JUDGMENT time, but nothing
# put it into SCOPE, so build was refused the files the gate then demanded:
# #1701 failed three runs (~2.5 h each) with a correct implementation, and
# #2032 (run 36969130031) failed every iteration on the same seven files. A
# second gap: the engine's allowlist held plan's 9 files while build worked to
# design's 28, so shape-floor judged scope against the wrong list.
#
# F1 [change] the engine's scope list gains every floor file when a reported
#             scope file is a shape-change path
# F2 [guard]  ...and gains nothing when none is
# F3 [change] design reports its scope block, so the engine list is the one
#             build works to (plan ∪ design), not plan's alone
# F4 [change] build's scope includes the engine list's floor files
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "one scope list, with the shape floor in it (#1874)"
setup_test_env "change-scope-floor"
# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"

# A target repo with a shape-change list, one event golden, one order test.
T="$TEST_TEMP_DIR/target"
mkdir -p "$T/config" "$T/tests/golden/full" "$T/tests/unit" "$T/core/pipeline"
printf 'core/pipeline/runner.sh\n' > "$T/config/shape-change-paths.txt"
printf 'pipeline.start\n' > "$T/tests/golden/full/event-sequence.golden"
# shellcheck disable=SC2016  # literal source text
printf 'assert_eq "x" "impact" "${_TPL_STAGES[2]}"\n' > "$T/tests/unit/order-test.sh"
export ZBUILD_REPO_ROOT="$T"
S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"

print_test_section "F1/F2: the floor joins the scope list"
_runner_record_report "$S" plan '{"scope_files":["core/pipeline/runner.sh"]}'
_runner_export_scope_allowlist "$S"
assert_contains "[F1] the event golden is in scope" ",${ZBUILD_SCOPE_ALLOWLIST:-}," ",tests/golden/full/event-sequence.golden,"
assert_contains "[F1] the stage-order test is in scope" ",${ZBUILD_SCOPE_ALLOWLIST:-}," ",tests/unit/order-test.sh,"
S2="$TEST_TEMP_DIR/state2"; mkdir -p "$S2/artifacts"
_runner_record_report "$S2" plan '{"scope_files":["lib/other.sh"]}'
_runner_export_scope_allowlist "$S2"
assert_eq "[F2] no shape file in scope → nothing added" "lib/other.sh" "${ZBUILD_SCOPE_ALLOWLIST:-}"

print_test_section "F3: design reports its scope"
D="$TEST_TEMP_DIR/design-art"; mkdir -p "$D"
printf '# Design\n\n```scope\ncore/pipeline/runner.sh\nlib/new.sh\n```\n' > "$D/design.md"
_f3="$(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    _design_write_result "$D" pass complete "authored" >/dev/null 2>&1
    jq -c '.data.scope_files // empty' "$D/design-verdict.json" 2>/dev/null
)"
assert_eq "[F3] design reports its scope block" '["core/pipeline/runner.sh","lib/new.sh"]' "$_f3"

print_test_section "F4: build works to the engine list"
_f4="$(
    # shellcheck source=../../plugins/agent/build/plugin.sh
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    artifact_dir="$TEST_TEMP_DIR/build-art"; mkdir -p "$artifact_dir"
    plan_json='{"files":["core/pipeline/runner.sh"],"steps":[]}'
    export ZBUILD_SCOPE_ALLOWLIST="core/pipeline/runner.sh,tests/unit/order-test.sh"
    _build_load_context >/dev/null 2>&1
    printf '%s' "${plan_files_csv:-}"
)"
assert_contains "[F4] build's scope holds the floor file" ",$_f4," ",tests/unit/order-test.sh,"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
