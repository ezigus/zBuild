#!/usr/bin/env bash
# Integration test (#527): cycle non-converged → review fall-through → pipeline_status=failed.
#
# Drives runner.sh in-process with stubs for cycle_orchestrator_run + the review plugin
# dispatch, mimicking the subprocess boundary the runner crosses in production:
#   - cycle returns rc∈{1,2,3} (max_iter, plateau, divergence) — non-zero but continue
#   - review stage runs and writes review.json (the ADR-019 fail-closed coercion path)
#   - runner MUST set pipeline_status="failed" (NOT "complete") at the end of dispatch
#   - new event `cycle.unconverged` MUST fire with reason matching the rc
#   - stage_statuses[test]="failed" MUST be set so review's coercion has unambiguous signal
#   - pipeline.end status=failed exactly once
#
# Positive control: rc=0 (converged) + review approve → status=complete (only success path).
# Halt locks: rc=4 (config_invalid), rc=5 (blocked, #528), rc=130 → status=interrupted, review SKIPPED.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle fall-through → review → pipeline=failed (#527)"
setup_test_env "cycle-fallthrough-527"

# ─── Source-once optimization (#1096 / PC3) ────────────────────────────────────
# runner.sh transitively sources ~20 core modules; doing that per case (×7)
# dominated runtime. Hoist the source to the parent ONCE; each case still runs
# in its own SUBSHELL purely for isolation, but inherits the already-sourced
# functions (no re-source). Per-case state lives entirely in subshell-local env
# vars + stub redefinitions, so nothing leaks between cases — identical coverage.
#
# ZBUILD_EVENTS_DIR is pinned BEFORE the parent source so event-bus.sh captures
# _ZBUILD_EVENTS_PINNED=1 at source time (runner.sh L23-24). That flag is
# inherited by every subshell, so main() will NOT override each case's pinned
# events location (runner.sh L887) — events land in the case's own events dir.
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/_source_once_events"
# runner.sh runs `set -e`; isolate the one-time source so a transient nonzero
# during init can't abort the harness, then drop back to lenient mode.
set +e
# shellcheck disable=SC1091
source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null
set +e

# ─── Shared test fixture: drive runner.sh end-to-end with mocked cycle + review ─
# Each case runs in a SUBSHELL so sourced runner state doesn't leak between
# cases. The runner's main() is invoked with --template simple (#979: standard
# retired) so the cycle dispatch path is exercised — the cycle_orchestrator_run
# stub short-circuits actual member dispatch, so any template carrying a cycle
# works.
_run_case() {
    local _case_rc="$1" _case_reason="$2" _review_verdict="$3"
    local _case_tmp; _case_tmp="$(mktemp -d "$TEST_TEMP_DIR/case-XXXXXX")"

    (
        set +e
        export ZBUILD_EVENTS_DIR="$_case_tmp/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
        export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
        export ZBUILD_STATE_DIR="$_case_tmp/state"; mkdir -p "$ZBUILD_STATE_DIR"
        export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

        # Stub cycle orchestrator: return configured rc, set the LAST_TERMINATED_REASON
        # the way the real orchestrator does (see core/pipeline/cycle-orchestrator.sh).
        eval "cycle_orchestrator_run() {
            _CYCLE_LAST_TERMINATED_REASON=\"$_case_reason\"
            _CYCLE_LAST_ITERATIONS=3
            return $_case_rc
        }"
        # Stub plugin resolution: every stage maps to a valid plugin dir (the dir
        # is never dereferenced — plugin_hook_call is stubbed below). #979: the
        # retired `review` plugin dir is replaced by a KEEP-set dir; the synthetic
        # "review" stage name below is just the exemplar the rc→status contract is
        # driven with (cycle_orchestrator_run itself is stubbed, template-agnostic).
        _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/build"; }
        # Stub manifest verdict reader.
        eval "runner_read_stage_verdict() {
            local stage=\"\$3\"
            case \"\$stage\" in
                review) echo \"$_review_verdict\" ;;
                *)      echo \"pass\" ;;
            esac
        }"
        # Stub stage dispatch — write minimal artifacts for review, skip the rest.
        eval "plugin_hook_call() {
            local dir=\"\$1\" hook=\"\$2\" stage=\"\$3\" state=\"\$4\"
            local artdir
            artdir=\"\$(dirname \"\$state\")/artifacts\"
            mkdir -p \"\$artdir\"
            if [[ \"\$stage\" == \"review\" ]]; then
                printf '{\"schema_version\":1,\"verdict\":\"$_review_verdict\",\"confidence\":0.6,\"issues\":[],\"summary\":\"x\"}' > \"\$artdir/review.json\"
                eb_emit_event \"plugin.run.complete\" \"plugin=review\" \"verdict=$_review_verdict\" 2>/dev/null || true
            fi
            return 0
        }"

        main --issue 999 --template simple >/dev/null 2>&1
        printf '%s' "$?" > "$_case_tmp/runner.rc"
    )
    printf '%s' "$_case_tmp"
}

# ─── Case A: rc=1 (max_iterations) — the original silent-failure bug ───────────
A_DIR="$(_run_case 1 "max_iterations" "request_changes")"
A_STATE="$A_DIR/state/pipeline-state.json"
A_EVENTS="$A_DIR/events/events.jsonl"

