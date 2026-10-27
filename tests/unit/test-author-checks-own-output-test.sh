#!/usr/bin/env bash
# tests/unit/test-author-checks-own-output-test.sh — test-author checks that its
# assertions test what their requirements say, and goes back to its model with
# what does not (#2370, ADR-040, ADR-068).
#
# Why: a check that reads one stage's output belongs to that stage. The check
# that was the spec-correspondence stage (a model call: does each assertion test
# what its SPEC says?) runs inside test-author after its model writes the
# assertions. What does not correspond goes back to its model until it does or
# its rounds (config.check_rounds) run out; then its one outcome is fail, and
# the build loop requires test-author to pass.
#
# A1 [change] a mismatch in round 1 goes back to the model, naming the SPEC and
#             why; corresponding in round 2 passes
# A2 [change] still a mismatch when the rounds run out: outcome fail, the result
#             lists the finding, rc 0
# A3 [change] the check call is rate-limited: that is test-author's outcome
# A4 [change] the rounds come from test-author's own manifest (2)
# A5 [change] the build loop requires test-author to pass; spec-correspondence
#             is no longer a stage
# A6 [change] the rounds share one budget of model calls: round 2 gets only the
#             calls round 1 left (#1801 run 40329281392: a fresh 4 per round
#             overran the stage's time limit, and the stage was killed)
# A7 [change] no calls left after round 1: no round 2; the outcome is fail and
#             the result lists the finding
# A9 [change] the summary later stages read lists each test file and the
#             requirements it covers, and says they fail on today's code
#             (#1801 run 40390919951: build ran them to find out)
# A8 [change] the author is told to run nothing, and to read the existing tests
#             and test helpers, not the code the change is about (#1944 run
#             40329284881: it ran the suite and lint, and read core/)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "test-author checks its own assertions (#2370)"
setup_test_env "test-author-checks-own-output"

# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
TAG="$(acceptance_spec_tag SPEC-1)"

# The author's model: each round writes the tagged assertion and says done,
# having used USED of the calls it was given (the loop's own counter).
_route_resolve_max_iterations() { printf '4'; }
USED=1
route_to_model_loop() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/author-calls"
    cp "$2" "$TEST_TEMP_DIR/author-prompt-$n"
    printf '%s' "$4" > "$TEST_TEMP_DIR/author-budget-$n"
    _ROUTE_LOOP_ITERATIONS="$USED"
    printf 'assert_eq "%s an empty input returns rc 1" "1" "$rc"\n' "$TAG" > "$R/tests/acc-test.sh"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    return 0
}
# The check's model: answer n is ${JUDGE[n-1]} (the last repeats); JUDGE_RC its rc.
JUDGE=(); JUDGE_RC=0
route_to_model() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/judge-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/judge-calls"
    printf '%s\n' "${JUDGE[$((n - 1))]:-${JUDGE[${#JUDGE[@]}-1]}}"
    return "$JUDGE_RC"
}

_run() {
    rm -rf "$TEST_TEMP_DIR/run" "$TEST_TEMP_DIR"/author-* "$TEST_TEMP_DIR"/judge-*
    local d="$TEST_TEMP_DIR/run"; R="$d/repo"; A="$d/state/artifacts"
    mkdir -p "$A" "$R/tests"
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && : > tests/acc-test.sh && git add -A && git commit -q -m seed ) >/dev/null 2>&1
    printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
    cat > "$A/design.md" <<'MD'
# Design
```acceptance
SPEC-1[code]: an empty input returns rc 1
WIRING: none
TESTFILES:
SPEC-1: tests/acc-test.sh
```
MD
    export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
    test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1
    RC=$?
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$A/test-author-result.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$A/test-author-result.json" 2>/dev/null || true)"
    CALLS="$(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0)"
}

MISMATCH="SPEC-1: VERDICT: mismatch REASON: it checks the exit code of the wrong command"
CORRESP="SPEC-1: VERDICT: corresponds REASON: it checks the requirement"

# ── A1 ───────────────────────────────────────────────────────────────────────
JUDGE=("$MISMATCH" "$CORRESP"); JUDGE_RC=0
_run
assert_eq "[A1] the model is called again after a mismatch" "2" "$CALLS"
assert_contains "[A1] round 2's prompt names the SPEC and why" \
    "$(cat "$TEST_TEMP_DIR/author-prompt-2" 2>/dev/null)" "it checks the exit code of the wrong command"
