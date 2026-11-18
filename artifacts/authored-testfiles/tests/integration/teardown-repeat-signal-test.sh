#!/usr/bin/env bash
# Integration: a second signal during teardown does not cut it short
# (ADR-054 §7, §11).
#
# Why: `timeout` sends its TERM twice — to the run, then to the run's whole
# process group — and an operator presses Ctrl-C twice. The first signal starts
# the EXIT trap; the always-run stages (release, persist) then run inside it.
# The trap put the run's own TERM handler back before dispatching them, so a
# second TERM arriving there ran that handler, whose `exit 1` ended the trap:
# the stages after it never ran. On ubuntu CI (2026-10-29, #2424 and #2423)
# runner-release-exit-paths SPEC-5 lost every release this way.
#
# T1 a TERM that arrives while release runs: release still finishes
# T2 ...and persist, the always-run stage after it, still runs
#
# A TERM can also land while the run's TERM handler is itself running: `timeout`
# sends a second, and a stage's or the run's watchdog TERMs the whole group. On
# Ubuntu's bash (5.2.21) a handler run inside a handler that was part-way
# through a command substitution broke the outer one off: the run carried on as
# if never signalled, ran the stage again, and was KILLed with nothing released
# (runner-release-exit-paths SPEC-5, 1 of 60 suite runs in diag run 42483294833). A TERM
# to the group also ends the handler's own command substitutions, which take the
# default TERM.
# T3 a group that keeps getting TERM from the moment the stage starts: the run
#    still ends through its handler (rc 1)
# T4 ...release finishes (T4a) and persist runs (T4b)
# T5 ...and the stage is not run again
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "a second signal during teardown does not cut it short (ADR-054 §7)"
setup_test_env "teardown-repeat-signal"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0 ZBUILD_SCOPE_OVERRIDE=1
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR" "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

REPO="$(setup_git_temp_repo teardown-repeat-signal)"
mkdir -p "$REPO/.zbuild/templates"
cat > "$REPO/.zbuild/templates/teardown-two.yaml" <<'EOF'
id: teardown-two
extends: simple
flow:
  - outcome
always_run:
  - release
  - persist
outcome:
  gate: auto
release:
  gate: auto
  roles: [teardown]
  timeout_s: 30
persist:
  gate: auto
  roles: [persist]
  timeout_s: 30
EOF
(cd "$REPO" && git add .zbuild && git commit -qm "teardown-two template") >/dev/null 2>&1

STARTED="$TEST_TEMP_DIR/outcome-started"
REL_IN="$TEST_TEMP_DIR/release-entered"; REL_OUT="$TEST_TEMP_DIR/release-finished"
PERSISTED="$TEST_TEMP_DIR/persist-ran"
mock_plugin_factory outcome agent 0 "" "" >/dev/null
mock_plugin_factory teardown tool 0 "" teardown >/dev/null
mock_plugin_factory persister tool 0 "" persist >/dev/null
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() { : > "$STARTED"; sleep 60; return 0; }
PLUG
# Release takes 3 s: long enough for the second TERM to land inside it.
cat > "$PLUGINS_ROOT/tool/teardown/plugin.sh" <<PLUG
teardown_run() { : > "$REL_IN"; sleep 3; : > "$REL_OUT"; return 0; }
PLUG
cat > "$PLUGINS_ROOT/tool/persister/plugin.sh" <<PLUG
persister_run() { : > "$PERSISTED"; return 0; }
PLUG

( cd "$REPO" && exec bash "$RUNNER" --template teardown-two --goal "teardown repeat signal" ) \
    > "$TEST_TEMP_DIR/run.out" 2>&1 &
