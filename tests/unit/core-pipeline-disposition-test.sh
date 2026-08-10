#!/usr/bin/env bash
# Tests: core/pipeline/disposition.sh — the disposition vocabulary and the
# engine's response table (#1822, ADR-054 §6).
#
# The question "is this failure recoverable?" is answered ONCE, at the dispatch
# boundary, from a field the stage declared — not re-derived per plugin from an
# exit code. `disposition` is a CLOSED set owned by the engine; each word exists
# only because the engine acts differently on it:
#
#   complete     nothing went wrong
#   interrupted  retry as-is
#   throttled    wait, then retry
#   exhausted    more budget, or the work must shrink
#   unavailable  halt; operator action required
#   broken       halt; it is a defect
#
# Two invariants this file exists to pin:
#   1. A disposition outside the set is a STRUCTURAL FAILURE. The engine never
#      invents a default — that is how "unrecognized is never a failure" (the
#      #1819 generator defect) gets reintroduced.
#   2. `broken` is the engine's own conclusion about a dispatch that left no
#      result. The engine NEVER writes it into the stage's artifact; it holds it
#      on its own channels (the reader's return, the dispatch event).
#
# Scope note: ADR-054's delivery map (§Implementation Notes) gives #1822 the
# vocabulary and the response table. Moving did_not_finish / empty_diff /
# scope_too_large / inert_build OUT of `verdict` is #1832; the re-dispatch
# mechanism keyed on a retryable response has no owner yet. So the retry-family
# responses are asserted here as policy, not as a loop — and the infinite-retry
# guard is asserted as "broken never resolves to a retryable response".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/disposition — vocabulary + engine response table (#1822)"
setup_test_env "pipeline-disposition"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/disposition.sh
source "$REPO_ROOT/core/pipeline/disposition.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
ART_DIR="$STATE_DIR/artifacts"
mkdir -p "$ART_DIR"

# assert_exit_code takes a VALUE, not a command — run it and hand over the rc.
_rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

_make_manifest() {
    # _make_manifest <dir> <id> <output_path>
    local dir="$1" id="$2" path="$3"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: $id
kind: tool
version: 0.0.1
hooks:
  run: plugin.sh
outputs:
  - id: result
    path: "$path"
    type: json
    required: true
    primary: true
EOF
}

# ═══ 1. The vocabulary is a closed set ═══════════════════════════════════════
print_test_section "the vocabulary is a closed set of exactly six words"

assert_eq "the closed set is exactly the ADR-054 §6 vocabulary" \
    "complete interrupted throttled exhausted unavailable broken" \
    "$(disposition_vocabulary)"

for _d in complete interrupted throttled exhausted unavailable broken; do
    assert_exit_code "\`$_d\` is a member of the closed set" 0 \
        "$(_rc_of disposition_is_valid "$_d")"
done

# Anything else is not a member — including the ADR-021 member-disposition
# vocabulary, which claims the same field name on a v1 artifact (see the
# result-reader section below for why that collision stays inert).
for _d in terminal recoverable advisory none pass fail error "" "COMPLETE" "complete "; do
    assert_exit_code "\`$_d\` is NOT a member of the closed set" 1 \
        "$(_rc_of disposition_is_valid "$_d")"
done

# ═══ 2. One DISTINCT engine response per disposition ═════════════════════════
# The acceptance bar is "distinct engine response", not "the value parses".
print_test_section "each disposition maps to its own engine response"

assert_eq "complete    -> proceed"          "proceed"          "$(disposition_response complete)"
assert_eq "interrupted -> retry"            "retry"            "$(disposition_response interrupted)"
assert_eq "throttled   -> retry_after_wait" "retry_after_wait" "$(disposition_response throttled)"
assert_eq "exhausted   -> escalate"         "escalate"         "$(disposition_response exhausted)"
assert_eq "unavailable -> halt_unavailable" "halt_unavailable" "$(disposition_response unavailable)"
assert_eq "broken      -> halt_broken"      "halt_broken"      "$(disposition_response broken)"

