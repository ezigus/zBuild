#!/usr/bin/env bash
# tests/integration/stage-errors-log-per-dispatch-test.sh — a stage's error log
# holds only its latest dispatch's errors (ADR-068 §8).
#
# Why: stage_errors_append adds lines to <stage>-errors.log, and nothing ever
# emptied it. #1801's rerun showed design's errors from earlier attempts and
# earlier runs as if they were this one's. The attempt archive keeps each
# dispatch's copy.
#
#   E1 [change] a dispatch starts with the stage's error log empty: an earlier
#               dispatch's lines are gone, this one's are there
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "a stage's error log holds only its latest dispatch's errors"
setup_test_env "stage-errors-log-per-dispatch"
emit_event() { :; }
verify_plugin_for_source() { return 0; }
scan_plugin_outputs() { return 0; }
export ZBUILD_NO_WORKTREE=1

JOB="$TEST_TEMP_DIR/state/runs/el"; A="$JOB/artifacts"
SF="$JOB/pipeline-state.json"
mkdir -p "$A" "$JOB/runtime"
echo '{}' > "$SF"
# An earlier dispatch's error, written with the stage's own writer.
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"
ZBUILD_ARTIFACT_DIR="$A" stage_errors_append me "an earlier dispatch failed"
WT="$TEST_TEMP_DIR/wt"; mkdir -p "$WT"; git -C "$WT" init -q
export ZBUILD_REPO_ROOT="$WT"

FX="$TEST_TEMP_DIR/plugins/me"; mkdir -p "$FX"
cat > "$FX/manifest.yaml" <<'YAML'
id: me
name: me
kind: tool
version: 0.0.1
hooks:
  run: me_run
outputs:
  - id: result
    path: ${artifact_dir}/me-result.json
    required: true
    primary: true
  - id: errors
    path: ${artifact_dir}/me-errors.log
    required: false
    errors: true
YAML
cat > "$FX/plugin.sh" <<PEOF
source '$REPO_ROOT/scripts/lib/stage-summary.sh'
me_run() { printf '{}\n' > '$A/me-result.json'; stage_errors_append me "this dispatch failed"; }
PEOF
plugin_hook_call "$FX" run me "$SF" >/dev/null 2>&1 || true
L="$(cat "$A/me-errors.log" 2>/dev/null)"

print_test_section "E1: a dispatch starts with the stage's error log empty"
assert_contains "[E1] this dispatch's error is there" "$L" "this dispatch failed"
if grep -qF "an earlier dispatch failed" <<< "$L"; then
    assert_fail "[E1] an earlier dispatch's error is gone" "$L"
else
    assert_pass "[E1] an earlier dispatch's error is gone"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
