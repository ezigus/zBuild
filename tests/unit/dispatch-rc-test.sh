#!/usr/bin/env bash
# Tests: core/pipeline/dispatch-rc.sh — rc ∈ {0,1} and the classification of an
# rc=1 that left no result (#1823, absorbs #1723; ADR-054 §4).
#
# rc carries exactly two facts: "my result is on disk" (0) and "I failed" (1).
# Everything the engine's old private vocabulary (5 blocked, 6 cycle_abort,
# 8 blocking_member_failure, 9 llm_unavailable, 10 scope_too_large, 11 route_back,
# 130/143 signal) was carrying moves onto declared channels.
#
# The one inference the engine is permitted, and what this file mostly pins:
#
#   rate-limit envelope seen  → throttled     (wait, then retry)
#   killed by signal, or 124  → interrupted   (retry as-is)
#   anything else             → broken        (halt; it is a defect)
#
# Why this matters more than a table: before #1823 all three were flatly
# `broken`, and `broken` halts. A run whose `intake` was killed by a passing
# SIGTERM, or whose `build` hit a 429, was reported as a defect and stopped —
# which is precisely the failure ADR-054 §6 says `interrupted` and `throttled`
# exist to prevent, and the reason #1798 is gated on this issue.
#
# #1850 deleted the legacy rc mapping together with the v1 result reader; this
# file pins that it is gone (section 5).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "dispatch-rc — rc ∈ {0,1} + rc=1 fallback classification (#1823)"
setup_test_env "dispatch-rc"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/dispatch-rc.sh
source "$REPO_ROOT/core/pipeline/dispatch-rc.sh"
# shellcheck source=../../core/pipeline/disposition.sh
source "$REPO_ROOT/core/pipeline/disposition.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../scripts/lib/router-rc-classify.sh
source "$REPO_ROOT/scripts/lib/router-rc-classify.sh"

# assert_exit_code takes a VALUE, not a command (test-helpers.sh:258).
_rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "1. dispatch_rc_narrow — the whole vocabulary is {0,1}"

assert_eq "[SPEC-1] rc 0 narrows to 0" "0" "$(dispatch_rc_narrow 0)"
assert_eq "[SPEC-1] rc 1 narrows to 1" "1" "$(dispatch_rc_narrow 1)"

# Every legacy engine code narrows to 1. Enumerated rather than sampled: the
# defect being fixed is that each of these meant something different to each
# reader, so "they are all just failure now" has to hold for all of them.
for _legacy in 2 3 4 5 6 7 8 9 10 11 124 130 137 143; do
    assert_eq "[SPEC-1] legacy rc $_legacy narrows to 1" "1" "$(dispatch_rc_narrow "$_legacy")"
done

# A non-numeric status is a FAILURE, not a success. A caller holding a
# non-number has already lost the status, and reading that as 0 would report a
# dispatch nobody can account for as a clean success.
assert_eq "[SPEC-1] a non-numeric status narrows to 1, not 0" "1" "$(dispatch_rc_narrow "")"
assert_eq "[SPEC-1] garbage narrows to 1, not 0" "1" "$(dispatch_rc_narrow "boom")"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "2. dispatch_rc_observation — captured BEFORE narrowing"

assert_eq "[SPEC-2] rc 124 observes a timeout" "timeout" "$(dispatch_rc_observation 124)"
assert_eq "[SPEC-2] rc 130 (SIGINT) observes a signal"  "signal" "$(dispatch_rc_observation 130)"
assert_eq "[SPEC-2] rc 143 (SIGTERM) observes a signal" "signal" "$(dispatch_rc_observation 143)"
assert_eq "[SPEC-2] rc 137 (SIGKILL) observes a signal" "signal" "$(dispatch_rc_observation 137)"

# The signal test is `> 128`, not a list of the three named codes. A stage killed
# by SIGHUP (129) or SIGQUIT (131) was still killed; enumerating three would
# report the rest as `broken` — a defect report for a stage that was killed.
assert_eq "[SPEC-2] rc 129 (SIGHUP) observes a signal"  "signal" "$(dispatch_rc_observation 129)"
assert_eq "[SPEC-2] rc 131 (SIGQUIT) observes a signal" "signal" "$(dispatch_rc_observation 131)"