RUNNER_PID=$!
for _ in $(seq 1 300); do [[ -e "$STARTED" ]] && break; sleep 0.1; done
kill -TERM "$RUNNER_PID" 2>/dev/null || true
for _ in $(seq 1 300); do [[ -e "$REL_IN" ]] && break; sleep 0.1; done
# The repeat: to the run itself, as `timeout` and a second Ctrl-C do.
kill -TERM "$RUNNER_PID" 2>/dev/null || true
for _ in $(seq 1 600); do kill -0 "$RUNNER_PID" 2>/dev/null || break; sleep 0.1; done
kill -KILL "$RUNNER_PID" 2>/dev/null || true
wait "$RUNNER_PID" 2>/dev/null || true

if [[ ! -e "$REL_IN" ]]; then
    assert_fail "[setup] release started" "$(tail -20 "$TEST_TEMP_DIR/run.out")"
fi
assert_file_exists "[T1] release finishes despite a second TERM" "$REL_OUT"
assert_file_exists "[T2] persist still runs after it" "$PERSISTED"

# ── T3–T5: TERM after TERM to the run's group, from the stage's start ──────
rm -f "$STARTED" "$REL_IN" "$REL_OUT" "$PERSISTED"
STARTS="$TEST_TEMP_DIR/outcome-starts"; : > "$STARTS"
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() { echo x >> "$STARTS"; : > "$STARTED"; sleep 60; return 0; }
PLUG
cat > "$PLUGINS_ROOT/tool/teardown/plugin.sh" <<PLUG
teardown_run() { : > "$REL_IN"; sleep 1; : > "$REL_OUT"; return 0; }
PLUG
set -m
( cd "$REPO" && exec bash "$RUNNER" --template teardown-two --goal "teardown signal storm" ) \
    > "$TEST_TEMP_DIR/storm.out" 2>&1 &
RUNNER_PID=$!
set +m
for _ in $(seq 1 300); do [[ -e "$STARTED" ]] && break; sleep 0.1; done
# Every 10 ms for 3 s: through the handler, the EXIT trap and release.
for _ in $(seq 1 300); do kill -TERM -- "-$RUNNER_PID" 2>/dev/null || break; sleep 0.01; done
for _ in $(seq 1 300); do kill -0 "$RUNNER_PID" 2>/dev/null || break; sleep 0.1; done
kill -KILL -- "-$RUNNER_PID" 2>/dev/null || true
_storm_rc=0; wait "$RUNNER_PID" 2>/dev/null || _storm_rc=$?
assert_eq "[T3] the run ends through its handler under repeated TERM (rc 1)" "1" "$_storm_rc"
assert_file_exists "[T4a] release finishes under repeated TERM" "$REL_OUT"
assert_file_exists "[T4b] persist runs under repeated TERM" "$PERSISTED"
assert_eq "[T5] the stage is not run again" "1" "$(grep -c x "$STARTS")"
[[ "$_storm_rc" == 1 && -e "$PERSISTED" ]] || tail -15 "$TEST_TEMP_DIR/storm.out" >&2

# ─── DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-9: cross-machine claim (ADR-005) ──────
#
# Verifies that runner.sh:
#   DSCLA-5: releases zbuild:claimed on normal pipeline exit
#   DSCLA-6: releases zbuild:claimed on pipeline failure exit
#   DSCLA-7: releases zbuild:claimed on TERM signal
#   DSCLA-9: outputs the holder string when refusing a claimed issue
#
# These tests FAIL on the code from before this change because runner.sh
# never calls zbuild_claim_acquire, so zbuild:claimed is never added to the
# claim store during a run.  The mid-run claim-present marker is therefore
# never written, and the assertion fails.
# ─────────────────────────────────────────────────────────────────────────────

# Claim-test infrastructure: one repo shared across all four scenarios.
_CLAIM_REPO="$(setup_git_temp_repo claim-dscla)"
mkdir -p "$_CLAIM_REPO/.zbuild/templates"
cat > "$_CLAIM_REPO/.zbuild/templates/claim-test.yaml" <<'CLAIMTPL'
id: claim-test
extends: simple
flow:
  - outcome
always_run: []
outcome:
  gate: auto
CLAIMTPL
(cd "$_CLAIM_REPO" && git add .zbuild && git commit -qm "add claim-test template") \
    >/dev/null 2>&1

