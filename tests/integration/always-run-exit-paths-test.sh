#!/usr/bin/env bash
# Integration: #1831 — an `always_run:` stage runs on EVERY exit path.
#
# This is the assertion the attribute exists for. A mechanism that fires on four
# of five exit paths is #1878's defect wearing a new name ("the snapshot was
# never called"), so each path gets its own case and names itself on failure —
# a single parameterised assertion would report "one of five" and leave the
# operator to find which.
#
# Paths covered: rc=0, rc=1, rc=130 (SIGINT), SIGTERM to the runner, and a
# release hook that hangs past its own timeout_s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "always_run dispatches on every exit path (#1831)"
setup_test_env "zb-always-run-exit"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0
export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$ZBUILD_EVENTS_DIR" "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

OVERLAY_REPO="$(setup_git_temp_repo always-run-overlay)"
install_template_overlay "$OVERLAY_REPO" always-run-minimal

# The always-run plugin, bound by ROLE (not by directory — that coupling is
# what #1831 removes). It touches a marker so "did it run?" is a file test
# rather than an inference from an event that might not be emitted.
mock_plugin_factory "outcome"  "agent" 0 "" ""         >/dev/null
mock_plugin_factory "teardown" "tool"  0 "" "teardown" >/dev/null

RELEASE_MARKER="$TEST_TEMP_DIR/release-ran"
RELEASE_ENTERED="$TEST_TEMP_DIR/release-entered"
_arm_release() {
    # Two markers, not one. ENTERED is written before the optional sleep,
    # RAN after it. With a single completion marker, "the watchdog killed a
    # hanging hook" and "the hook was never dispatched at all" are the same
    # observation — and SPEC-5 passed for that wrong reason during development,
    # before the dispatch worked at all.
    # $1 = optional `sleep N` injected between the two, for the watchdog case.
    cat > "$PLUGINS_ROOT/tool/teardown/plugin.sh" <<PLUG
teardown_run() {
    : > "${RELEASE_ENTERED}"
    ${1:-:}
    : > "${RELEASE_MARKER}"
    return 0
}
PLUG
}

_arm_outcome() {
    cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() {
    ${1:-:}
    return ${2:-0}
}
PLUG
}

# Each case gets its own state dir: a stale marker or state file from a prior
# case would make a later one pass for the wrong reason.
_run_case() {
    local name="$1" rc_want_set="$2"
    rm -f "$RELEASE_MARKER" "$RELEASE_ENTERED"
    export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-$name"
    mkdir -p "$ZBUILD_STATE_DIR"
    set +e
    ( cd "$OVERLAY_REPO" && bash "$RUNNER" --template always-run-minimal \
        --goal "always-run $name" ) >"$TEST_TEMP_DIR/$name.out" 2>&1
    _CASE_RC=$?
    set -e
    [[ "$rc_want_set" == "skip" ]] || true
}

# ─── [SPEC-1][change] rc=0 — the ordinary success path ──────────────────────
print_test_section "[SPEC-1][change] release runs when the pipeline succeeds"
_arm_release; _arm_outcome "" 0
_run_case "rc0" skip
assert_file_exists "[SPEC-1] release ran on rc=0" "$RELEASE_MARKER"

# ─── [SPEC-2][change] rc=1 — a failed run still frees its resources ─────────
# The failing path is the one that matters most: a run that died is exactly the
# run holding process groups and locks nobody else will clean up.
print_test_section "[SPEC-2][change] release runs when a stage fails"
_arm_release; _arm_outcome "" 1
_run_case "rc1" skip
assert_file_exists "[SPEC-2] release ran on a non-zero stage rc" "$RELEASE_MARKER"

# ─── [SPEC-3][change] rc=130 — the SIGINT path ─────────────────────────────
print_test_section "[SPEC-3][change] release runs on the SIGINT path (rc=130)"
_arm_release; _arm_outcome "" 130
_run_case "rc130" skip
assert_file_exists "[SPEC-3] release ran on rc=130" "$RELEASE_MARKER"

