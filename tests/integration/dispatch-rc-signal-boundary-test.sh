#!/usr/bin/env bash
# Integration: a stage that is ACTUALLY killed by a signal resolves to
# `interrupted`, not `broken` (#1823, ADR-054 §4).
#
# This drives the real subprocess boundary — `plugin_hook_call` sources the
# plugin in an isolated subshell and returns its wait status — rather than
# asserting against a hand-written number. The distinction matters: the whole
# mechanism depends on a real signal death surfacing as 128+N through that
# subshell, and a unit test that passes `143` by hand proves nothing about
# whether the engine ever sees a 143.
#
# The regression it guards: before #1823 every dispatch that returned non-zero
# and left no result was flatly `broken`, and `broken` halts. A stage killed by
# a passing SIGTERM — a CI runner reclaiming a job, an operator's Ctrl-C, an
# OOM killer — was reported as a defect and stopped the run. `interrupted` is
# what lets the engine retry it instead, which is why #1798 (make a failing leaf
# stage terminal) is gated on this issue: without the split, making failures
# terminal turns every transient signal into a dead run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "dispatch-rc: a signalled stage is interrupted, not broken (#1823)"
setup_test_env "dispatch-rc-signal-boundary"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR/artifacts"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/dispatch-rc.sh
source "$REPO_ROOT/core/pipeline/dispatch-rc.sh"
# shellcheck source=../../core/pipeline/disposition.sh
source "$REPO_ROOT/core/pipeline/disposition.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../scripts/lib/router-rc-classify.sh
source "$REPO_ROOT/scripts/lib/router-rc-classify.sh"

_rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

# Build a stub stage whose `run` hook does <body>. It declares a primary output
# and never writes it, so every case here is "rc non-zero, nothing to read" —
# the exact shape #1823 classifies.
_mkstage() {
    local id="$1"
    local body="$2"
    local dir="$TEST_TEMP_DIR/$id"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Stub $id
kind: tool
version: 0.0.1
hooks:
  run: ${id}_run
outputs:
  - id: result
    path: \${artifact_dir}/${id}-result.json
    primary: true
EOF
    cat > "$dir/plugin.sh" <<EOF
${id}_run() { $body }
EOF
    printf '%s' "$dir"
}

# Reproduce the dispatch boundary exactly as core/pipeline/runner.sh's
# cycle_dispatch_stage does: clear the marker, dispatch, read the RAW status,
# take the observation, narrow, then ask the reader.
_dispatch() {
    local dir="$1" id="$2" raw=0
    _router_clear_throttle_marker
    set +e
    plugin_hook_call "$dir" run "$id" "$ZBUILD_STATE_DIR/pipeline-state.json" >/dev/null 2>&1
    raw=$?
    set -e
    _LAST_RAW_RC="$raw"
    _LAST_OBSERVATION="$(dispatch_rc_observation "$raw")"
    _LAST_RATE_LIMITED=0
    if _router_throttle_observed; then _LAST_RATE_LIMITED=1; fi
    _LAST_NARROW_RC="$(dispatch_rc_narrow "$raw")"
    _LAST_DISPOSITION="$(runner_read_stage_disposition \
        "$ZBUILD_STATE_DIR" "$dir/manifest.yaml" "$id" \
        "$_LAST_NARROW_RC" "$_LAST_OBSERVATION" "$_LAST_RATE_LIMITED")"
}

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "1. SIGTERM — the stage really is killed"

_d="$(_mkstage sigterm_stage 'kill -TERM $BASHPID; sleep 5;')"
_dispatch "$_d" sigterm_stage

# Prove the premise before asserting the conclusion. If the stub exited 1
# normally, every assertion below would still pass while testing nothing.
assert_eq "[SPEC-1] the subshell really died by SIGTERM (raw rc 143)" "143" "$_LAST_RAW_RC"
assert_eq "[SPEC-1] the boundary observes a signal" "signal" "$_LAST_OBSERVATION"
assert_eq "[SPEC-1] rc narrows to 1 at the contract boundary" "1" "$_LAST_NARROW_RC"
assert_eq "[SPEC-1] a killed stage is interrupted, NOT broken" "interrupted" "$_LAST_DISPOSITION"
assert_eq "[SPEC-1] and therefore the engine retries rather than halting" \
    "retry" "$(disposition_response "$_LAST_DISPOSITION")"
assert_eq "[SPEC-1] interrupted does not halt the run" \
    "1" "$(_rc_of disposition_halts "$_LAST_DISPOSITION")"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "2. SIGINT — the Ctrl-C shape"