mock_plugin_factory outcome agent 0 >/dev/null

export ZBUILD_CLAIM_BACKEND="local-fs"
export ZBUILD_CLAIM_STORE="$TEST_TEMP_DIR/claim-store-dscla"
export ZBUILD_CLAIM_BACKOFF_MIN_MS=5
export ZBUILD_CLAIM_BACKOFF_MAX_MS=15
export ZBUILD_NO_WORKTREE=1
export ZBUILD_NO_ISSUE_LOCK=1
mkdir -p "$ZBUILD_CLAIM_STORE"

_SRL="$REPO_ROOT/scripts/lib/stage-result.sh"

# ── Helper: prepare a fresh state+events dir for one claim scenario ──────────
_claim_prep() {
    local _label="$1"
    _CDIR="$TEST_TEMP_DIR/cscenario-$_label"
    mkdir -p "$_CDIR/state" "$_CDIR/events"
    export ZBUILD_STATE_DIR="$_CDIR/state"
    export ZBUILD_EVENTS_DIR="$_CDIR/events"
    export ZBUILD_EVENTS_JSONL="$_CDIR/events/events.jsonl"
}

# ── DSCLA-5: zbuild:claimed released on normal pipeline completion ────────────

# Given: the claim was acquired at run start (issue 90001764)
_DSCLA5_ISSUE="90001764"
_DSCLA5_PRESENT="$TEST_TEMP_DIR/dscla5-claim-present"
_DSCLA5_STARTED="$TEST_TEMP_DIR/dscla5-stage-started"
rm -f "$_DSCLA5_PRESENT" "$_DSCLA5_STARTED"

# Stage: checks for zbuild:claimed before writing result; completes normally
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() {
    # Check if zbuild:claimed is present before stage does any work [DSCLA-1]
    if grep -Fxq "zbuild:claimed" "$ZBUILD_CLAIM_STORE/$_DSCLA5_ISSUE/labels.txt" 2>/dev/null; then
        : > "$_DSCLA5_PRESENT"
    fi
    : > "$_DSCLA5_STARTED"
    local _art; _art="\${ZBUILD_ARTIFACT_DIR:-\$(dirname "\$2")/artifacts}"; mkdir -p "\$_art"
    source "$_SRL"
    stage_result_write "\$_art/outcome-result.json" "pass" "claim check ok"
    return 0
}
PLUG

_claim_prep "dscla5"

# When: the pipeline exits normally (_runner_ended=true)
( cd "$_CLAIM_REPO" && exec bash "$RUNNER" \
    --issue "$_DSCLA5_ISSUE" --no-resume \
    --template claim-test ) \
    > "$TEST_TEMP_DIR/dscla5.out" 2>&1
_dscla5_rc=$?

# Then: zbuild:claimed was present on the issue before the first stage ran
if [[ -e "$_DSCLA5_PRESENT" ]]; then
    assert_pass "[DSCLA-1] zbuild:claimed was present before the first stage dispatched"
else
    assert_fail "[DSCLA-1] zbuild:claimed was present before the first stage dispatched" \
        "claim never appeared in store; rc=$_dscla5_rc output=$(tail -5 "$TEST_TEMP_DIR/dscla5.out")"
fi

# Then: zbuild:claimed is absent from the issue after normal exit
# (gate on acquisition: if the claim was never added, release cannot be verified)
if [[ ! -e "$_DSCLA5_PRESENT" ]]; then
    assert_fail "[DSCLA-5] zbuild:claimed was never acquired — cannot verify release" \
        "claim never appeared in store; rc=$_dscla5_rc output=$(tail -5 "$TEST_TEMP_DIR/dscla5.out")"
elif ! grep -Fxq "zbuild:claimed" "$ZBUILD_CLAIM_STORE/$_DSCLA5_ISSUE/labels.txt" 2>/dev/null; then
    assert_pass "[DSCLA-5] zbuild:claimed absent after normal pipeline completion"