# Mechanically enforce distinctness so a future edit cannot collapse two words
# onto one response without this failing. `unavailable` and `broken` both stop
# the run, but an operator reading the log has to be able to tell "something
# outside us is down" from "this is our bug" — they are not interchangeable.
_resp_count="$(for _d in $(disposition_vocabulary); do disposition_response "$_d"; printf '\n'; done | sort -u | wc -l | tr -d ' ')"
assert_eq "all six responses are distinct from one another" "6" "$_resp_count"

# ═══ 3. The response table is the engine's, and it halts where it says ══════
print_test_section "halt / retry predicates follow the table, not the stage"

for _d in unavailable broken; do
    assert_exit_code "\`$_d\` halts the run" 0 "$(_rc_of disposition_halts "$_d")"
done
for _d in complete interrupted throttled exhausted; do
    assert_exit_code "\`$_d\` does not halt the run" 1 "$(_rc_of disposition_halts "$_d")"
done

# Retry is a property of the DISPOSITION, not of the stage — no plugin decides
# its own retry policy.
for _d in interrupted throttled; do
    assert_exit_code "\`$_d\` is retryable" 0 "$(_rc_of disposition_retryable "$_d")"
done
for _d in complete exhausted unavailable broken; do
    assert_exit_code "\`$_d\` is NOT retryable" 1 "$(_rc_of disposition_retryable "$_d")"
done

# What separates `interrupted` from `throttled` is not the word — it is the
# wait. A throttled stage re-dispatched immediately just gets throttled again.
assert_eq "interrupted retries immediately (no wait)" "0" "$(disposition_wait_s interrupted)"
assert_gt "throttled waits before retrying" "$(disposition_wait_s throttled)" "0"

# A wait is meaningless for a disposition that will not be retried, and
# answering "0" for one is a footgun: a caller that skipped the retryable check
# would read "0 seconds until retry" for `broken` and immediately re-dispatch a
# halted stage. Refusing is the only safe answer.
for _d in complete exhausted unavailable broken; do
    assert_exit_code "\`$_d\` has no wait — the call is refused" 1 \
        "$(_rc_of disposition_wait_s "$_d")"
    assert_eq "\`$_d\` prints no wait value" "" "$(disposition_wait_s "$_d" 2>/dev/null || true)"
done

# ═══ 4. Guard: `broken` still halts — no infinite-retry regression ══════════
print_test_section "guard: broken halts and can never be retried"

assert_exit_code "broken halts" 0 "$(_rc_of disposition_halts broken)"
assert_exit_code "broken is not retryable" 1 "$(_rc_of disposition_retryable broken)"
assert_eq "broken's response is not in the retry family" "halt_broken" "$(disposition_response broken)"
# The pairing is the actual guard: nothing may both halt and retry.
for _d in $(disposition_vocabulary); do
    if disposition_halts "$_d" 2>/dev/null; then
        assert_exit_code "\`$_d\` halts, therefore is not retryable" 1 "$(_rc_of disposition_retryable "$_d")"
    fi
done

# ═══ 5. An unknown disposition is a structural failure ══════════════════════
# No default is invented. An unrecognized word must cost something — that is
# the whole #1819 thesis.
print_test_section "an unknown disposition is a structural failure"

assert_exit_code "disposition_response refuses an unknown word" 1 \
    "$(_rc_of disposition_response "wedged")"
assert_eq "disposition_response prints nothing for an unknown word" "" \
    "$(disposition_response wedged 2>/dev/null || true)"
# rc 2, not 1: "I cannot answer" is a different statement from "it does not
# halt" / "it is not retryable". A caller that collapsed them would read an
# unrecognized word as a benign, non-halting one.
assert_exit_code "disposition_halts returns 2 (not 1) for an unknown word" 2 \
    "$(_rc_of disposition_halts "wedged")"
assert_exit_code "disposition_retryable returns 2 (not 1) for an unknown word" 2 \
    "$(_rc_of disposition_retryable "wedged")"

unk_dir="$TEST_TEMP_DIR/plugins/unkstage"
_make_manifest "$unk_dir" "unkstage" "${ART_DIR}/unk-result.json"
jq -nc '{result_contract:2,verdict:"pass",disposition:"wedged",reason:"a word off the list"}' \
    > "$ART_DIR/unk-result.json"