_d="$(_mkstage sigint_stage 'kill -INT $BASHPID; sleep 5;')"
_dispatch "$_d" sigint_stage
assert_eq "[SPEC-2] the subshell really died by SIGINT (raw rc 130)" "130" "$_LAST_RAW_RC"
assert_eq "[SPEC-2] a Ctrl-C'd stage is interrupted" "interrupted" "$_LAST_DISPOSITION"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "3. SIGKILL — the OOM-killer shape"

_d="$(_mkstage sigkill_stage 'kill -KILL $BASHPID; sleep 5;')"
_dispatch "$_d" sigkill_stage
assert_eq "[SPEC-3] the subshell really died by SIGKILL (raw rc 137)" "137" "$_LAST_RAW_RC"
assert_eq "[SPEC-3] an OOM-killed stage is interrupted" "interrupted" "$_LAST_DISPOSITION"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "4. The negative control — an ordinary failure still halts"

# Without this, sections 1-3 would pass for an implementation that called
# everything `interrupted`, which would be strictly worse than the bug: a real
# defect would retry forever.
_d="$(_mkstage plain_fail_stage 'return 1;')"
_dispatch "$_d" plain_fail_stage
assert_eq "[SPEC-4] an ordinary failure exits 1, not a signal code" "1" "$_LAST_RAW_RC"
assert_eq "[SPEC-4] nothing is observed" "" "$_LAST_OBSERVATION"
assert_eq "[SPEC-4] an unexplained failure is still broken" "broken" "$_LAST_DISPOSITION"
assert_eq "[SPEC-4] and therefore still halts the run" \
    "halt_broken" "$(disposition_response "$_LAST_DISPOSITION")"
assert_eq "[SPEC-4] broken halts" "0" "$(_rc_of disposition_halts "$_LAST_DISPOSITION")"

# A large non-signal rc must NOT be read as a signal death.
_d="$(_mkstage big_rc_stage 'return 200;')"
_dispatch "$_d" big_rc_stage
assert_eq "[SPEC-4] rc 200 is above the signal ceiling" "200" "$_LAST_RAW_RC"
assert_eq "[SPEC-4] rc 200 observes nothing" "" "$_LAST_OBSERVATION"
assert_eq "[SPEC-4] rc 200 is broken, not interrupted" "broken" "$_LAST_DISPOSITION"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "5. A stage that wrote a result keeps its own word"

# rc fills the silence; it never overwrites a declaration. A stage killed AFTER
# writing a v2 result is not re-classified — the engine's inference applies only
# where the stage said nothing.
_d="$(_mkstage spoke_then_died '
    printf %s "{\"result_contract\":2,\"verdict\":\"fail\",\"disposition\":\"exhausted\",\"reason\":\"budget\"}" \
        > "$ZBUILD_STATE_DIR/artifacts/spoke_then_died-result.json"
    kill -TERM $BASHPID; sleep 5;')"
_dispatch "$_d" spoke_then_died
assert_eq "[SPEC-5] it really was killed (raw rc 143)" "143" "$_LAST_RAW_RC"
assert_eq "[SPEC-5] the declared word survives the signal" "exhausted" "$_LAST_DISPOSITION"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "6. A rate-limited dispatch is throttled"

# The router arms the marker from inside the plugin's subshell — which is the
# whole reason it is a file. A global set there would not survive to here, and
# the engine would classify a 429 as `broken` and halt a run that only needed
# to wait.
_d="$(_mkstage throttled_stage '
    source "'"$REPO_ROOT"'/scripts/lib/router-rc-classify.sh"
    _router_arm_throttle_marker "LLM rate-limited — resets 5pm"
    return 1;')"
_dispatch "$_d" throttled_stage
assert_eq "[SPEC-6] the marker crossed the subshell boundary" "1" "$_LAST_RATE_LIMITED"
assert_eq "[SPEC-6] a rate-limited stage is throttled, not broken" "throttled" "$_LAST_DISPOSITION"
assert_eq "[SPEC-6] and the engine waits before retrying" \
    "retry_after_wait" "$(disposition_response "$_LAST_DISPOSITION")"
assert_gt "[SPEC-6] the wait is non-zero" "$(disposition_wait_s "$_LAST_DISPOSITION")" "0"

# The marker must not leak into the NEXT dispatch. A stale marker would classify
# an unrelated later failure as throttled — and throttled retries, so one rate
# limit would become a retry loop on a genuine defect.
_d="$(_mkstage after_throttle_stage 'return 1;')"
_dispatch "$_d" after_throttle_stage
assert_eq "[SPEC-6] the marker did NOT leak into the next dispatch" "0" "$_LAST_RATE_LIMITED"
assert_eq "[SPEC-6] so the next unexplained failure is broken again" "broken" "$_LAST_DISPOSITION"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