else
    assert_fail "[DSCLA-5] zbuild:claimed absent after normal pipeline completion" \
        "label still present in claim store after runner exit"
fi


# ── DSCLA-6: zbuild:claimed released on pipeline failure ─────────────────────

# Given: the claim was acquired at run start (issue 90001765)
_DSCLA6_ISSUE="90001765"
_DSCLA6_PRESENT="$TEST_TEMP_DIR/dscla6-claim-present"
rm -f "$_DSCLA6_PRESENT"

# Stage: checks for zbuild:claimed, then fails (stage failure triggers abort)
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() {
    if grep -Fxq "zbuild:claimed" "$ZBUILD_CLAIM_STORE/$_DSCLA6_ISSUE/labels.txt" 2>/dev/null; then
        : > "$_DSCLA6_PRESENT"
    fi
    local _art; _art="\${ZBUILD_ARTIFACT_DIR:-\$(dirname "\$2")/artifacts}"; mkdir -p "\$_art"
    source "$_SRL"
    stage_result_write "\$_art/outcome-result.json" "broken" "deliberate failure"
    return 1
}
PLUG

_claim_prep "dscla6"

# When: the pipeline exits due to a stage failure (_runner_abort_trap fires)
( cd "$_CLAIM_REPO" && exec bash "$RUNNER" \
    --issue "$_DSCLA6_ISSUE" --no-resume \
    --template claim-test ) \
    > "$TEST_TEMP_DIR/dscla6.out" 2>&1
_dscla6_rc=$?

# Then: zbuild:claimed was present before the stage ran
if [[ -e "$_DSCLA6_PRESENT" ]]; then
    assert_pass "[DSCLA-6] zbuild:claimed was present during failure run"
else
    assert_fail "[DSCLA-6] zbuild:claimed was present during failure run" \
        "claim never appeared in store; rc=$_dscla6_rc output=$(tail -5 "$TEST_TEMP_DIR/dscla6.out")"
fi

# Then: zbuild:claimed is absent after failure exit
# (gate on acquisition: if the claim was never added, release cannot be verified)
if [[ ! -e "$_DSCLA6_PRESENT" ]]; then
    assert_fail "[DSCLA-6] zbuild:claimed was never acquired — cannot verify release" \
        "claim never appeared in store; rc=$_dscla6_rc output=$(tail -5 "$TEST_TEMP_DIR/dscla6.out")"
elif ! grep -Fxq "zbuild:claimed" "$ZBUILD_CLAIM_STORE/$_DSCLA6_ISSUE/labels.txt" 2>/dev/null; then
    assert_pass "[DSCLA-6] zbuild:claimed absent after pipeline failure"
else
    assert_fail "[DSCLA-6] zbuild:claimed absent after pipeline failure" \
        "label still present after failure exit"
fi


# ── DSCLA-7: zbuild:claimed released on TERM signal ──────────────────────────

# Given: the claim was acquired at run start (issue 90001766)
_DSCLA7_ISSUE="90001766"
_DSCLA7_PRESENT="$TEST_TEMP_DIR/dscla7-claim-present"
_DSCLA7_STARTED="$TEST_TEMP_DIR/dscla7-stage-started"
rm -f "$_DSCLA7_PRESENT" "$_DSCLA7_STARTED"

# Stage: checks for zbuild:claimed, writes marker, then sleeps (waits for TERM)
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() {
    if grep -Fxq "zbuild:claimed" "$ZBUILD_CLAIM_STORE/$_DSCLA7_ISSUE/labels.txt" 2>/dev/null; then
        : > "$_DSCLA7_PRESENT"
    fi
    : > "$_DSCLA7_STARTED"
    sleep 60
    local _art; _art="\${ZBUILD_ARTIFACT_DIR:-\$(dirname "\$2")/artifacts}"; mkdir -p "\$_art"
    source "$_SRL"
    stage_result_write "\$_art/outcome-result.json" "pass" "claim check ok"
    return 0
}
PLUG

_claim_prep "dscla7"

