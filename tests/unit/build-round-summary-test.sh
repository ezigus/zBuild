#!/usr/bin/env bash
# Unit test (#2323, ADR-054 §5 amendment): build's result reports the whole
# stage in a cycle round, not only its last pass.
#
# #2032 run 37289606005: round-2 build's first pass committed one file
# (build.commit.created 6ee96b06) and ended on router timeouts; the engine
# re-dispatched it (disposition timed_out, ADR-054 §6a) and the second pass
# changed nothing. The stage then said "changed 0 file(s) over 1 iteration(s)".
#
#   R1 pass 1 commits a file, pass 2 (same round) changes nothing →
#      1 file over 2 passes, in build-summary.md, build-summary.json and the
#      plugin.result event.
#   R2 a NEW round that changes nothing → 0 files over 1 pass (the previous
#      round's work and pass count do not carry over).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #2323: the result counts every pass in the round"
setup_test_env "build-2323-round-summary"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-2323-$$"
export ZBUILD_CYCLE_ID="build_test_cycle"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# MOCK_WRITE=1 → the pass writes in_scope.txt; 0 → it changes nothing.
MOCK_WRITE=1
MOCK_TERMINATED_REASON="done_sentinel"
MOCK_ITERS=1
# shellcheck disable=SC2317
route_to_model_loop() {
    local _repo="$3"
    if [[ "$MOCK_WRITE" -eq 1 ]]; then
        echo "in-scope work from LLM" > "$_repo/in_scope.txt"
    fi
    _ROUTE_LOOP_ITERATIONS="$MOCK_ITERS"
    _ROUTE_LOOP_TERMINATED_REASON="$MOCK_TERMINATED_REASON"
    _ROUTE_LOOP_INPUT_TOKENS=5
    _ROUTE_LOOP_OUTPUT_TOKENS=3
    _ROUTE_LOOP_LAST_RESPONSE=$'edits\nCOMMIT_SUMMARY: t\nLOOP_COMPLETE'
    return 0
}
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 1; }
# shellcheck disable=SC2317
apply_scope_redaction() {
    if [[ -n "${1:-}" && -n "${2:-}" && -f "$1" ]]; then cp -f "$1" "$2"; fi
    return 0
}

REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    echo seed > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -q -m M0
) >/dev/null
BASELINE="$(git -C "$REPO" rev-parse HEAD)"
printf '%s' "$BASELINE" > "$ZBUILD_STATE_DIR/intake-baseline-ref.txt"

ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
SCOPE_MANIFEST="$ZBUILD_STATE_DIR/scope-manifest.md"
DIFF_PATCH="$ARTIFACT_DIR/diff.patch"
SUMMARY_JSON="$ARTIFACT_DIR/build-summary.json"
SUMMARY_MD="$ARTIFACT_DIR/build-summary.md"
printf '%s\n' '{"title":"t","files":["in_scope.txt"]}' > "$PLAN_JSON"
echo "scope: in_scope.txt" > "$SCOPE_MANIFEST"
cd "$REPO"

_run_pass() {
    local rc=0
    _build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$SUMMARY_JSON" "$ARTIFACT_DIR" \
        >/dev/null 2>&1 || rc=$?
    return "$rc"
}

_last_result_field() {
    local f="$1" line="" l
    while IFS= read -r l; do
        [[ "$l" == *'"type":"plugin.result"'* ]] && line="$l"
    done < "$ZBUILD_EVENTS_JSONL"
    jq -r ".data.$f // empty" <<< "$line" 2>/dev/null || true
}

# ─── R1: pass 1 commits one file (timeout), pass 2 changes nothing ──────────
export ZBUILD_CYCLE_ITER=2
: > "$ZBUILD_EVENTS_JSONL"
MOCK_WRITE=1; MOCK_TERMINATED_REASON="router_timeout"; MOCK_ITERS=3
_run_pass || true
committed="$(git -C "$REPO" diff --name-only "$BASELINE" HEAD 2>/dev/null || true)"
assert_eq "R1 fixture: pass 1 committed in_scope.txt" "in_scope.txt" "$committed"

# The engine re-dispatches within the same round: same run, cycle, iteration.
MOCK_WRITE=0; MOCK_TERMINATED_REASON="done_sentinel"; MOCK_ITERS=1
_run_pass || true

head_line="$(sed -n 3p "$SUMMARY_MD" 2>/dev/null || true)"
assert_eq "R1: build-summary.md says 1 file over 2 passes" \
    "- changed 1 file(s) over 2 pass(es), 4 iteration(s)" "$head_line"
assert_eq "R1: build-summary.json files_changed is the round's file" \
    "in_scope.txt" "$(jq -r '(.files_changed // []) | join(",")' "$SUMMARY_JSON" 2>/dev/null || true)"
assert_eq "R1: build-summary.json passes = 2" \
    "2" "$(jq -r '.passes // empty' "$SUMMARY_JSON" 2>/dev/null || true)"
assert_eq "R1: plugin.result files_changed_count = 1" "1" "$(_last_result_field files_changed_count)"
assert_eq "R1: plugin.result passes = 2" "2" "$(_last_result_field passes)"
assert_eq "R1: a round that changed a file is not an empty-diff resting point" \
    "" "$(jq -r '.data.build_kind // empty' "$SUMMARY_JSON" 2>/dev/null || true)"

# ─── R2: the next round changes nothing ─────────────────────────────────────
# The cycle normally clears build-summary.json at a round's start; it is left
# in place here so the round boundary must come from the iteration itself.
export ZBUILD_CYCLE_ITER=3
: > "$ZBUILD_EVENTS_JSONL"
_run_pass || true
head_line="$(sed -n 3p "$SUMMARY_MD" 2>/dev/null || true)"
assert_eq "R2: a new round starts its own count" \
    "- changed 0 file(s) over 1 pass(es), 1 iteration(s)" "$head_line"
assert_eq "R2: files_changed empty" \
    "0" "$(jq -r '(.files_changed // []) | length' "$SUMMARY_JSON" 2>/dev/null || true)"
assert_eq "R2: passes = 1" "1" "$(jq -r '.passes // empty' "$SUMMARY_JSON" 2>/dev/null || true)"

cd "$REPO_ROOT"
# R3: a round on record from ANOTHER iteration, opened under set -euo pipefail
# (as the engine sources build): the lookup finds nothing and must not stop
# the stage. #2323's first cut died here — read returns 1 at end of input.
print_test_section "R3: another iteration's round, under set -e"
_r3="$TEST_TEMP_DIR/r3-summary.json"
printf '%s\n' '{"round":{"run_id":"run-r3","cycle_id":"c","iter":"1","base":"abc","passes":1,"iterations":2}}' > "$_r3"
_r3_out="$(bash -c '
    set -euo pipefail
    source "'"$REPO_ROOT"'/plugins/agent/build/lib/round.sh"
    export ZBUILD_RUN_ID=run-r3 ZBUILD_CYCLE_ID=c ZBUILD_CYCLE_ITER=2
    _build_round_open "'"$_r3"'" "'"$REPO_ROOT"'"
    printf "passes=%s" "$_BUILD_ROUND_PASSES"
' 2>/dev/null || echo "died")"
assert_eq "[R3] the lookup does not stop the stage, and the round starts at pass 1" "passes=1" "$_r3_out"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
