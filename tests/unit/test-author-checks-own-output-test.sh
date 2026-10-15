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

# The author's model: each call writes the tagged assertion and says done.
route_to_model_loop() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/author-calls"
    cp "$2" "$TEST_TEMP_DIR/author-prompt-$n"
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