# When: the runner process receives SIGTERM (_runner_signal_trap then _runner_abort_trap)
( cd "$_CLAIM_REPO" && exec bash "$RUNNER" \
    --issue "$_DSCLA7_ISSUE" --no-resume \
    --template claim-test ) \
    > "$TEST_TEMP_DIR/dscla7.out" 2>&1 &
_DSCLA7_PID=$!

# Wait for the stage to have started (which means claim was acquired before it)
for _ in $(seq 1 300); do [[ -e "$_DSCLA7_STARTED" ]] && break; sleep 0.1; done

kill -TERM "$_DSCLA7_PID" 2>/dev/null || true
for _ in $(seq 1 300); do kill -0 "$_DSCLA7_PID" 2>/dev/null || break; sleep 0.1; done
kill -KILL "$_DSCLA7_PID" 2>/dev/null || true
wait "$_DSCLA7_PID" 2>/dev/null || true

if [[ ! -e "$_DSCLA7_STARTED" ]]; then
    assert_fail "[setup-DSCLA-7] stage started before TERM" \
        "$(tail -10 "$TEST_TEMP_DIR/dscla7.out")"
fi

# Then: zbuild:claimed was present before the stage ran
if [[ -e "$_DSCLA7_PRESENT" ]]; then
    assert_pass "[DSCLA-7] zbuild:claimed was present before stage started"
else
    assert_fail "[DSCLA-7] zbuild:claimed was present before stage started" \
        "claim never appeared in store"
fi

# Then: zbuild:claimed is absent after TERM exit
# (gate on acquisition: if the claim was never added, release cannot be verified)
if [[ ! -e "$_DSCLA7_PRESENT" ]]; then
    assert_fail "[DSCLA-7] zbuild:claimed was never acquired — cannot verify release after TERM" \
        "claim never appeared in store"
elif ! grep -Fxq "zbuild:claimed" "$ZBUILD_CLAIM_STORE/$_DSCLA7_ISSUE/labels.txt" 2>/dev/null; then
    assert_pass "[DSCLA-7] zbuild:claimed absent after TERM signal"
else
    assert_fail "[DSCLA-7] zbuild:claimed absent after TERM signal" \
        "label still present after TERM"
fi


# ── DSCLA-9: runner output contains holder string when zbuild:claimed present ─

# Given: zbuild:claimed on the issue and a claim comment with a holder string
_DSCLA9_ISSUE="90001767"
_DSCLA9_HOLDER="run-holder-9abc on machine-other"
_DSCLA9_STARTED="$TEST_TEMP_DIR/dscla9-stage-started"
rm -f "$_DSCLA9_STARTED"

# Pre-populate the claim store: label + holder
mkdir -p "$ZBUILD_CLAIM_STORE/$_DSCLA9_ISSUE"
printf 'zbuild:claimed\n' > "$ZBUILD_CLAIM_STORE/$_DSCLA9_ISSUE/labels.txt"
# Run-status comment with <!-- zbuild-holder: --> field (the holder's run wrote this via run-status-comment.sh)
cat > "$ZBUILD_CLAIM_STORE/$_DSCLA9_ISSUE/run-status-comment.txt" <<EOF
<!-- zbuild-run-status run_id=holder-run-prev -->
<!-- zbuild-holder: $_DSCLA9_HOLDER -->
run is in progress
EOF

# Stage: writes marker if dispatched (must NOT be dispatched for DSCLA-9 to pass)
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() {
    : > "$_DSCLA9_STARTED"
    local _art; _art="\${ZBUILD_ARTIFACT_DIR:-\$(dirname "\$2")/artifacts}"; mkdir -p "\$_art"
    source "$_SRL"
    stage_result_write "\$_art/outcome-result.json" "pass" "should not reach here"
    return 0
}
PLUG

_claim_prep "dscla9"

# When: the runner is started on that issue
( cd "$_CLAIM_REPO" && exec bash "$RUNNER" \
    --issue "$_DSCLA9_ISSUE" --no-resume \
    --template claim-test ) \
    > "$TEST_TEMP_DIR/dscla9.out" 2>&1