# ─── [SPEC-4][change] SIGTERM delivered to the runner itself ───────────────
# Distinct from rc=130: there the stage returned a code, here the signal is
# delivered to the runner process while a stage is still executing. #1759's
# re-armed INT/TERM traps are what give this path somewhere to hang off.
print_test_section "[SPEC-4][change] release runs when the runner is SIGTERMed mid-stage"
_arm_release; _arm_outcome "sleep 30" 0
rm -f "$RELEASE_MARKER" "$RELEASE_ENTERED"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-sigterm"
mkdir -p "$ZBUILD_STATE_DIR"
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template always-run-minimal \
    --goal "always-run sigterm" ) >"$TEST_TEMP_DIR/sigterm.out" 2>&1 &
_runner_pid=$!
# Wait for the run to actually reach the stage before signalling — signalling a
# runner still in startup would prove nothing about the exit path.
_waited=0
while [[ ! -f "$ZBUILD_STATE_DIR/pipeline-state.json" && $_waited -lt 100 ]]; do
    sleep 0.2; _waited=$(( _waited + 1 ))
done
sleep 1
kill -TERM "$_runner_pid" 2>/dev/null || true
wait "$_runner_pid" 2>/dev/null || true
# The trap runs in the dying process; give it a moment to land the marker.
_waited=0
while [[ ! -f "$RELEASE_MARKER" && $_waited -lt 50 ]]; do
    sleep 0.2; _waited=$(( _waited + 1 ))
done
assert_file_exists "[SPEC-4] release ran after SIGTERM to the runner" "$RELEASE_MARKER"

# ─── [SPEC-5][guard] a hanging release cannot hang the exit ────────────────
# The stage declares timeout_s: 2. A hook that blocks past it must be killed and
# the exit must continue — otherwise Ctrl-C becomes a lockup, which is the exact
# class of bug an EXIT-trap dispatch exists to avoid. Asserting the WALL CLOCK
# rather than the marker: the marker would also be absent if release never ran
# at all, so it cannot distinguish "bounded" from "broken".
print_test_section "[SPEC-5][guard] a release hook that hangs is bounded by its timeout_s"
_arm_release "sleep 60"; _arm_outcome "" 0
rm -f "$RELEASE_MARKER" "$RELEASE_ENTERED"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-hang"
mkdir -p "$ZBUILD_STATE_DIR"
_t0=$(date +%s)
set +e
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template always-run-minimal \
    --goal "always-run hang" ) >"$TEST_TEMP_DIR/hang.out" 2>&1
set -e
_elapsed=$(( $(date +%s) - _t0 ))
# 45s is generous against a 2s bound plus runner startup; the assertion is
# "bounded at all", not a tight budget — a tight one would flake under a loaded
# parallel pool (the #991 lesson).
if [[ "$_elapsed" -lt 45 ]]; then
    assert_pass "[SPEC-5] a 60s release hook did not hold the exit (${_elapsed}s)"
else
    assert_fail "[SPEC-5] a 60s release hook held the exit" "elapsed=${_elapsed}s"
fi
# These two together are what make the case meaningful: the hook WAS entered
# (so the bound is what stopped it) and did NOT complete (so it was actually
# killed). Either alone is satisfied by a dispatch that never happened.
assert_file_exists "[SPEC-5] the hanging hook was actually dispatched" "$RELEASE_ENTERED"
assert_file_not_exists "[SPEC-5] the hanging hook was killed before completing" "$RELEASE_MARKER"

# ─── [SPEC-6][guard] an unresolvable always-run role is LOUD ───────────────
# The code this replaces did `[[ -d "$_td_dir" ]] || return 0` — a missing
# plugin was a silent no-op. An always-run stage that cannot be resolved has not
# run, and the operator must be able to see that rather than infer it from a
# missing effect.
print_test_section "[SPEC-6][guard] an unresolvable role emits an event instead of failing silently"
_arm_outcome "" 0
rm -f "$RELEASE_MARKER"
rm -rf "$PLUGINS_ROOT/tool/teardown"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-unresolved"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/unresolved.jsonl"
mkdir -p "$ZBUILD_STATE_DIR"
set +e
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template always-run-minimal \
    --goal "always-run unresolved" ) >"$TEST_TEMP_DIR/unresolved.out" 2>&1
_unres_rc=$?
set -e
assert_event_emitted "[SPEC-6] stage.always_run.unresolved is emitted" \
    "$ZBUILD_EVENTS_JSONL" "stage.always_run.unresolved"
# And it must not change the run's fate — an always-run stage never decides the
# verdict, including when it could not be found.
assert_eq "[SPEC-6] an unresolvable always-run stage does not fail the run" "0" "$_unres_rc"

print_test_results
