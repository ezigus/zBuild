#!/usr/bin/env bash
# tests/unit/test-author-test.sh — assertions are authored from the SPEC, by a
# stage that cannot see the implementation (#2022).
#
# Build authoring both the code and the assertion is correlated error: the two
# agree by construction, so no check comparing them can catch a misreading. Two
# runs shipped exactly that (ADR-036:512; #1978). This stage takes assertion
# authorship back, and its ISOLATION is the mechanism — an author that can read
# the implementation would just describe it, which is the defect wearing a
# different hat.
#
#   SPEC-1 [change]: the prompt carries the SPEC's requirement TEXT, not just
#                    its id — the #1978 defect was the text sitting 130 lines
#                    away while the instruction named only the id
#   SPEC-2 [guard] : the prompt carries NO implementation — not the diff, not
#                    the build summary. Isolation is the whole mechanism
#   SPEC-3 [change]: a completed authoring pass records the assertion digests,
#                    so assertion-integrity has a baseline to compare against
#   SPEC-4 [guard] : v2 contract — result_contract:2 on the result, rc binary
#   SPEC-5 [change]: a router failure maps to a DISPOSITION (ADR-054 §6), not to
#                    a cheerful verdict — the stage did not do its job
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-author: assertions from the SPEC, blind to the code (#2022)"
setup_test_env "test-author"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

_TA_PROMPT="$TEST_TEMP_DIR/prompt.txt"
_TA_RC=0

# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"

# The stubs come AFTER the source, the convention every other agent-plugin unit
# test follows (build-acceptance-charter-test.sh:33-37). The plugin sources
# core/router/route.sh (#2060), which defines the real route_to_model and
# resolve_tier — a stub declared first would simply be overwritten.
#
# This file remains blind by construction to whether the plugin has a router at
# all: it prepares one either way. tests/integration/test-author-router-dispatch-test.sh
# is the test that can see that, and it dispatches in a fresh process for exactly
# this reason.
route_to_model() { printf '%s' "$2" > "$_TA_PROMPT"; printf 'authored\n'; return $_TA_RC; }
resolve_tier() { printf 'T2'; }

_setup() {
    _S="$TEST_TEMP_DIR/$1"; _A="$_S/artifacts"; _R="$_S/repo"
    mkdir -p "$_A" "$_R/tests"
    export ZBUILD_REPO_ROOT="$_R" ZBUILD_ARTIFACT_DIR="$_A"
    printf '%s\n' 'assert_eq "[SPEC-1] placeholder" "1" "$got"' > "$_R/tests/acc-test.sh"
    cat > "$_A/design.md" <<'EOF'
# Design
```acceptance
SPEC-1[change]: plugin-specific fields live under data:{} not at the top level
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
EOF
    # The implementation, sitting right beside the design where a careless
    # prompt builder would sweep it in.
    printf 'diff --git a/x b/x\n+exit_code at top level\n' > "$_A/diff.patch"
    printf '{"verdict":"pass","files_changed_count":3}' > "$_A/build-summary.json"
    printf '{}' > "$_S/pipeline-state.json"
}
_res() { jq -r "$1" "$_A/test-author-result.json" 2>/dev/null || echo MISSING; }

# ─── Happy path ─────────────────────────────────────────────────────────────
_setup ok
_TA_RC=0
set +e; test_author_run "test-author" "$_S/pipeline-state.json"; _rc=$?; set -e
_P="$(cat "$_TA_PROMPT" 2>/dev/null || true)"

assert_contains "[SPEC-1][change] the prompt carries the SPEC's requirement TEXT" \
    "$_P" "fields live under data:{} not at the top level"
assert_eq "[SPEC-2][guard] the prompt carries NO diff" \
    "0" "$(grep -c 'diff --git' <<< "$_P" || true)"
assert_eq "[SPEC-2][guard] nor the build summary" \
    "0" "$(grep -c 'files_changed_count' <<< "$_P" || true)"
assert_file_exists "[SPEC-3][change] a completed pass records the assertion digests" \
    "$_A/assertion-digests.txt"
assert_eq "[SPEC-4][guard] the result declares result_contract 2" "2" "$(_res '.result_contract')"
assert_eq "[SPEC-4][guard] rc is binary — a good pass is 0" "0" "$_rc"
assert_eq "[SPEC-4][guard] a completed pass is disposition=complete" \
    "complete" "$(_res '.disposition')"

# ─── Router failure ─────────────────────────────────────────────────────────
_setup timeout
_TA_RC=124
set +e; test_author_run "test-author" "$_S/pipeline-state.json"; _rc2=$?; set -e
assert_eq "[SPEC-5][change] a router timeout is NOT reported as a clean authoring pass" \
    "degraded" "$(_res '.verdict')"
assert_eq "[SPEC-5][change] and it maps to a non-complete disposition" \
    "1" "$([[ "$(_res '.disposition')" != "complete" ]] && echo 1 || echo 0)"
assert_eq "[SPEC-4][guard] rc stays binary on failure" \
    "1" "$([[ "$_rc2" == "0" || "$_rc2" == "1" ]] && echo 1 || echo 0)"

# ─── SPEC-6/7 (#2170): the author knows its budget, and the budget fits the job ─
# #1841: test-author ran under the engine default of 25 tool-call turns (plan and
# impact get 45; design and build are unbounded) with no budget block in its
# prompt, and hit "Reached max turns (25)" on every call.
print_test_section "SPEC-6: the prompt carries the ADR-063 TURN BUDGET block from the enforcing value"
_setup s6
_TA_RC=0
_route_resolve_max_turns() { printf '45'; }
_route_resolve_timeout() { printf '600'; }
test_author_run "test-author" "$_S/pipeline-state.json" >/dev/null 2>&1 || true
assert_contains "[SPEC-6][change] the prompt carries the TURN BUDGET block" "$(cat "$_TA_PROMPT")" "TURN BUDGET"
assert_contains "[SPEC-6][change] …with the number the router enforces" "$(cat "$_TA_PROMPT")" "45 tool-call turns"
assert_contains "[SPEC-6][change] …and the WALL CLOCK BUDGET block" "$(cat "$_TA_PROMPT")" "WALL CLOCK BUDGET"
unset -f _route_resolve_max_turns _route_resolve_timeout
print_test_section "SPEC-7: simple.yaml gives test-author a turn budget that fits authoring a contract"
_mt="$(awk '/^test-author:/{f=1;next} /^[a-z]/{f=0} f && /max_turns:/{print $2}' "$REPO_ROOT/config/templates/simple.yaml")"
assert_eq "[SPEC-7][change] simple.yaml test-author.router.max_turns is 45 (plan/impact parity), not the 25 default" "45" "$_mt"

# ─── SPEC-8/9 (#2174): the author owns every [SPEC-n] tag in the files it writes ─
# #1841: security-lens-test.sh carried [SPEC-5]/[SPEC-6] labels from an older
# contract; the gate greps by tag, matched those, and called the new SPEC-5/6
# tautologies. A tag whose number is not in THIS contract is stale by
# definition: the assertion stays, the tag goes.
print_test_section "SPEC-8: the prompt tells the author stale tags are dropped"
_setup s8
_TA_RC=0
test_author_run "test-author" "$_S/pipeline-state.json" >/dev/null 2>&1 || true
assert_contains "[SPEC-8][change] the prompt says a [SPEC-n] tag not in this contract is dropped (assertion kept)" \
    "$(cat "$_TA_PROMPT")" "not in this contract"
print_test_section "SPEC-9: stale tags are stripped mechanically after authoring"
_setup s9
printf '%s\n' 'assert_eq "[SPEC-1] placeholder" "1" "$got"' 'assert_eq "[SPEC-5] old contract: ANSI bytes stripped" "x" "$y"' 'assert_eq "[SPEC-12] old contract too" "a" "$b"' > "$_R/tests/acc-test.sh"
_TA_RC=0
test_author_run "test-author" "$_S/pipeline-state.json" >/dev/null 2>&1 || true
assert_eq "[SPEC-9][change] a tag whose number is not in the contract is removed" "0" "$(grep -c '\[SPEC-5\]\|\[SPEC-12\]' "$_R/tests/acc-test.sh" || true)"
assert_contains "[SPEC-9][change] …the assertion itself stays" "$(cat "$_R/tests/acc-test.sh")" 'old contract: ANSI bytes stripped'
assert_contains "[SPEC-9][guard] a tag in the contract is kept" "$(cat "$_R/tests/acc-test.sh")" '[SPEC-1] placeholder'
assert_eq "[SPEC-9][change] the strip is recorded as an event" "1" "$(grep -c '"test_author.stale_tags_dropped"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"

print_test_results
exit $((FAIL > 0))
