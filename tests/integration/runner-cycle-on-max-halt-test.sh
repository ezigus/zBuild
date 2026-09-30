#!/usr/bin/env bash
# Integration test (#2241): a cycle marked `on_max: halt` that runs out of rounds
# STOPS the run — no later stage runs.
#
# Why: #1842 run 20260930034047-2413. design_verify_cycle is `on_max: halt`
# (simple.yaml, #2176). Its design never passed spec-coverage in 3 rounds, yet the
# runner logged "continuing to next dispatch unit", built the change, passed every
# gate, opened a PR that closes the issue — and only then marked the run failed.
# runner.sh handled every unconverged cycle (rc 1/2/3) by warning and continuing;
# `on_max` was read only for the final status. The #2176 test checked the template
# SAID halt; nothing checked the runner stopped.
#
# H1 [change] halt + the cycle out of rounds → the next unit (review) is NOT
#             dispatched; status failed; pipeline.end names the cycle and reason
# H2 [guard]  continue + the cycle out of rounds → review IS dispatched (#527)
# H3 [change] `abort` (the old word runner-final-status used) behaves as halt
# H4 [guard]  halt + the cycle converged (rc 0) → review IS dispatched
# H5 [change] a failing event bus does not kill the halt path before it records
#             the run's end (review #2247: the emit was unguarded under set -e)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a cycle marked on_max: halt stops the run (#2241)"
setup_test_env "cycle-on-max-halt"

_ZB_ISSUE="$(zb_test_issue)"
_ZB_REPO="$(zb_test_repo cycle-halt)"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/_source_once_events"
set +e
cd "$_ZB_REPO" || exit 1
# shellcheck disable=SC1091
source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null
set +e

OVERLAY_REPO="$(setup_git_temp_repo cycle-halt-overlay)"
install_template_overlay "$OVERLAY_REPO" cycle-halt-minimal cycle-fallthrough-minimal cycle-abort-minimal

# _run <template> <cycle_rc> <reason> → prints the case dir. Records every stage
# the runner dispatches in <dir>/dispatched.
_run() {
    local tpl="$1" crc="$2" reason="$3" extra="${4:-}" d
    mkdir -p "$TEST_TEMP_DIR"
    d="$(mktemp -d "$TEST_TEMP_DIR/case-XXXXXX")"
    (
        set +e
        export ZBUILD_EVENTS_DIR="$d/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
        export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
        export ZBUILD_STATE_DIR="$d/state"; mkdir -p "$ZBUILD_STATE_DIR"
        export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
        eval "cycle_orchestrator_run() {
            _CYCLE_LAST_TERMINATED_REASON=\"$reason\"
            _CYCLE_LAST_ITERATIONS=3
            return $crc
        }"
        _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/build"; }
        runner_read_stage_verdict() { echo "pass"; }
        eval "plugin_hook_call() {
            printf '%s\n' \"\$3\" >> '$d/dispatched'
            mkdir -p \"\$(dirname \"\$4\")/artifacts\"
            return 0
        }"
        [[ -n "$extra" ]] && eval "$extra"
        cd "$OVERLAY_REPO" || exit 1
        main --issue "$_ZB_ISSUE" --template "$tpl" > "$d/runner.log" 2>&1
        printf '%s' "$?" > "$d/runner.rc"
    )
    printf '%s' "$d"
}
_dispatched() { grep -cx "$2" "$1/dispatched" 2>/dev/null || true; }
_end_event() { grep '"pipeline.end"' "$1/events/events.jsonl" 2>/dev/null | tail -1; }

print_test_section "H1: halt stops the run"
H1="$(_run cycle-halt-minimal 2 max_iterations)"
assert_eq "[H1] the next unit (review) is not dispatched" "0" "$(_dispatched "$H1" review)"
assert_eq "[H1] the run's status is failed" "failed" "$(jq -r '.status // empty' "$H1/state/pipeline-state.json" 2>/dev/null)"
assert_contains "[H1] pipeline.end names the cycle" "$(_end_event "$H1")" "build_test_cycle"
assert_contains "[H1] ...and why it stopped" "$(_end_event "$H1")" "max_iterations"
assert_eq "[H1] the runner exits non-zero" "1" "$([[ "$(cat "$H1/runner.rc" 2>/dev/null)" != 0 ]] && echo 1 || echo 0)"

print_test_section "H2: continue still carries on"
H2="$(_run cycle-fallthrough-minimal 2 max_iterations)"
assert_eq "[H2] with on_max: continue the next unit (review) is dispatched" "1" "$(_dispatched "$H2" review)"

print_test_section "H3: abort is the old word for halt"
H3="$(_run cycle-abort-minimal 2 max_iterations)"
assert_eq "[H3] on_max: abort stops the run too" "0" "$(_dispatched "$H3" review)"

print_test_section "H4: a converged halt cycle carries on"
H4="$(_run cycle-halt-minimal 0 converged)"
assert_eq "[H4] a halt cycle that converged does not stop the run" "1" "$(_dispatched "$H4" review)"

print_test_section "H5: a failing event bus"
# Only the halt path's pipeline.end emit fails — every other event still works,
# so the run reaches the halt block as it would in production — and under
# `set -e`, as runner.sh runs (this harness otherwise runs main with it off).
H5="$(_run cycle-halt-minimal 2 max_iterations 'eval "$(declare -f eb_emit_event | sed "1s/eb_emit_event/_zb_real_emit/")"; eb_emit_event() { [[ "$1" == pipeline.end ]] && return 1; _zb_real_emit "$@"; }; set -e')"
assert_eq "[H5] review is still not dispatched" "0" "$(_dispatched "$H5" review)"
assert_contains "[H5] the halt path runs to its end (its message is printed)" \
    "$(cat "$H5/runner.log" 2>/dev/null)" "the run stops here"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