# An ordinary failure observes NOTHING. Empty is the honest answer and is what
# separates `broken` from the two recoverable words.
assert_eq "[SPEC-2] rc 1 observes nothing"  "" "$(dispatch_rc_observation 1)"
assert_eq "[SPEC-2] rc 0 observes nothing"  "" "$(dispatch_rc_observation 0)"
assert_eq "[SPEC-2] rc 9 observes nothing (a legacy code is not a signal)" \
    "" "$(dispatch_rc_observation 9)"
assert_eq "[SPEC-2] rc 200 observes nothing (above the signal ceiling)" \
    "" "$(dispatch_rc_observation 200)"
assert_eq "[SPEC-2] a non-numeric status observes nothing" "" "$(dispatch_rc_observation "boom")"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "3. dispatch_rc_failure_disposition — the ADR-054 §4 table"

assert_eq "[SPEC-3] signal death → interrupted" \
    "interrupted" "$(dispatch_rc_failure_disposition signal)"
assert_eq "[SPEC-3] timeout → interrupted" \
    "interrupted" "$(dispatch_rc_failure_disposition timeout)"
# #2111 (Eric's call): a rate limit ENDS the run. `throttled` waited 30s and
# retried into the same limit, then the cycle re-verified an unchanged tree
# five times (#1840/#1841). `unavailable` halts; ADR-050 resume is the retry.
assert_eq "[SPEC-3] rate limit → unavailable (#2111)" \
    "unavailable" "$(dispatch_rc_failure_disposition "" 1)"
assert_eq "[SPEC-3] no observation → broken" \
    "broken" "$(dispatch_rc_failure_disposition "")"

# Rate limit beats signal when both are present: a 429 on the wire is direct
# evidence about this dispatch, and (#2111) the response to it is to END the
# run — retrying (immediately or after a wait) re-enters the same limit and
# re-verifies an unchanged tree until max_iterations (#1840/#1841).
assert_eq "[SPEC-3] rate limit wins over a signal (ends the run)" \
    "unavailable" "$(dispatch_rc_failure_disposition signal 1)"

# Every word this table can produce must be a member of the closed set, or the
# reader would hand a caller a word disposition_response refuses to answer for.
for _w in "$(dispatch_rc_failure_disposition signal)" \
          "$(dispatch_rc_failure_disposition timeout)" \
          "$(dispatch_rc_failure_disposition "" 1)" \
          "$(dispatch_rc_failure_disposition "")"; do
    assert_eq "[SPEC-3] '$_w' is a member of the closed disposition set" \
        "0" "$(_rc_of disposition_is_valid "$_w")"
done

# An unrecognized observation is `broken`, NOT a softer word. This is the
# invented-default guard one layer down: a future caller passing an observation
# this table has never heard of must not be told the stage is retryable.
assert_eq "[SPEC-3] an unknown observation → broken, never a retryable word" \
    "broken" "$(dispatch_rc_failure_disposition "wedged")"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "4. The classification drives a DIFFERENT engine response"

# The point of the table is not the words — it is that the engine acts
# differently. A test that only compared strings would pass for three words
# that all halted, which is exactly the pre-#1823 behaviour.
assert_eq "[SPEC-4] interrupted → retry" \
    "retry" "$(disposition_response "$(dispatch_rc_failure_disposition signal)")"
assert_eq "[SPEC-4] throttled → retry_after_wait (the word keeps its response)" \
    "retry_after_wait" "$(disposition_response throttled)"
assert_eq "[SPEC-4] a rate limit → halt_unavailable (#2111)" \
    "halt_unavailable" "$(disposition_response "$(dispatch_rc_failure_disposition "" 1)")"
assert_eq "[SPEC-4] broken → halt_broken" \
    "halt_broken" "$(disposition_response "$(dispatch_rc_failure_disposition "")")"

# The regression this file exists to catch: before #1823 a killed stage halted.
assert_eq "[SPEC-4] a killed stage does NOT halt" \
    "1" "$(_rc_of disposition_halts "$(dispatch_rc_failure_disposition signal)")"
assert_eq "[SPEC-4] a rate-limited stage DOES halt (#2111 — the run ends, resumable)" \
    "0" "$(_rc_of disposition_halts "$(dispatch_rc_failure_disposition "" 1)")"