assert_eq "[A1] corresponding in round 2 passes" "pass" "$OUTCOME"

# ── A2 ───────────────────────────────────────────────────────────────────────
JUDGE=("$MISMATCH"); JUDGE_RC=0
_run
assert_eq "[A2] the model is called once per round, no more" "2" "$CALLS"
assert_eq "[A2] still a mismatch when the rounds run out: outcome fail" "fail" "$OUTCOME"
assert_eq "[A2] ...rc 0 (the stage finished)" "0" "$RC"
assert_contains "[A2] the result lists the finding" "$FINDINGS" "SPEC-1"

# ── A3 ───────────────────────────────────────────────────────────────────────
JUDGE=("rate limited"); JUDGE_RC=1
_router_rc_classify() { printf -v "$2" '%s' error; printf -v "$3" '%s' router_rate_limited; }
_run
assert_eq "[A3] a rate-limited check call is test-author's outcome" "rate_limited" "$OUTCOME"
unset -f _router_rc_classify

# ── A4 ───────────────────────────────────────────────────────────────────────
assert_eq "[A4] test-author's manifest sets its rounds" "2" \
    "$(yaml_get "$REPO_ROOT/plugins/agent/test-author/manifest.yaml" config.check_rounds 2>/dev/null)"

# ── A6 ───────────────────────────────────────────────────────────────────────
JUDGE=("$MISMATCH" "$CORRESP"); JUDGE_RC=0; USED=3
_run
assert_eq "[A6] round 1 is given the stage's calls" "4" "$(cat "$TEST_TEMP_DIR/author-budget-1" 2>/dev/null)"
assert_eq "[A6] round 2 is given only the calls round 1 left" "1" "$(cat "$TEST_TEMP_DIR/author-budget-2" 2>/dev/null)"
assert_eq "[A6] ...and corresponding then passes" "pass" "$OUTCOME"

# ── A7 ───────────────────────────────────────────────────────────────────────
JUDGE=("$MISMATCH"); JUDGE_RC=0; USED=4
_run
assert_eq "[A7] no calls left: no round 2" "1" "$CALLS"
assert_eq "[A7] ...the outcome is fail" "fail" "$OUTCOME"
assert_eq "[A7] ...rc 0 (the stage finished)" "0" "$RC"
assert_contains "[A7] ...and the result lists the finding" "$FINDINGS" "SPEC-1"
USED=1

# ── A8 ───────────────────────────────────────────────────────────────────────
JUDGE=("$CORRESP"); JUDGE_RC=0
_run
_AP="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null)"
assert_contains "[A8] the author is told to run nothing" "$_AP" "Do not run anything"
assert_contains "[A8] ...naming tests, lint and the suite" "$_AP" "no tests, no lint, no test suite"
assert_contains "[A8] it may read the existing tests and test helpers" "$_AP" \
    "You may read the existing tests and the repository's test helpers"
assert_contains "[A8] ...not the code the change is about" "$_AP" "do not read the code this change is about"
assert_eq "[A8] it is no longer told to open the code that writes the data" "0" \
    "$(grep -c 'open the code that writes it' <<< "$_AP" || true)"

# ── A9 ───────────────────────────────────────────────────────────────────────
JUDGE=("$CORRESP"); JUDGE_RC=0
_run
_SUM="$(tr -s '[:space:]' ' ' < "$A/test-author-summary.md" 2>/dev/null)"
assert_contains "[A9] the summary lists each test file with its requirements" "$_SUM" "tests/acc-test.sh — SPEC-1"
assert_contains "[A9] ...and says they fail on today's code" "$_SUM" \
    "Each [code] requirement's test fails on the code as it is now, and passes once the code is written"

# ── A5 ───────────────────────────────────────────────────────────────────────
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1
_req=""
for (( i = 1; i <= ${_TPL_CYCLE_EXIT_COUNT_build_test_cycle:-0}; i++ )); do
    v="_TPL_CYCLE_EXIT_${i}_STAGE_build_test_cycle"; _req+="${!v} "
done
assert_contains "[A5] the build loop requires test-author to pass" "$_req" "test-author "
assert_eq "[A5] spec-correspondence is no longer a stage" "" "${_TPL_STAGE_ROLES_spec_correspondence:-}"
assert_eq "[A5] ...nor a plugin" "absent" "$([[ -d "$REPO_ROOT/plugins/agent/spec-correspondence" ]] && echo present || echo absent)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
