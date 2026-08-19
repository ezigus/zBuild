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
# Scope note: the legacy rcs are MAPPED here, not removed. #1850 deletes the
# mapping together with the v1 result reader — its acceptance says so in as many
# words. What changes now is that they are interpreted in ONE place.
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
assert_eq "[SPEC-3] rate limit → throttled" \
    "throttled" "$(dispatch_rc_failure_disposition "" 1)"
assert_eq "[SPEC-3] no observation → broken" \
    "broken" "$(dispatch_rc_failure_disposition "")"

# Rate limit beats signal when both are present. The two responses are NOT
# equally safe under ambiguity: `interrupted` retries immediately, which for a
# throttled stage is simply throttled again — the zero-output loop of #1723.
# `throttled` waits first, costing a genuine interruption one bounded wait.
# Where it must guess, the engine guesses toward the response that cannot spin.
assert_eq "[SPEC-3] rate limit wins over a signal (cannot spin)" \
    "throttled" "$(dispatch_rc_failure_disposition signal 1)"

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
assert_eq "[SPEC-4] throttled → retry_after_wait" \
    "retry_after_wait" "$(disposition_response "$(dispatch_rc_failure_disposition "" 1)")"
assert_eq "[SPEC-4] broken → halt_broken" \
    "halt_broken" "$(disposition_response "$(dispatch_rc_failure_disposition "")")"

# The regression this file exists to catch: before #1823 a killed stage halted.
assert_eq "[SPEC-4] a killed stage does NOT halt" \
    "1" "$(_rc_of disposition_halts "$(dispatch_rc_failure_disposition signal)")"
assert_eq "[SPEC-4] a rate-limited stage does NOT halt" \
    "1" "$(_rc_of disposition_halts "$(dispatch_rc_failure_disposition "" 1)")"
assert_eq "[SPEC-4] an unexplained stage DOES halt" \
    "0" "$(_rc_of disposition_halts "$(dispatch_rc_failure_disposition "")")"

# And throttled waits where interrupted does not — the number is what separates
# them, not the word.
assert_eq "[SPEC-4] interrupted waits 0s" \
    "0" "$(disposition_wait_s "$(dispatch_rc_failure_disposition signal)")"
assert_gt "[SPEC-4] throttled waits > 0s before retrying" \
    "$(disposition_wait_s "$(dispatch_rc_failure_disposition "" 1)")" "0"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "5. Legacy rc mapping (the v1 boundary — #1850 deletes it)"

assert_eq "[SPEC-5] rc 5 → blocked"                  "blocked" "$(dispatch_rc_legacy_reason 5)"
assert_eq "[SPEC-5] rc 6 → cycle_abort"              "cycle_abort" "$(dispatch_rc_legacy_reason 6)"
assert_eq "[SPEC-5] rc 8 → blocking_member_failure"  "blocking_member_failure" "$(dispatch_rc_legacy_reason 8)"
assert_eq "[SPEC-5] rc 9 → llm_unavailable"          "llm_unavailable" "$(dispatch_rc_legacy_reason 9)"
assert_eq "[SPEC-5] rc 10 → scope_too_large"         "scope_too_large" "$(dispatch_rc_legacy_reason 10)"
# [SPEC-13] (#1832, ADR-054 §6): scope_too_large remains as the rc=10 dispatch signal label.
# The design decision keeps it as log/event vocabulary for the abort reason — it is a
# dispatch-rc signal, NOT a verdict string. Guard: must not be removed from legacy mapping.
assert_eq "[SPEC-13] rc 10 → scope_too_large (dispatch signal, not verdict; unchanged by #1832)" \
    "scope_too_large" "$(dispatch_rc_legacy_reason 10)"
assert_eq "[SPEC-5] rc 11 → route_back"              "route_back" "$(dispatch_rc_legacy_reason 11)"
assert_eq "[SPEC-5] rc 4 → config_invalid"           "config_invalid" "$(dispatch_rc_legacy_reason 4)"

# 130 and 143 must AGREE. _cycle_handle_terminal_rc has a `130)` arm and no
# `143)` arm, so a SIGTERM falls through to `*) reason="error"` and is reported
# to an operator as an ordinary error rather than an abort. Naming both here is
# what makes the two signals agree.
assert_eq "[SPEC-5] rc 130 (SIGINT) → aborted"  "aborted" "$(dispatch_rc_legacy_reason 130)"
assert_eq "[SPEC-5] rc 143 (SIGTERM) → aborted, the same word as SIGINT" \
    "aborted" "$(dispatch_rc_legacy_reason 143)"

# Refusing to answer is the point: a caller wanting a word for 42 has already
# lost, and a plausible-looking default would bury that.
assert_eq "[SPEC-5] an unmapped rc returns 1 and prints nothing" \
    "1" "$(_rc_of dispatch_rc_legacy_reason 42)"