assert_eq "[SPEC-4] an unexplained stage DOES halt" \
    "0" "$(_rc_of disposition_halts "$(dispatch_rc_failure_disposition "")")"

# And throttled waits where interrupted does not — the number is what separates
# them, not the word.
assert_eq "[SPEC-4] interrupted waits 0s" \
    "0" "$(disposition_wait_s "$(dispatch_rc_failure_disposition signal)")"
assert_gt "[SPEC-4] throttled waits > 0s before retrying" \
    "$(disposition_wait_s throttled)" "0"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "5. The legacy rc mapping is gone (#1850)"

# #1850 deleted it with the v1 result reader. A stage that died leaving no
# result is classified from what the boundary OBSERVED (section 3), never from
# the number it chose — so there is no table to keep in step any more.
for _fn in dispatch_rc_legacy_reason dispatch_rc_legacy_disposition; do
    if declare -F "$_fn" >/dev/null 2>&1; then
        assert_fail "[SPEC-5] $_fn is deleted" "still defined"
    else
        assert_pass "[SPEC-5] $_fn is deleted"
    fi
done
# What the mapping's signal rows said is still true, from the observation alone.
assert_eq "[SPEC-5] SIGINT and SIGTERM both read as interrupted, by observation" \
    "interrupted interrupted" \
    "$(dispatch_rc_failure_disposition "$(dispatch_rc_observation 130)" 0) $(dispatch_rc_failure_disposition "$(dispatch_rc_observation 143)" 0)"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "6. runner_read_stage_disposition honours the observation"

_mkplugin() {
    local dir="$1" prim="$2"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $(basename "$dir")
name: Fixture
kind: tool
version: 0.0.1
hooks:
  run: fx_run
outputs:
  - id: result
    path: \${artifact_dir}/${prim}
    primary: true
EOF
    printf '%s' "$dir"
}

_sd="$TEST_TEMP_DIR/sd"; mkdir -p "$_sd/artifacts"
_pd="$(_mkplugin "$TEST_TEMP_DIR/fx" "fx-result.json")"

# No result on disk + rc=1. This is the case the whole issue is about.
rm -f "$_sd/artifacts/fx-result.json"

assert_eq "[SPEC-6] no result + killed by signal → interrupted" "interrupted" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 signal 0)"
assert_eq "[SPEC-6] no result + timeout → interrupted" "interrupted" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 timeout 0)"
assert_eq "[SPEC-6] no result + rate limit → unavailable (#2111)" "unavailable" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 "" 1)"
assert_eq "[SPEC-6] no result + nothing observed → broken" "broken" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 "" 0)"

# Back-compat: the two trailing args are optional, and omitting them keeps
# #1822's behaviour exactly. Three existing readers call the 4-arg form.
assert_eq "[SPEC-6] omitting the observation still yields broken (#1822 shape)" \
    "broken" "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1)"

# rc=0 is not classified by observation — but since #1850 a clean exit that
# left no result is broken: the stage said it finished and the engine holds
# nothing. The observation does not soften that into `interrupted`.
assert_eq "[SPEC-6] rc=0 with no result is broken, observation or not (#1850)" \
    "broken" "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 0 signal 0)"

# A DECLARED disposition always wins over the engine's inference. rc fills the
# silence; it never overwrites a stage that spoke for itself. Without this, a
# stage that wrote `exhausted` and was then killed would be retried as
# `interrupted` forever.
# #2187: a non-retryable word, because a RETRYABLE one seen alongside a rate
# limit is read as the rate limit it was (#2111) — see SPEC-6b.
printf '{"result_contract":2,"verdict":"fail","disposition":"misconfigured","reason":"no tier"}' \
    > "$_sd/artifacts/fx-result.json"
assert_eq "[SPEC-6] a DECLARED disposition beats a signal observation" "misconfigured" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 signal 0)"
assert_eq "[SPEC-6] a DECLARED disposition beats a rate-limit observation" "misconfigured" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 "" 1)"
# SPEC-6b (#2111, #2187): a RETRYABLE declared word seen alongside a rate limit
# was the rate limit — retrying would just be throttled again.
printf '{"result_contract":2,"verdict":"fail","disposition":"timed_out","reason":"router_timeout"}' \
    > "$_sd/artifacts/fx-result.json"