_dscla9_rc=$?

# Then: the runner's stdout or stderr output contains the holder string
if grep -qF "$_DSCLA9_HOLDER" "$TEST_TEMP_DIR/dscla9.out" 2>/dev/null; then
    assert_pass "[DSCLA-9] runner output contains holder string when zbuild:claimed is present"
else
    assert_fail "[DSCLA-9] runner output contains holder string when zbuild:claimed is present" \
        "holder '$_DSCLA9_HOLDER' not found in: $(cat "$TEST_TEMP_DIR/dscla9.out" 2>/dev/null)"
fi

# Then: runner exits non-zero before any stage is dispatched
if [[ "$_dscla9_rc" -ne 0 ]]; then
    assert_pass "[DSCLA-9] runner exits non-zero when zbuild:claimed is present"
else
    assert_fail "[DSCLA-9] runner exits non-zero when zbuild:claimed is present" \
        "runner exited 0 (should have refused)"
fi
if [[ "$_dscla9_rc" -ne 0 ]]; then
    assert_pass "[DSCLA-3] runner exits non-zero when zbuild:claimed is present"
else
    assert_fail "[DSCLA-3] runner exits non-zero when zbuild:claimed is present" \
        "runner exited 0 (should have refused)"
fi

# And: no stage was dispatched
if [[ ! -e "$_DSCLA9_STARTED" ]]; then
    assert_pass "[DSCLA-9] no stage was dispatched when runner refused the claim"
else
    assert_fail "[DSCLA-9] no stage was dispatched when runner refused the claim" \
        "stage started marker found — runner dispatched a stage after refusing"
fi
if [[ ! -e "$_DSCLA9_STARTED" ]]; then
    assert_pass "[DSCLA-3] no stage was dispatched when runner refused the claim"
else
    assert_fail "[DSCLA-3] no stage was dispatched when runner refused the claim" \
        "stage started marker found — runner dispatched a stage after refusing"
fi

# Then: pipeline.refused.claimed event was emitted to the event bus
if grep -qF '"pipeline.refused.claimed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[DSCLA-3] pipeline.refused.claimed event emitted to event bus"
else
    assert_fail "[DSCLA-3] pipeline.refused.claimed event emitted to event bus" \
        "event not found in events log; log contents: $(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -20 || echo '<empty>')"
fi

# ── DSCLA-11: run-status comment shows terminal status when runner exits ──────
#
# This requirement is [done] — the existing rsc_render_header already shows a
# terminal status when pipeline.end or pipeline.abort is in the events.  The
# test must pass on both old and new code.

# Given: an events.jsonl with pipeline.start + pipeline.end (normal exit path)
_dscla11_state="$TEST_TEMP_DIR/dscla11-state"
mkdir -p "$_dscla11_state"
_dscla11_events="$_dscla11_state/events.jsonl"
printf '{"type":"pipeline.start","data":{"run_id":"dscla11-run","issue":88880000},"ts":"2026-01-01T00:00:00Z"}\n' \
    > "$_dscla11_events"
printf '{"type":"pipeline.end","data":{"status":"pass","run_id":"dscla11-run"},"ts":"2026-01-01T00:01:00Z"}\n' \
    >> "$_dscla11_events"

# When: the run-status body is rendered (same path the sidecar uses)
# shellcheck source=../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"
_dscla11_model="$(rsc_rows_json "$_dscla11_events" 2>/dev/null || printf '{}')"
_dscla11_header="$(rsc_render_header "$_dscla11_model" "$_dscla11_state" 2>/dev/null || printf '')"

# Then: the status header is not "running"
if grep -qF '**running**' <<< "${_dscla11_header:-}"; then
    assert_fail "[DSCLA-11] run-status comment does not show 'running' when pipeline.end is present" \
        "header shows running — expected terminal; header: ${_dscla11_header:0:200}"
else
    assert_pass "[DSCLA-11] run-status comment does not show 'running' when pipeline.end is present"
