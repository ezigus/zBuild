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
    # #1862: the runner's caller exports the member stage BEFORE the sequence
    # below — cycle-orchestrator.sh:1466 `export ZBUILD_CURRENT_STAGE="$s"`,
    # then :1714 `cycle_dispatch_stage "$s"`. This helper omitted it, which was
    # the "convenient approximation" the comment above warns against: the
    # throttle marker's path is keyed on the stage (router-rc-classify.sh:154),
    # so clear/observe ran unscoped here while production runs them scoped.
    # Exporting it makes the key identical inside and outside the dispatch,
    # which is what production does.
    export ZBUILD_CURRENT_STAGE="$id"
    _router_clear_throttle_marker
    set +e
    plugin_hook_call "$dir" run "$id" "$ZBUILD_STATE_DIR/pipeline-state.json" >/dev/null 2>&1
    raw=$?
    set -e
    _LAST_RAW_RC="$raw"
    _LAST_OBSERVATION="$(dispatch_rc_observation "$raw")"
    _LAST_RATE_LIMITED=0
    if _router_throttle_observed; then _LAST_RATE_LIMITED=1; fi
    # Mirror the runner's ACTUAL sequence, not a convenient approximation. The
    # readers below run inside `$()` exactly as cycle_dispatch_stage runs them,
    # because that is what makes the difference: a version smuggled out of a
    # reader on a global dies at the subshell boundary, and the gate then reads
    # its default forever. #1823 shipped precisely that for one commit — the
    # gate was inert and every test still passed, because this helper was
    # calling a reader directly instead of doing what the runner does.
    _LAST_CONTRACT="$(_verdict_probe_contract "$ZBUILD_STATE_DIR" "$dir/manifest.yaml")"
    _LAST_NARROW_RC="$raw"
    if [[ "$_LAST_CONTRACT" =~ ^[0-9]+$ ]] && [[ "$_LAST_CONTRACT" -ge 2 ]]; then
        _LAST_NARROW_RC="$(dispatch_rc_narrow "$raw")"
    fi
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
# This stub is v1 (it writes no result), so its rc is NOT narrowed — the runner
# still sees 143 and its existing abort handling is untouched. The narrowing is
# v2-only until #1850; section 7 pins both halves of that rule.
assert_eq "[SPEC-1] a v1 stage's rc is NOT narrowed (coexistence)" "143" "$_LAST_NARROW_RC"
# The classification is additive and applies either way — which is the whole
# point: an unmigrated stage gets an honest disposition today without any
# change to the rc it reports.
assert_eq "[SPEC-1] but the disposition is classified regardless of version" \
    "interrupted" "$_LAST_DISPOSITION"
assert_eq "[SPEC-1] a killed stage is interrupted, NOT broken" "interrupted" "$_LAST_DISPOSITION"
assert_eq "[SPEC-1] and therefore the engine retries rather than halting" \
    "retry" "$(disposition_response "$_LAST_DISPOSITION")"
assert_eq "[SPEC-1] interrupted does not halt the run" \
    "1" "$(_rc_of disposition_halts "$_LAST_DISPOSITION")"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "2. SIGINT — why it is NOT raised for real here"

# SIGINT deliberately gets no real-signal case. POSIX has a shell set SIGINT (and
# SIGQUIT) to SIG_IGN in a job it starts in the background, and children inherit
# that — so inside `scripts/run-tests.sh`, which backgrounds the parallel-safe
# tiers, `kill -INT $BASHPID` is a NO-OP: the stub survives and exits 0. Verified
# directly: the same stub yields rc=130 in the foreground and rc=0 backgrounded.
# SIGTERM and SIGKILL are unaffected, which is why sections 1 and 3 use them.
#
# Writing the case anyway would produce a test that passes standalone and fails
# under `npm test` — a harness artefact indistinguishable, at a glance, from the
# regression it was meant to catch.
#
# Nothing is lost. The classification keys on `rc > 128`, one branch for every
# signal, and sections 1 and 3 drive that branch with two real deaths. SIGINT's
# own rc is pinned at the unit level in tests/unit/dispatch-rc-test.sh
# ("[SPEC-2] rc 130 (SIGINT) observes a signal"), where no process is spawned
# and the harness cannot interfere.
assert_eq "[SPEC-2] rc 130 still classifies as a signal death" \
    "signal" "$(dispatch_rc_observation 130)"
assert_eq "[SPEC-2] and therefore as interrupted" \
    "interrupted" "$(dispatch_rc_failure_disposition "$(dispatch_rc_observation 130)")"

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

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "7. v1 keeps its rc; only v2 is narrowed"

# The coexistence rule. A v1 plugin's exit code is still its ONLY channel —
# `plan` reports scope_too_large as rc=10 and has no result field to say it in —
# so narrowing every plugin today would delete the meaning of all 25 at once.
# v2 stages declare a `disposition`, so they have somewhere else to say
# everything the rc was carrying, and only they are held to {0,1}.
#
# Without this gate the change is not additive: `plan`'s rc=10 would arrive at
# the runner as 1, the scope_too_large abort would never fire, and an oversized
# scope would run on instead of stopping. No existing test covers that path
# through the runner, so nothing would have caught it.

_d="$(_mkstage v1_scope_stage 'return 10;')"
_dispatch "$_d" v1_scope_stage
assert_eq "[SPEC-7] a v1 stage declares contract 1" "1" "$_LAST_CONTRACT"
assert_eq "[SPEC-7] and its rc=10 passes through UNCHANGED" "10" "$_LAST_NARROW_RC"
# The legacy meaning is still recoverable as a word, so a reader that wants the
# declared vocabulary can have it without the number.
assert_eq "[SPEC-7] while rc=10 still maps to the exhausted disposition" \
    "exhausted" "$(dispatch_rc_legacy_disposition "$_LAST_RAW_RC")"
