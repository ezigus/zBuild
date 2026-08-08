#!/usr/bin/env bash
# Integration test (#1709 / ADR-034): ZBUILD_TEST_CHANGED_FILES is armed
# intra-iter after the build stage completes, enabling targeted mode on
# ITERATION 1 — not just iter 2+ as the prior #846 fix provided.
#
# Scenario:
#   iter 1: build writes build-summary.json (files_changed=[lib/util.sh]);
#           orchestrator arms ZBUILD_TEST_CHANGED_FILES before test dispatch;
#           _test_compute_target_files greps tests/ for "util.sh" and finds
#           tests/unit/util_test.sh → test runs ONLY that file (run_mode=targeted),
#           passes → full-suite gate fires.
#   iter 2: gate forces full suite (run_mode=full); all tests pass → converged.
#
# The fixture uses a real source→test reference relationship so that
# _test_compute_target_files can locate the test file via grep, matching
# the contract described in ADR-034.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build_test_cycle: targeted mode available on iter 1 (#1709)"
setup_test_env "build-test-cycle-targeted-iter1"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_RUN_ID="targeted-iter1-$$"

# ─── Fixture repo ─────────────────────────────────────────────────────────────
# lib/util.sh  — a source file that the build declares changed
# tests/unit/util_test.sh — test that sources util.sh (contains "util.sh"
#   in its text, so _test_compute_target_files can grep-discover it)
# tests/unit/other_test.sh — an unrelated test that must NOT run in targeted mode
FIXTURE="$TEST_TEMP_DIR/fixture"
mkdir -p "$FIXTURE/lib" "$FIXTURE/tests/unit"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email t@e.x; git -C "$FIXTURE" config user.name t

printf '#!/usr/bin/env bash\nreturn 0\n' > "$FIXTURE/lib/util.sh"
# util_test.sh references util.sh by name so grep-discovery works
cat > "$FIXTURE/tests/unit/util_test.sh" <<'EOF'
#!/usr/bin/env bash
# Tests for lib/util.sh
source lib/util.sh
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/tests/unit/other_test.sh"
chmod +x "$FIXTURE/tests/unit/util_test.sh" "$FIXTURE/tests/unit/other_test.sh"
git -C "$FIXTURE" add -A; git -C "$FIXTURE" commit -q -m seed
export ZBUILD_REPO_ROOT="$FIXTURE"

# Test runner — same format as the #846 targeted-rerun test.
RUNNER="$TEST_TEMP_DIR/runner.sh"
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
load_template "$REPO_ROOT/tests/fixtures/templates/build-test-cycle-minimal.yaml"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# ─── Stub dispatch: real test stage; synthetic build ─────────────────────────
RUN_MODES="$TEST_TEMP_DIR/run-modes.log"
: > "$RUN_MODES"
cycle_dispatch_stage() {
    local stage="$1" iter="$2" state_file="$3"
    local sd; sd="$(dirname "$state_file")"; local ad="$sd/artifacts"; mkdir -p "$ad"
    local v="pass"
    case "$stage" in
        build)
            # Declare lib/util.sh changed; _test_compute_target_files will grep
            # tests/ for "util.sh" and find util_test.sh (real source→test ref).
            printf '{"schema_version":1,"verdict":"pass","files_changed":["lib/util.sh"]}' \
                > "$ad/build-summary.json"
            : > "$ad/diff.patch"
            v="pass" ;;
        test)
            test_run "test" "$state_file" >/dev/null 2>&1 || true
            local rm; rm="$(jq -r '.run_mode // "?"' "$ad/test-results.json" 2>/dev/null || echo "?")"
            printf 'iter=%s run_mode=%s\n' "$iter" "$rm" >> "$RUN_MODES"
            v="$(jq -r '.verdict // "fail"' "$ad/test-results.json" 2>/dev/null || echo fail)" ;;
    esac
    _CYCLE_DISPATCH_VERDICT="$v"; _CYCLE_DISPATCH_STATUS="complete"; return 0
}

BANNER_LOG="$TEST_TEMP_DIR/banner.log"
set +e
cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE" \
    >"$BANNER_LOG" 2>&1
RC=$?
set -e

echo "--- banner ---"; cat "$BANNER_LOG"
echo "--- run_modes ---"; cat "$RUN_MODES"
iter1_mode="$(awk -F'run_mode=' '/iter=1 /{print $2}' "$RUN_MODES" | head -1)"
iter2_mode="$(awk -F'run_mode=' '/iter=2 /{print $2}' "$RUN_MODES" | head -1)"

# [SPEC-1] CHANGE-behavior: iter-1 test stage engages targeted mode when
# build-summary.json is armed intra-iter.  Fails at merge-base baseline
# (prior code never arms ZBUILD_TEST_CHANGED_FILES before iter 2).
assert_eq "[SPEC-1] T1: iter-1 test stage runs run_mode=targeted (intra-iter arm)" \
    "targeted" "$iter1_mode"
assert_event_emitted "T2: cycle.test.full_suite_gate emitted on targeted convergence" \
    "$ZBUILD_EVENTS_JSONL" "cycle.test.full_suite_gate"
assert_eq "T3: iter-2 (gate) runs full suite" "full" "$iter2_mode"
assert_eq "T4: cycle converged (rc=0)" "0" "$RC"
assert_eq "T5: reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