assert_eq "v2 result with an off-list disposition -> structural failure (error)" \
    "error" "$(runner_read_stage_verdict "$STATE_DIR" "$unk_dir/manifest.yaml" "unkstage" 0)"
assert_eq "the raw channel agrees it is a structural failure" \
    "error" "$(runner_read_stage_verdict_raw "$STATE_DIR" "$unk_dir/manifest.yaml" "unkstage" 0)"
assert_contains "the violation names the offending word on the reason channel" \
    "$(runner_read_stage_reason "$STATE_DIR" "$unk_dir/manifest.yaml" "unkstage" 0)" \
    "wedged"
# A violated result resolves to `broken` on the disposition channel, so the two
# channels agree. Returning the declared word here would tell a caller reading
# only this channel "throttled, retry" about a result the engine has already
# rejected — the infinite-retry regression this issue exists to guard against.
# Nothing is lost: the offending word survives verbatim on the reason channel
# (asserted above). This is not an invented default — the engine is concluding a
# defect and halting, not guessing a value in order to carry on.
assert_eq "an off-list disposition resolves to broken (channels agree)" \
    "broken" "$(runner_read_stage_disposition "$STATE_DIR" "$unk_dir/manifest.yaml" "unkstage" 0)"

# The same rule for a violation on a DIFFERENT mandatory field: a valid
# disposition on an otherwise-invalid result is still untrustworthy, because
# nothing about the missing field is confined to the field it is missing from.
jq -nc '{result_contract:2,disposition:"throttled",reason:"verdict is missing"}' \
    > "$ART_DIR/unk-result.json"
assert_eq "a valid disposition on a result missing its verdict -> broken" \
    "broken" "$(runner_read_stage_disposition "$STATE_DIR" "$unk_dir/manifest.yaml" "unkstage" 0)"
assert_eq "...and that result is a structural failure on the verdict channel" \
    "error" "$(runner_read_stage_verdict "$STATE_DIR" "$unk_dir/manifest.yaml" "unkstage" 0)"

# ═══ 6. A stage that died with no result is `broken` ════════════════════════
# The engine's own conclusion. It does NOT backfill the stage's artifact —
# there is nothing on disk to read, and there still is nothing afterwards.
print_test_section "a dispatch that left no result is broken"

dead_dir="$TEST_TEMP_DIR/plugins/deadstage"
_make_manifest "$dead_dir" "deadstage" "${ART_DIR}/dead-result.json"
rm -f "$ART_DIR/dead-result.json"

assert_eq "died (rc=1) with no result -> broken" \
    "broken" "$(runner_read_stage_disposition "$STATE_DIR" "$dead_dir/manifest.yaml" "deadstage" 1)"
assert_file_not_exists "the engine did not fabricate a result file" \
    "$ART_DIR/dead-result.json"

# A result that exists but is unparseable is a defect too — the stage claimed
# to have written an answer and did not.
printf '{not json' > "$ART_DIR/dead-result.json"
assert_eq "died with an unparseable result -> broken" \
    "broken" "$(runner_read_stage_disposition "$STATE_DIR" "$dead_dir/manifest.yaml" "deadstage" 1)"
rm -f "$ART_DIR/dead-result.json"

# A stage that died AFTER declaring a disposition keeps its own word: this is
# `plan`'s hand-rolled `return 1`, which is exactly what #1822 exists to stop
# being fatal-by-default. rc≠0 must not overwrite a declared field.
alive_dir="$TEST_TEMP_DIR/plugins/alivestage"
_make_manifest "$alive_dir" "alivestage" "${ART_DIR}/alive-result.json"
jq -nc '{result_contract:2,verdict:"incomplete",disposition:"interrupted",reason:"router_timeout"}' \
    > "$ART_DIR/alive-result.json"
assert_eq "died (rc=1) but declared interrupted -> interrupted, not broken" \
    "interrupted" "$(runner_read_stage_disposition "$STATE_DIR" "$alive_dir/manifest.yaml" "alivestage" 1)"

