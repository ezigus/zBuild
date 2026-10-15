#!/usr/bin/env bash
# Tests: a stage's latest output is what every reader gets, and the engine
# neither copies nor deletes a stage's output to make that so (ADR-068 §6,
# ADR-021 §3 as amended).
#
#   L1 [change] a stage that runs again and does not rewrite its result has no
#               result for that run — the previous run's verdict is not read as
#               this one's. This used to be done by DELETING the result before a
#               loop re-ran the stage (#511 Pin 8); now the reader tells by time.
#   L1b [guard] a stage that does rewrite its result is read as usual.
#   L2 [change] a loop does not delete a stage's output before running it again.
#   L3 retired with gate-aggregator (#2368): the engine counts a member with no
#      outcome this round as failed — engine-combines-loop-test.sh L2. Was: does not count a gate's result from before the
#               gate's latest run (a suite that timed out on try 2 must not pass
#               on try 1's result) — review on #2357.
#   L4 [change] the stage report is empty for a run that wrote no result.
#   L5 [change] data.build_kind is not read from a previous run's result.
#   L6 [change] a run refused before its hook ran has no result either.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

print_test_header "a stage's latest output, never an engine copy or deletion"
setup_test_env "stage-latest-output"
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl" ZBUILD_EVENTS_DB=/dev/null

STATE="$TEST_TEMP_DIR/state"
mkdir -p "$STATE/artifacts"
export ZBUILD_STATE_DIR="$STATE"
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# A stage that writes a pass the first time it runs and nothing after.
SDIR="$(mock_plugin_factory "once-writer" "tool" 0)"
cat > "$SDIR/plugin.sh" <<EOF
once_writer_run() {
    [[ -f "$TEST_TEMP_DIR/once-written" ]] && return 0
    : > "$TEST_TEMP_DIR/once-written"
    $(mock_result_line once-writer pass)
    return 0
}
EOF
_TPL_STAGES=(once-writer)

_read() {
    _verdict_read_result "$STATE" "$SDIR/manifest.yaml" "once-writer" 0 _r
    printf '%s|%s' "$_r_state" "$_r_verdict"
}

# ─── L1b: the run that writes its result is read as usual ───────────────────
print_test_section "L1b: a result the stage wrote this run is read"
plugin_hook_call "$SDIR" run "once-writer" "$STATE/pipeline-state.json" >/dev/null 2>&1
assert_eq "[L1b] first run's pass is read" "ok|pass" "$(_read)"

# ─── L1: the next run writes nothing; its result is missing, not the old pass ─
print_test_section "L1: a run that did not rewrite its result has none"
# Backdate the first result so the second run's mark is strictly newer on any
# filesystem's timestamp resolution.
touch -t 202601010000 "$STATE/artifacts/once-writer-result.json"
plugin_hook_call "$SDIR" run "once-writer" "$STATE/pipeline-state.json" >/dev/null 2>&1
assert_file_exists "[L1] the engine did not delete the stage's file" \
    "$STATE/artifacts/once-writer-result.json"
assert_eq "[L1] the second run's result reads as absent, not the first run's pass" \
    "absent|" "$(_read)"

# ─── L4 / L5: the report and build_kind come from this run's result only ─────
print_test_section "L4/L5: report and build_kind of a run that wrote nothing"
assert_eq "[L4] the stage report of that run is empty" "{}" \
    "$(runner_read_stage_report "$STATE" "$SDIR/manifest.yaml" "once-writer" 0)"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
stage_result_write "$STATE/artifacts/once-writer-result.json" pass r '{"build_kind":"empty_diff"}' >/dev/null
touch -t 202601010000 "$STATE/artifacts/once-writer-result.json"
assert_eq "[L5] build_kind is not read from a result older than the run" "" \
    "$(runner_read_stage_data_kind "$STATE" "$SDIR/manifest.yaml" "once-writer")"

# ─── L6: a run refused before its hook ran has no result ────────────────────
print_test_section "L6: a refused run is not credited with the previous result"
NDIR="$(mock_plugin_factory "needy" "tool" 0)"
_TPL_STAGES=(once-writer needy)
plugin_hook_call "$NDIR" run "needy" "$STATE/pipeline-state.json" >/dev/null 2>&1
_verdict_read_result "$STATE" "$NDIR/manifest.yaml" "needy" 0 _n
assert_eq "[L6-guard] the first run wrote its result" "ok|pass" "$_n_state|$_n_verdict"
touch -t 202601010000 "$STATE/artifacts/needy-result.json"
# The engine refuses the next run before its hook: the manifest no longer
# declares one (plugin.run.refused, reason=hook-not-declared).
python3 - "$NDIR/manifest.yaml" <<'PY'
import sys,re; p=sys.argv[1]; s=open(p).read()
s=re.sub(r"\n  run: [^\n]*", "", s, count=1)
open(p,'w').write(s)
PY
plugin_hook_call "$NDIR" run "needy" "$STATE/pipeline-state.json" >/dev/null 2>&1
_verdict_read_result "$STATE" "$NDIR/manifest.yaml" "needy" 0 _n
assert_eq "[L6] the refused run's result reads as absent" "absent" "$_n_state"

# ─── L2: a loop does not delete a member's output before re-running it ──────
print_test_section "L2: a loop keeps a member's output until the member rewrites it"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
mock_plugin_factory "build" "agent" 0 "" "builder" >/dev/null
mock_plugin_factory "test" "agent" 0 "" "tester" >/dev/null
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
STATE_FILE="$STATE/pipeline-state.json"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
stage_result_write "$STATE/artifacts/test-result.json" fail "try 1" >/dev/null
SEEN="$TEST_TEMP_DIR/seen.txt"; : > "$SEEN"
# The dispatch stub records, as each member starts, whether its own output from
# the previous try is still where it wrote it.
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    if [[ "$stage" == "test" ]]; then
        if [[ -f "$STATE/artifacts/test-result.json" ]]; then
            printf 'iter%s:present\n' "$iter" >> "$SEEN"
        else
            printf 'iter%s:deleted\n' "$iter" >> "$SEEN"
        fi
        if [[ "$iter" -ge 2 ]]; then _CYCLE_DISPATCH_VERDICT=pass; _CYCLE_DISPATCH_STATUS=complete; return 0; fi
        _CYCLE_DISPATCH_VERDICT=fail; _CYCLE_DISPATCH_STATUS=failed; return 1
    fi
    _CYCLE_DISPATCH_VERDICT=pass; _CYCLE_DISPATCH_STATUS=complete; return 0
}
# shellcheck source=../lib/cycle-report-stub.sh
source "$REPO_ROOT/tests/lib/cycle-report-stub.sh"
zb_stub_reports_tests test
load_template "$REPO_ROOT/tests/fixtures/templates/cycle-converges-iter2.yaml"
cycle_orchestrator_run "build-test" "$STATE" "$STATE_FILE" >/dev/null 2>&1 || true
assert_contains "[L2] try 1 starts with the member's output in place" "$(cat "$SEEN")" "iter1:present"
assert_contains "[L2] try 2 starts with the member's output in place" "$(cat "$SEEN")" "iter2:present"
if grep -q '"cycle.artifacts.cleared"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[L2] no cycle.artifacts.cleared event" "the loop deleted a member's output"
else
    assert_pass "[L2] no cycle.artifacts.cleared event"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