assert_eq "[SPEC-6b] a retryable word with a rate limit observed reads as rate_limited" "rate_limited" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 "" 1)"

# A contract violation stays `broken` regardless of what was observed. The
# engine has already rejected this result as structurally invalid; reporting it
# as retryable would retry an invalid result forever (#1822's named regression).
printf '{"result_contract":2,"verdict":"fail","disposition":"wedged","reason":"x"}' \
    > "$_sd/artifacts/fx-result.json"
assert_eq "[SPEC-6] an invalid declared disposition stays broken despite a signal" \
    "broken" "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 signal 0)"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "7. The throttle marker is per-dispatch, not per-run"

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

_router_clear_throttle_marker
assert_eq "[SPEC-7] no marker before anything is armed" \
    "1" "$(_rc_of _router_throttle_observed)"

_router_arm_throttle_marker "LLM rate-limited — resets 5pm"
assert_eq "[SPEC-7] the marker is observable after arming" \
    "0" "$(_rc_of _router_throttle_observed)"

# The clear is what stops one rate limit becoming a retry loop on an unrelated
# defect: a marker left by an earlier stage would classify the NEXT stage's
# unexplained failure as `throttled`, and `throttled` retries.
_router_clear_throttle_marker
assert_eq "[SPEC-7] clearing removes it, so the next dispatch starts clean" \
    "1" "$(_rc_of _router_throttle_observed)"

# With no state dir the helpers must degrade to no-ops rather than fabricate a
# path under cwd (the _zbuild_abort_sentinel_path discipline, ADR-025).
_saved_state_dir="$ZBUILD_STATE_DIR"
unset ZBUILD_STATE_DIR
assert_eq "[SPEC-7] no ZBUILD_STATE_DIR → the marker path is empty" \
    "" "$(_router_throttle_marker_path)"
assert_eq "[SPEC-7] arming without a state dir is a silent no-op, not an error" \
    "0" "$(_rc_of _router_arm_throttle_marker "x")"
assert_eq "[SPEC-7] observing without a state dir reports nothing" \
    "1" "$(_rc_of _router_throttle_observed)"
export ZBUILD_STATE_DIR="$_saved_state_dir"
[[ -e "$PWD/.throttled.signal" ]] && assert_fail "[SPEC-7] no marker fabricated under cwd" "found $PWD/.throttled.signal"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "8. With no result, only the observation classifies — never the number (#1850)"

# The legacy mapping once turned rc 9 into `unavailable` and rc 10 into
# `out_of_turns` for a v1 stage that could say nothing else. Every stage is v2
# now and records those causes itself (router_reason_disposition), so a stage
# that exits with NO result has crashed whatever number it chose: broken. Only
# what the boundary observed about its death changes that.
rm -f "$_sd/artifacts/fx-result.json"

assert_eq "[SPEC-8] rc=9 with no result and nothing observed → broken" "broken" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 9 "" 0)"
assert_eq "[SPEC-8] rc=10 with no result and nothing observed → broken" "broken" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 10 "" 0)"
assert_eq "[SPEC-8] rc=143 observed as a signal → interrupted" "interrupted" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 143 "$(dispatch_rc_observation 143)" 0)"
assert_eq "[SPEC-8] an observed rate limit → unavailable (#2111)" "unavailable" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 9 "" 1)"

print_test_section "SPEC-9 (#1850): a stage killed by Ctrl-C or kill names the abort word"
# The raw status is read here, at the boundary, and nowhere else: a child that
# died of SIGINT/SIGTERM records the ADR-025 abort word before the rc narrows.
assert_eq "[SPEC-9] 130 (SIGINT) names sigint" "sigint" "$(dispatch_rc_signal_word 130)"
assert_eq "[SPEC-9] 143 (SIGTERM) names sigterm" "sigterm" "$(dispatch_rc_signal_word 143)"
assert_eq "[SPEC-9] 137 (SIGKILL) names no abort word" "" "$(dispatch_rc_signal_word 137)"
assert_eq "[SPEC-9] 1 names no abort word" "" "$(dispatch_rc_signal_word 1)"
assert_eq "[SPEC-9] 124 (timeout) names no abort word" "" "$(dispatch_rc_signal_word 124)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