assert_eq "A: pipeline_status=failed (NOT complete — the actual bug fix)" \
    "failed" "$(jq -r '.status' "$A_STATE" 2>/dev/null)"
# cycle_orchestrator_run is stubbed in this test, so no member stage state leaks
# out regardless of template shape. The pipeline_status assertion above (failed)
# is the core rc→status contract; the cycle.unconverged event assertion below is
# the rc→event contract. Both are engine-level (template-agnostic) and survive
# the #979 retirement of standard.yaml's outer build_review_cycle.
if grep -q '"type":"cycle.unconverged"' "$A_EVENTS" 2>/dev/null && \
   grep -q '"reason":"max_iterations"' "$A_EVENTS" 2>/dev/null; then
    assert_pass "A: cycle.unconverged event emitted with reason=max_iterations"
else
    assert_fail "A: cycle.unconverged event" "missing or wrong reason in $A_EVENTS"
fi
A_END_COUNT="$(grep -c '"type":"pipeline.end"' "$A_EVENTS" 2>/dev/null)"
[[ -z "$A_END_COUNT" ]] && A_END_COUNT=0
assert_eq "A: pipeline.end event fires exactly once" "1" "$A_END_COUNT"
_end_lines="$(grep '"type":"pipeline.end"' "$A_EVENTS" 2>/dev/null)" || true
if grep -q '"status":"failed"' <<< "$_end_lines"; then
    assert_pass "A: pipeline.end status=failed"
else
    assert_fail "A: pipeline.end status" "expected status=failed in pipeline.end event"
fi

# ─── Case B: rc=2 (plateau) — same shape, different reason ─────────────────────
B_DIR="$(_run_case 2 "plateau" "request_changes")"
B_STATE="$B_DIR/state/pipeline-state.json"
B_EVENTS="$B_DIR/events/events.jsonl"
assert_eq "B: rc=2 plateau → pipeline_status=failed" \
    "failed" "$(jq -r '.status' "$B_STATE" 2>/dev/null)"
if grep -q '"reason":"plateau"' "$B_EVENTS" 2>/dev/null; then
    assert_pass "B: cycle.unconverged reason=plateau"
else
    assert_fail "B: cycle.unconverged reason=plateau" "missing"
fi

# ─── Case C: rc=3 (divergence) — same shape ────────────────────────────────────
C_DIR="$(_run_case 3 "divergence" "request_changes")"
C_STATE="$C_DIR/state/pipeline-state.json"
C_EVENTS="$C_DIR/events/events.jsonl"
assert_eq "C: rc=3 divergence → pipeline_status=failed" \
    "failed" "$(jq -r '.status' "$C_STATE" 2>/dev/null)"
if grep -q '"reason":"divergence"' "$C_EVENTS" 2>/dev/null; then
    assert_pass "C: cycle.unconverged reason=divergence"
else
    assert_fail "C: cycle.unconverged reason=divergence" "missing"
fi

# ─── Case D: positive control — rc=0 converged + review approve → status=complete ─
D_DIR="$(_run_case 0 "converged" "approve")"
D_STATE="$D_DIR/state/pipeline-state.json"
D_EVENTS="$D_DIR/events/events.jsonl"
assert_eq "D: positive control — rc=0 converged + approve → status=complete" \
    "complete" "$(jq -r '.status' "$D_STATE" 2>/dev/null)"
D_UNCONV="$(grep -c '"type":"cycle.unconverged"' "$D_EVENTS" 2>/dev/null)"
[[ -z "$D_UNCONV" ]] && D_UNCONV=0
assert_eq "D: cycle.unconverged NOT emitted on converged path" "0" "$D_UNCONV"

# ─── Case E: rc=4 (config_invalid) — halt, review SKIPPED, status=interrupted ─
E_DIR="$(_run_case 4 "config_invalid" "approve")"
E_STATE="$E_DIR/state/pipeline-state.json"
assert_eq "E: rc=4 config_invalid → status=interrupted" \
    "interrupted" "$(jq -r '.status' "$E_STATE" 2>/dev/null)"
assert_eq "E: review SKIPPED on halt path" \
    "null" "$(jq -r '.stage_statuses.review // "null"' "$E_STATE" 2>/dev/null)"

# ─── Case F: rc=5 (blocked, #528) — halt, review SKIPPED, status=interrupted ───
F_DIR="$(_run_case 5 "blocked" "approve")"
F_STATE="$F_DIR/state/pipeline-state.json"
assert_eq "F: rc=5 blocked (#528) → status=interrupted" \
    "interrupted" "$(jq -r '.status' "$F_STATE" 2>/dev/null)"
assert_eq "F: review SKIPPED on rc=5 halt path" \
    "null" "$(jq -r '.stage_statuses.review // "null"' "$F_STATE" 2>/dev/null)"

# ─── Case G: rc=130 (aborted) — halt, review SKIPPED ───────────────────────────
G_DIR="$(_run_case 130 "aborted" "approve")"
G_STATE="$G_DIR/state/pipeline-state.json"
assert_eq "G: rc=130 aborted → status=interrupted" \
    "interrupted" "$(jq -r '.status' "$G_STATE" 2>/dev/null)"

print_test_results