# ═══ 7. v1 results are untouched — versioned coexistence ════════════════════
# Nothing writes a v2 result today. A v1 stage declares no disposition, so the
# response table is not consulted and today's verdict-driven control flow runs
# unchanged. This is what keeps the ADR-021 member-disposition contract
# (terminal|recoverable|advisory|none, on the SAME field name) inert: those
# artifacts are v1, so the closed-set check never sees them.
print_test_section "v1 results declare no disposition (the table is not consulted)"

v1_dir="$TEST_TEMP_DIR/plugins/v1stage"
_make_manifest "$v1_dir" "v1stage" "${ART_DIR}/v1-result.json"
jq -nc '{verdict:"pass"}' > "$ART_DIR/v1-result.json"
assert_eq "v1 result -> empty disposition" \
    "" "$(runner_read_stage_disposition "$STATE_DIR" "$v1_dir/manifest.yaml" "v1stage" 0)"
assert_eq "v1 result still classifies exactly as before" \
    "pass" "$(runner_read_stage_verdict "$STATE_DIR" "$v1_dir/manifest.yaml" "v1stage" 0)"

# The collision guard, stated as a test: a v1 artifact carrying ADR-021's
# `terminal` is NOT a structural failure. Break this and the acceptance gate's
# cycle-halt path (cycle-orchestrator.sh `_cycle_member_terminal_failure`)
# turns into a contract violation on every failing gate.
jq -nc '{verdict:"fail",disposition:"terminal",reason:"acceptance gate"}' > "$ART_DIR/v1-result.json"
assert_eq "v1 ADR-021 disposition=terminal is NOT a structural failure" \
    "fail" "$(runner_read_stage_verdict "$STATE_DIR" "$v1_dir/manifest.yaml" "v1stage" 0)"
assert_eq "v1 ADR-021 disposition is not surfaced on the v2 channel" \
    "" "$(runner_read_stage_disposition "$STATE_DIR" "$v1_dir/manifest.yaml" "v1stage" 0)"

# ═══ 8. The disposition appears on the dispatch event ═══════════════════════
print_test_section "the disposition is surfaced on the dispatch event"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh" 2>/dev/null || true

: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_CYCLE_ID="c1"
_CYCLE_TRAP_ITER=1
_CYCLE_DISPATCH_DISPOSITION="throttled"
_cycle_emit_member_dispatch_complete 0 "build" 1 "error" "failed"

assert_event_emitted "dispatch.complete is emitted" \
    "$ZBUILD_EVENTS_JSONL" "cycle.member.dispatch.complete"
assert_eq "the event carries the disposition" "throttled" \
    "$(jq -r 'select(.type=="cycle.member.dispatch.complete") | .data.disposition // ""' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "the event carries the engine's response to it" "retry_after_wait" \
    "$(jq -r 'select(.type=="cycle.member.dispatch.complete") | .data.disposition_response // ""' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"

# A v1 dispatch declares nothing, and the event must not invent a value.
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_DISPATCH_DISPOSITION=""
_cycle_emit_member_dispatch_complete 0 "build" 0 "pass" "complete"
assert_eq "a v1 dispatch reports an empty disposition, not a default" "" \
    "$(jq -r 'select(.type=="cycle.member.dispatch.complete") | .data.disposition // ""' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"

# An off-list word reaching the event (it should not, since the reader resolves
# a violation to `broken` — but the emitter must not fabricate a response for
# one if it ever does).
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_DISPATCH_DISPOSITION="wedged"
_cycle_emit_member_dispatch_complete 0 "build" 1 "error" "failed"
assert_eq "an off-list word is reported verbatim on the event" "wedged" \
    "$(jq -r 'select(.type=="cycle.member.dispatch.complete") | .data.disposition // ""' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "...with no response invented for it" "" \
    "$(jq -r 'select(.type=="cycle.member.dispatch.complete") | .data.disposition_response // ""' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"

# The nested-cycle leak — an outer cycle inheriting its inner cycle's last leaf
# disposition — is covered BEHAVIOURALLY, against a real two-level cycle, in
# tests/integration/cycle-member-dispatch-events-test.sh section 3. It is not
# duplicated here as a source grep: a test that asserts a line of code exists
# passes for a line that does nothing.

cleanup_test_env
print_test_results
exit $((FAIL > 0))