assert_eq "[SPEC-7] and to its declared reason word" \
    "scope_too_large" "$(dispatch_rc_legacy_reason "$_LAST_RAW_RC")"

# A v2 stage returning the same rc IS narrowed — it declared a disposition, so
# nothing is lost by dropping the number.
_d="$(_mkstage v2_scope_stage '
    printf %s "{\"result_contract\":2,\"verdict\":\"fail\",\"disposition\":\"exhausted\",\"reason\":\"scope too large\"}" \
        > "$ZBUILD_STATE_DIR/artifacts/v2_scope_stage-result.json"
    return 10;')"
_dispatch "$_d" v2_scope_stage
assert_eq "[SPEC-7] a v2 stage declares contract 2" "2" "$_LAST_CONTRACT"
assert_eq "[SPEC-7] its raw rc really was 10" "10" "$_LAST_RAW_RC"
assert_eq "[SPEC-7] and it IS narrowed to 1" "1" "$_LAST_NARROW_RC"
assert_eq "[SPEC-7] with the meaning carried by its declared word" \
    "exhausted" "$_LAST_DISPOSITION"

# And the dictionary is enforced for v2 only. An off-set word is a structural
# failure (#1822); the engine never substitutes a plausible member.
_d="$(_mkstage v2_bogus_stage '
    printf %s "{\"result_contract\":2,\"verdict\":\"fail\",\"disposition\":\"wedged\",\"reason\":\"x\"}" \
        > "$ZBUILD_STATE_DIR/artifacts/v2_bogus_stage-result.json"
    return 1;')"
_dispatch "$_d" v2_bogus_stage
assert_eq "[SPEC-7] a v2 word outside the dictionary resolves to broken" \
    "broken" "$_LAST_DISPOSITION"
assert_contains "[SPEC-7] and is reported as a contract violation naming the word" \
    "$(runner_read_stage_reason "$ZBUILD_STATE_DIR" "$_d/manifest.yaml" v2_bogus_stage 1)" \
    "unknown_disposition:wedged"

# A v1 stage is NOT held to the dictionary — it declares no disposition at all,
# and absence is not an off-set word. This is what lets 25 unmigrated plugins
# keep running while the F-wave converts them one PR at a time.
_d="$(_mkstage v1_plain_stage '
    printf %s "{\"verdict\":\"fail\"}" \
        > "$ZBUILD_STATE_DIR/artifacts/v1_plain_stage-result.json"
    return 1;')"
_dispatch "$_d" v1_plain_stage
assert_eq "[SPEC-7] a v1 result is not judged against the dictionary" "1" "$_LAST_CONTRACT"
assert_eq "[SPEC-7] and yields no disposition rather than a violation" "" "$_LAST_DISPOSITION"
assert_eq "[SPEC-7] its reason channel carries no contract violation" \
    "" "$(runner_read_stage_reason "$ZBUILD_STATE_DIR" "$_d/manifest.yaml" v1_plain_stage 1)"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "8. The version cannot travel on a global (inert-gate guard)"

# THE regression this section exists for. For one commit the gate read
# `_ZBUILD_LAST_RESULT_CONTRACT`, set inside _verdict_read_result — which every
# public reader invokes from inside `$(...)`. A `$()` is a subshell, so the
# assignment never reached the caller, the gate always saw the default, and v2
# narrowing NEVER FIRED. Every test still passed: the unit tests called the
# readers directly, and the guard test asserted the gate LINES existed, which a
# line that does nothing satisfies perfectly.
#
# So this asserts the mechanism, not the text: the version must survive being
# fetched the way the runner fetches it.

_d="$(_mkstage inert_probe_stage '
    printf %s "{\"result_contract\":2,\"verdict\":\"fail\",\"disposition\":\"broken\",\"reason\":\"x\"}" \
        > "$ZBUILD_STATE_DIR/artifacts/inert_probe_stage-result.json"
    return 1;')"

# Demonstrate the trap directly: a global set inside a command substitution is
# invisible to the caller. If this ever starts passing, bash changed and the
# whole concern is moot — but it will not.
_ZBUILD_PROBE_CANARY=""
_canary_setter() { _ZBUILD_PROBE_CANARY="set-inside"; printf 'output'; }
_ignored="$(_canary_setter)"
assert_eq "[SPEC-8] a global assigned inside \$() does NOT reach the caller" \
    "" "$_ZBUILD_PROBE_CANARY"

# End to end through the dispatch helper, which now mirrors the runner. The
# dispatch has to happen FIRST — the stage writes its result when the hook runs,
# so probing before it would read an absent file and correctly answer 1.
_dispatch "$_d" inert_probe_stage

# The real thing: the probe returns the version through stdout, so it survives
# the same boundary that swallowed the global.
assert_eq "[SPEC-8] the contract probe returns 2 through stdout" \
    "2" "$(_verdict_probe_contract "$ZBUILD_STATE_DIR" "$_d/manifest.yaml")"
assert_eq "[SPEC-8] the boundary sees contract 2" "2" "$_LAST_CONTRACT"
assert_eq "[SPEC-8] so a v2 stage's rc IS narrowed — the gate actually fires" \
    "1" "$_LAST_NARROW_RC"

# The negative half: a v1 stage in the same helper must NOT be narrowed. Without
# this, an implementation that narrowed everything would satisfy the above.
_d="$(_mkstage inert_probe_v1_stage 'return 10;')"
_dispatch "$_d" inert_probe_v1_stage
assert_eq "[SPEC-8] a v1 stage still reports contract 1" "1" "$_LAST_CONTRACT"
assert_eq "[SPEC-8] and its rc survives un-narrowed" "10" "$_LAST_NARROW_RC"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