fi

# Given: an events.jsonl with pipeline.start + pipeline.abort (failure exit path)
_dscla11_abort_events="$_dscla11_state/abort-events.jsonl"
printf '{"type":"pipeline.start","data":{"run_id":"dscla11-abort","issue":88880001},"ts":"2026-01-01T00:00:00Z"}\n' \
    > "$_dscla11_abort_events"
printf '{"type":"pipeline.abort","data":{"status":"broken"},"ts":"2026-01-01T00:01:00Z"}\n' \
    >> "$_dscla11_abort_events"

# When: rendered for a failed run
_dscla11_am="$(rsc_rows_json "$_dscla11_abort_events" 2>/dev/null || printf '{}')"
_dscla11_ah="$(rsc_render_header "$_dscla11_am" "$_dscla11_state" 2>/dev/null || printf '')"

# Then: the status header is not "running"
if grep -qF '**running**' <<< "${_dscla11_ah:-}"; then
    assert_fail "[DSCLA-11] run-status comment does not show 'running' on pipeline failure" \
        "header shows running — expected terminal; header: ${_dscla11_ah:0:200}"
else
    assert_pass "[DSCLA-11] run-status comment does not show 'running' on pipeline failure"
fi

# Given: an events.jsonl with only pipeline.start (no terminal event, as on TERM signal)
_dscla11_signal_events="$_dscla11_state/signal-events.jsonl"
printf '{"type":"pipeline.start","data":{"run_id":"dscla11-signal","issue":88880002},"ts":"2026-01-01T00:00:00Z"}\n' \
    > "$_dscla11_signal_events"

# When: the sidecar renders with "interrupted" override (which the sidecar does on TERM with no terminal event)
_dscla11_sigm="$(rsc_rows_json "$_dscla11_signal_events" 2>/dev/null || printf '{}')"
_dscla11_sigh="$(rsc_render_header "$_dscla11_sigm" "$_dscla11_state" "interrupted" 2>/dev/null || printf '')"

# Then: the status header is not "running"
if grep -qF '**running**' <<< "${_dscla11_sigh:-}"; then
    assert_fail "[DSCLA-11] run-status comment does not show 'running' on TERM signal exit" \
        "header shows running; header: ${_dscla11_sigh:0:200}"
else
    assert_pass "[DSCLA-11] run-status comment does not show 'running' on TERM signal exit"
fi

# ── DSCLA-13: second SIGTERM during abort trap does not prevent claim release ──
#
# Tests that when _runner_abort_trap blocks SIGTERM (via trap '' TERM) and a
# second SIGTERM arrives while zbuild_claim_release is executing inside the
# trap, zbuild:claimed is still removed from the issue.
#
# This test FAILS on base code: runner.sh never calls zbuild_claim_acquire,
# so zbuild:claimed is never added to the claim store, and the acquisition
# gate assertion fails.

# Given: the claim was acquired at run start (issue 90001769)
_DSCLA13_ISSUE="90001769"
_DSCLA13_PRESENT="$TEST_TEMP_DIR/dscla13-claim-present"
_DSCLA13_STARTED="$TEST_TEMP_DIR/dscla13-stage-started"
_DSCLA13_ABORT_ENTERED="$TEST_TEMP_DIR/dscla13-abort-entered"
rm -f "$_DSCLA13_PRESENT" "$_DSCLA13_STARTED" "$_DSCLA13_ABORT_ENTERED"

# Add a template with an always-run teardown stage to the claim repo.
# The teardown stage's entry marker confirms we are inside _runner_abort_trap
# with SIGTERM already blocked, so the second SIGTERM lands during trap execution.
cat > "$_CLAIM_REPO/.zbuild/templates/claim-dscla13.yaml" <<'CLAIMTPL'
id: claim-dscla13
extends: simple
flow:
  - outcome
always_run:
  - release
outcome:
  gate: auto
release:
  gate: auto
  roles: [teardown]
  timeout_s: 30
