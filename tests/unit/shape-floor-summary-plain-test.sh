#!/usr/bin/env bash
# tests/unit/shape-floor-summary-plain-test.sh — the shape check's summary says
# what to do, in plain words, and no longer demands edits a correct file does
# not need (#2269).
#
# Why: the summary later stages read said "A shape change is in flight, so these
# files must change with it" under a headline that was the raw reason token
# (missing_floor_files). Since #2256 a floor file that is still correct needs no
# edit, so "must change" sends build to edit files that are fine.
#
# S1 [change] the summary does not show the raw reason token or "in flight"
# S2 [change] it says to update the files that are now wrong, and that a still-
#             correct file can stay as it is
# S3 [guard]  the result JSON keeps its reason token (other code reads it)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the shape check's summary is plain (#2269)"
setup_test_env "shape-floor-summary-plain"
# shellcheck source=../../plugins/tool/shape-floor/plugin.sh
source "$REPO_ROOT/plugins/tool/shape-floor/plugin.sh"

T="$TEST_TEMP_DIR/target"
mkdir -p "$T/config" "$T/tests/golden/full" "$T/tests/unit" "$T/core/pipeline"
printf 'core/pipeline/runner.sh\n' > "$T/config/shape-change-paths.txt"
printf 'pipeline.start\n' > "$T/tests/golden/full/event-sequence.golden"
# shellcheck disable=SC2016  # literal source text
printf 'assert_eq "x" "impact" "${_TPL_STAGES[2]}"\n' > "$T/tests/unit/order-test.sh"
printf 'echo runner\n' > "$T/core/pipeline/runner.sh"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t \
  && git add -A && git commit -qm base ) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$T" ZBUILD_DIFF_CMD="printf 'core/pipeline/runner.sh\n'"
S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"; printf '{}\n' > "$S/pipeline-state.json"
export ZBUILD_ARTIFACT_DIR="$S/artifacts"
unset ZBUILD_STAGE_INPUTS

shape_floor_run shape-floor "$S/pipeline-state.json" >/dev/null 2>&1
_sum="$(cat "$S/artifacts/shape-floor-detail.md" 2>/dev/null)"
assert_eq "fixture: the check failed" "fail" "$(jq -r '.verdict // empty' "$S/artifacts/shape-floor-result.json" 2>/dev/null)"

for _w in missing_floor_files "in flight" "must change"; do
    if grep -qF -- "$_w" <<< "$_sum"; then
        assert_fail "[S1] the summary does not say '$_w'" "found in shape-floor-detail.md"
    else
        assert_pass "[S1] the summary does not say '$_w'"
    fi
done
assert_contains "[S2] it says to update the files that are now wrong" "$_sum" "Update any that are now wrong"
assert_contains "[S2] it says a still-correct file can stay" "$_sum" "can stay as it is"
assert_eq "[S3] the result JSON keeps its reason token" "missing_floor_files" \
    "$(jq -r '.reason // empty' "$S/artifacts/shape-floor-result.json" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
