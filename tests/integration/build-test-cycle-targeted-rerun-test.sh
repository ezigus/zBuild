#!/usr/bin/env bash
# Integration test (#846 / ADR-034): the REAL build_test_cycle + REAL test plugin
# engage targeted re-run end to end. The unit tests cover the pieces
# (_test_run_inner run_mode=targeted; the orchestrator gate); this proves they
# CONNECT — i.e. _cycle_apply_feedback actually exports the red-set to the real
# test stage, the test stage runs only the affected file (run_mode=targeted), and
# the orchestrator then fires the full-suite gate before converging.
#
#   iter 1: full run, b.sh fails  -> red-set={b.sh}, run_mode=full, verdict=fail
#   iter 2: build fixes b.sh; red-set exported -> test runs ONLY b.sh
#           (run_mode=targeted), passes -> orchestrator suppresses convergence and
#           arms ZBUILD_TEST_FULL_SUITE_GATE (emits cycle.test.full_suite_gate)
#   iter 3: gate forces a full run -> all pass (run_mode=full) -> converged
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build_test_cycle: real targeted re-run + full-suite gate (#846)"
setup_test_env "build-test-cycle-targeted-846"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_RUN_ID="targeted-846-$$"

# ─── Fixture repo the real test stage rsyncs + runs ──────────────────────────
FIXTURE="$TEST_TEMP_DIR/fixture"
mkdir -p "$FIXTURE/tests/unit"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email t@e.x; git -C "$FIXTURE" config user.name t
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/tests/unit/a.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FIXTURE/tests/unit/b.sh"  # fails initially
chmod +x "$FIXTURE/tests/unit/"*.sh
git -C "$FIXTURE" add -A; git -C "$FIXTURE" commit -q -m seed
export ZBUILD_REPO_ROOT="$FIXTURE"

# Test runner emitting the zbuild runall FAIL format the red-set parser expects.
RUNNER="$TEST_TEMP_DIR/runner.sh"
# Runner mirrors scripts/run-tests.sh: no args → full (all tests/unit/*.sh);
# args → targeted subset. Emits the recognised `unit: N/M passed` + `unit: FAIL
# <f>` format so the test plugin's verdict parser AND red-set extractor work for
# both modes (the whole point of #846's fix).
cat > "$RUNNER" <<'RUN'
files=("$@"); [[ ${#files[@]} -eq 0 ]] && files=(tests/unit/*.sh)
p=0; t=0
for f in "${files[@]}"; do
  t=$((t+1))
  if bash "$f" >/dev/null 2>&1; then p=$((p+1)); else printf 'unit: FAIL %s\n' "$f"; fi
done
printf 'unit: %s/%s passed\n' "$p" "$t"
[[ $p -eq $t ]] && exit 0 || exit 1
RUN
export ZBUILD_TEST_CMD="bash $RUNNER"
# #846: repo-configurable targeted command (the {files} placeholder is rendered
# by _test_build_targeted_cmd). Mirrors zbuild's `run-tests.sh --files {files}`.
export ZBUILD_TEST_CMD_TARGETED="bash $RUNNER {files}"

# ─── State dir + cycle env ───────────────────────────────────────────────────
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
ART="$ZBUILD_STATE_DIR/artifacts"
mkdir -p "$ART" "$ZBUILD_EVENTS_DIR"; : > "$ZBUILD_EVENTS_JSONL"
printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_FILE"

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/standard.yaml"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# ─── Stub dispatch: real test stage; synthetic build + assessment ────────────
RUN_MODES="$TEST_TEMP_DIR/run-modes.log"  # one run_mode per test dispatch
: > "$RUN_MODES"
cycle_dispatch_stage() {
    local stage="$1" iter="$2" state_file="$3"
    local sd; sd="$(dirname "$state_file")"; local ad="$sd/artifacts"; mkdir -p "$ad"
    local v="pass"
    case "$stage" in
        build)
            # iter 2: "fix" b.sh so the targeted re-run goes green; declare the change.
            if [[ "$iter" == "2" ]]; then
                printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/tests/unit/b.sh"
                git -C "$FIXTURE" commit -q -am "fix b" 2>/dev/null || true
            fi
            printf '{"schema_version":1,"verdict":"pass","files_changed":["tests/unit/b.sh"]}' > "$ad/build-summary.json"
            : > "$ad/diff.patch"   # test stage guards on diff.patch existence
            v="pass" ;;
        test)
            test_run "test" "$state_file" >/dev/null 2>&1 || true
            local rm; rm="$(jq -r '.run_mode // "?"' "$ad/test-results.json" 2>/dev/null || echo "?")"
            printf 'iter=%s run_mode=%s\n' "$iter" "$rm" >> "$RUN_MODES"
            v="$(jq -r '.verdict // "fail"' "$ad/test-results.json" 2>/dev/null || echo fail)" ;;
        test_assessment)
            # Focused stub: mirror the test verdict (assessment is covered by #895).
            v="$(jq -r '.verdict // "fail"' "$ad/test-results.json" 2>/dev/null || echo fail)"
            printf '{"verdict":"%s"}' "$v" > "$ad/test-assessment.json"
            printf '## assess iter %s\nverdict: %s\n' "$iter" "$v" > "$ad/test-assessment.md" ;;
    esac
    _CYCLE_DISPATCH_VERDICT="$v"; _CYCLE_DISPATCH_STATUS="complete"; return 0
}

set +e
cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE"
RC=$?
set -e

echo "--- run_modes ---"; cat "$RUN_MODES"
iter2_mode="$(awk -F'run_mode=' '/iter=2 /{print $2}' "$RUN_MODES" | head -1)"
iter3_mode="$(awk -F'run_mode=' '/iter=3 /{print $2}' "$RUN_MODES" | head -1)"

assert_eq "T1: iter-2 test stage runs run_mode=targeted (red-set engaged)" "targeted" "$iter2_mode"
assert_event_emitted "T2: cycle.test.full_suite_gate emitted on targeted convergence" \
    "$ZBUILD_EVENTS_JSONL" "cycle.test.full_suite_gate"
assert_eq "T3: iter-3 (gate) runs full suite" "full" "$iter3_mode"
assert_eq "T4: cycle converged (rc=0)" "0" "$RC"
assert_eq "T5: reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