CLAIMTPL
(cd "$_CLAIM_REPO" && git add .zbuild && git commit -qm "add claim-dscla13 template") \
    >/dev/null 2>&1

# Outcome: gate on zbuild:claimed being present, write started, sleep until SIGTERM
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() {
    if grep -Fxq "zbuild:claimed" "$ZBUILD_CLAIM_STORE/$_DSCLA13_ISSUE/labels.txt" 2>/dev/null; then
        : > "$_DSCLA13_PRESENT"
    fi
    : > "$_DSCLA13_STARTED"
    sleep 60
    return 0
}
PLUG

# Teardown (release stage): write abort-entered marker, then sleep 3 s.
# While it sleeps the second SIGTERM arrives; zbuild_claim_release also
# executes in _runner_abort_trap alongside this stage.
cat > "$PLUGINS_ROOT/tool/teardown/plugin.sh" <<PLUG
teardown_run() { : > "$_DSCLA13_ABORT_ENTERED"; sleep 3; return 0; }
PLUG

_claim_prep "dscla13"

# When: the runner process receives a first SIGTERM (enters _runner_abort_trap,
# blocks SIGTERM via trap '' TERM), then a second SIGTERM arrives while
# zbuild_claim_release is executing inside _runner_abort_trap.
( cd "$_CLAIM_REPO" && exec bash "$RUNNER" \
    --issue "$_DSCLA13_ISSUE" --no-resume \
    --template claim-dscla13 ) \
    > "$TEST_TEMP_DIR/dscla13.out" 2>&1 &
_DSCLA13_PID=$!

# Wait for outcome stage to start: zbuild_claim_acquire fired before first stage
for _ in $(seq 1 300); do [[ -e "$_DSCLA13_STARTED" ]] && break; sleep 0.1; done

# Given: the runner has entered _runner_abort_trap and blocked SIGTERM via trap '' TERM
kill -TERM "$_DSCLA13_PID" 2>/dev/null || true

# Wait for the teardown (release) stage to enter: we are inside _runner_abort_trap
for _ in $(seq 1 300); do [[ -e "$_DSCLA13_ABORT_ENTERED" ]] && break; sleep 0.1; done

# When: second SIGTERM arrives while zbuild_claim_release is executing inside the trap
kill -TERM "$_DSCLA13_PID" 2>/dev/null || true

for _ in $(seq 1 600); do kill -0 "$_DSCLA13_PID" 2>/dev/null || break; sleep 0.1; done
kill -KILL "$_DSCLA13_PID" 2>/dev/null || true
wait "$_DSCLA13_PID" 2>/dev/null || true

# Setup check: outcome stage started (first SIGTERM arrived while outcome was running)
if [[ ! -e "$_DSCLA13_STARTED" ]]; then
    assert_fail "[setup-DSCLA-13] outcome stage started before first SIGTERM" \
        "$(tail -10 "$TEST_TEMP_DIR/dscla13.out")"
fi

# Then: zbuild:claimed is absent from the issue after the runner exits
# Gate on acquisition: if claim was never acquired (base code), report that
if [[ ! -e "$_DSCLA13_PRESENT" ]]; then
    assert_fail "[DSCLA-13] zbuild:claimed was never acquired — cannot verify release after second SIGTERM" \
        "claim never appeared in store; output=$(tail -5 "$TEST_TEMP_DIR/dscla13.out")"
elif ! grep -Fxq "zbuild:claimed" "$ZBUILD_CLAIM_STORE/$_DSCLA13_ISSUE/labels.txt" 2>/dev/null; then
    assert_pass "[DSCLA-13] zbuild:claimed absent after second SIGTERM during abort trap"
else
    assert_fail "[DSCLA-13] zbuild:claimed absent after second SIGTERM during abort trap" \
        "label still present in claim store after runner exit with second SIGTERM"
fi

# ─────────────────────────────────────────────────────────────────────────────
# End of DSCLA claim tests
# ─────────────────────────────────────────────────────────────────────────────
print_test_results
exit $((FAIL > 0))