assert_eq "[SPEC-5] an unmapped rc prints nothing" "" "$(dispatch_rc_legacy_reason 42 || true)"
assert_eq "[SPEC-5] rc 0 has no legacy reason" "1" "$(_rc_of dispatch_rc_legacy_reason 0)"

# Only the three legacy codes ADR-054 §6 has an exact word for map to a
# disposition. Each is a wording match against the §6 table, not a judgement
# call: 9 is "halt; operator action required", 10 is "more budget, or the work
# must shrink", a signal is "retry as-is".
assert_eq "[SPEC-5] rc 9 → unavailable"        "unavailable" "$(dispatch_rc_legacy_disposition 9)"
assert_eq "[SPEC-5] rc 10 → exhausted"         "exhausted" "$(dispatch_rc_legacy_disposition 10)"
assert_eq "[SPEC-5] rc 130 → interrupted"      "interrupted" "$(dispatch_rc_legacy_disposition 130)"
assert_eq "[SPEC-5] rc 143 → interrupted"      "interrupted" "$(dispatch_rc_legacy_disposition 143)"

# The control-flow codes map to NOTHING, deliberately. They are decisions the
# cycle made, not statements about whether a stage got far enough to produce a
# verdict worth reading. ADR-054 §4 re-homes them onto routing state (ADR-045)
# and the blocking-member halt (ADR-013). Forcing them into the disposition set
# would be the invented default the contract exists to forbid.
for _cf in 4 5 6 8 11; do
    assert_eq "[SPEC-5] rc $_cf has NO disposition (it is control flow)" \
        "1" "$(_rc_of dispatch_rc_legacy_disposition "$_cf")"
done

# Whatever the mapping does produce must be in the closed set.
for _rc in 9 10 130 143; do
    assert_eq "[SPEC-5] rc $_rc maps into the closed disposition set" \
        "0" "$(_rc_of disposition_is_valid "$(dispatch_rc_legacy_disposition "$_rc")")"
done

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
assert_eq "[SPEC-6] no result + rate limit → throttled" "throttled" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 "" 1)"
assert_eq "[SPEC-6] no result + nothing observed → broken" "broken" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 "" 0)"

# Back-compat: the two trailing args are optional, and omitting them keeps
# #1822's behaviour exactly. Three existing readers call the 4-arg form.
assert_eq "[SPEC-6] omitting the observation still yields broken (#1822 shape)" \
    "broken" "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1)"

# rc=0 never classifies — there is no failure to explain, and an observation on
# a successful dispatch must not invent one.
assert_eq "[SPEC-6] rc=0 yields no disposition even with an observation" \
    "" "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 0 signal 0)"

# A DECLARED disposition always wins over the engine's inference. rc fills the
# silence; it never overwrites a stage that spoke for itself. Without this, a
# stage that wrote `exhausted` and was then killed would be retried as
# `interrupted` forever.
printf '{"result_contract":2,"verdict":"fail","disposition":"exhausted","reason":"budget"}' \
    > "$_sd/artifacts/fx-result.json"
assert_eq "[SPEC-6] a DECLARED disposition beats a signal observation" "exhausted" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 1 signal 0)"
assert_eq "[SPEC-6] a DECLARED disposition beats a rate-limit observation" "exhausted" \
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
print_test_section "8. A legacy rc outranks the observation-based fallback"

# Review finding: a v1 stage exiting 9 or 10 with no result resolved to `broken`
# because the legacy mapping was computed and never consulted. Both still halt,
# so no control flow changed — but `broken` tells an operator "this is our own
# defect" for what is actually a service outage or an oversized scope, and that
# distinction is the entire reason `unavailable` and `broken` are separate words
# (#1822: they differ in what is reported, not in the stopping).
rm -f "$_sd/artifacts/fx-result.json"

assert_eq "[SPEC-8] rc=9 with no result → unavailable, not broken" "unavailable" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 9 "" 0)"
assert_eq "[SPEC-8] rc=10 with no result → exhausted, not broken" "exhausted" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 10 "" 0)"
assert_eq "[SPEC-8] rc=143 with no result → interrupted" "interrupted" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 143 "" 0)"

# Each drives a genuinely different operator-facing response.
assert_eq "[SPEC-8] unavailable halts for an OPERATOR, not as a defect" \
    "halt_unavailable" "$(disposition_response unavailable)"
assert_eq "[SPEC-8] exhausted escalates rather than halting" \
    "escalate" "$(disposition_response exhausted)"

# A legacy code with no §6 word still falls through to the observation table.
assert_eq "[SPEC-8] rc=5 (blocked) has no word, so it stays broken" "broken" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 5 "" 0)"
assert_eq "[SPEC-8] rc=8 likewise stays broken" "broken" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 8 "" 0)"

# A rate limit still wins: it is evidence about THIS dispatch, where a legacy rc
# is a coexistence-era translation.
assert_eq "[SPEC-8] an observed rate limit outranks a legacy rc" "throttled" \
    "$(runner_read_stage_disposition "$_sd" "$_pd/manifest.yaml" fx 9 "" 1)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
