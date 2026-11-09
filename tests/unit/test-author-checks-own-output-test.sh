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
# A1 [change] (#2460) a mismatch ends the try `unusable`, with a finding naming the SPEC and
#             why; corresponding in round 2 passes
# A2 [change] (#2460) one model call per try — the engine, not the stage, runs it again; the result
#             lists the finding, rc 0
# A3 [change] the check call is rate-limited: that is test-author's outcome
# A4 [change] (#2460) test-author has no rounds of its own (no config.check_rounds); its template
#             gives the engine retries (retry: 2)
# A5 [change] the build loop requires test-author to pass; spec-correspondence
#             is no longer a stage
# A6 [change] each try is one model call, given no call limit (#2439: one
#             call per try; was a budget of calls the rounds shared, #1801)
# A7 retired (#2439): there is no call budget left to run out of; the rounds
#             end at check_rounds (A2)
# A9 [change] the summary later stages read lists each test file and the
#             requirements it covers, and says they fail on today's code
#             (#1801 run 40390919951: build ran them to find out)
# A8 [change] the author runs nothing — its new and changed test files are run
#             by test-author's own script on the old code (#2445; was #2441's
#             "run your own test files", a model judging its own tests) — and
#             reads the existing tests and test helpers, not the code the change
#             is about
# A10 [change] findings from other stages about its tests are its to fix or
#             answer (ADR-068 §6; #1754 run: the test stage said two tests
#             already passed on the old code and one failed on the new, and
#             test-author fixed only its own check's findings)
# A11 [change] it is not told its assertions are expected to fail on today's
#             code: after round 1 today's code holds the change
# A13 [change] a finding it is shown and does not answer is asked for, and
#             every answer, with how many findings it was shown, is recorded
#             (ADR-068 §6)
# A14 [change] (#2503) told a test of its fails, it runs that test file and
#             finds why before changing it, and never deletes an assertion to
#             make it pass. #1805 run 42523805245: told "expected >0, got 0", it
#             guessed the engine lacked the behaviour and deleted the
#             assertion; the cause was its own mock, missing a role.
# A15 [change] (#2506) it may run a test file of its own that it is told
#             fails, and nothing else: never the suite or lint. #1805 run
#             42556446368: told both "run that test file" (A14) and "Run
#             nothing", it ran no test in four calls and guessed.
# A12 [change] what it did about each finding — its latest answer to each (#2460) — is recorded in its result and
#             summary (ADR-068 §6)
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

# The author's model: each round writes the tagged assertion and says done.
route_to_model_loop() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/author-calls"
    cp "$2" "$TEST_TEMP_DIR/author-prompt-$n"
    printf '%s' "$#" > "$TEST_TEMP_DIR/author-argc-$n"
    _ROUTE_LOOP_ITERATIONS=1
    # A test that runs on its own and fails on the old code, as a [code] test
    # must: test-author's script runs it there (#2445).
    {
        printf '#!/usr/bin/env bash\n'
        printf 'assert_eq() { if [[ "$2" == "$3" ]]; then printf "  ✓ %%s\\n" "$1"; else printf "  ✗ %%s\\n" "$1"; return 1; fi; }\n'
        printf 'rc=0\n'
        printf 'assert_eq "%s an empty input returns rc 1" "1" "$rc" || exit 1\n' "$TAG"
    } > "$R/tests/acc-test.sh"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_LAST_RESPONSE="${ANSWERS:-}"$'\n'"LOOP_COMPLETE"
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

# #2464 (ADR-072 §3): a verdict short of corresponds quotes the requirement.
# #2467 (ADR-073 §6): a line per part of the SPEC, and one for the test's sections.
MISMATCH=$'SPEC-1 Then 1: wrong | WHY: it checks the exit code of the wrong command | QUOTE: "an empty input returns rc 1"\nSPEC-1 sections: ok'
CORRESP=$'SPEC-1 Then 1: ok\nSPEC-1 sections: ok'

# ── A1 ───────────────────────────────────────────────────────────────────────
# #2460: the engine owns every retry. A mismatch ends this try `unusable`, the
# finding in the result, and the engine's next try is told it under Previous work.
JUDGE=("$MISMATCH" "$CORRESP"); JUDGE_RC=0
_run
assert_eq "[A1] a mismatch is not sent back to the model inside the try" "1" "$CALLS"
assert_eq "[A1] ...the try ends unusable, for the engine to run again" "unusable" "$OUTCOME"
assert_eq "[A1] ...rc 1 (the try did not produce a usable result)" "1" "$RC"
assert_contains "[A1] the result names the SPEC and why" "$FINDINGS" "it checks the exit code of the wrong command"

# ── A2 ───────────────────────────────────────────────────────────────────────
JUDGE=("$MISMATCH"); JUDGE_RC=0
_run
assert_eq "[A2] one model call per try, no more" "1" "$CALLS"
assert_eq "[A2] still a mismatch: outcome unusable, not fail" "unusable" "$OUTCOME"
assert_contains "[A2] the result lists the finding" "$FINDINGS" "SPEC-1"
assert_eq "[A2] the stage no longer re-asks itself: no fix-up rounds" "0" \
    "$(grep -c '_ta_fixup_calls_v\|check_rounds' "$REPO_ROOT/plugins/agent/test-author/plugin.sh" || true)"

# ── A3 ───────────────────────────────────────────────────────────────────────
JUDGE=("rate limited"); JUDGE_RC=1
_router_rc_classify() { printf -v "$2" '%s' error; printf -v "$3" '%s' router_rate_limited; }
_run
assert_eq "[A3] a rate-limited check call is test-author's outcome" "rate_limited" "$OUTCOME"
unset -f _router_rc_classify

# ── A4 ───────────────────────────────────────────────────────────────────────
assert_eq "[A4] test-author's manifest sets no rounds of its own" "" \
    "$(yaml_get "$REPO_ROOT/plugins/agent/test-author/manifest.yaml" config.check_rounds 2>/dev/null)"
for _tpl in simple; do
    assert_eq "[A4] $_tpl.yaml gives test-author the engine's retries (retry: 2)" "2" \
        "$(awk '/^test-author:/{f=1;next} /^[a-z_-]+:/{f=0} f && /^  retry:/{print $2}' "$REPO_ROOT/config/templates/$_tpl.yaml")"
done

# ── A6 ───────────────────────────────────────────────────────────────────────
JUDGE=("$CORRESP"); JUDGE_RC=0
_run
assert_eq "[A6] one call in the try" "1" "$CALLS"
assert_eq "[A6] the call is given no call limit: <tier> <prompt> <repo>" "3" "$(cat "$TEST_TEMP_DIR/author-argc-1" 2>/dev/null)"
assert_eq "[A6] ...and corresponding passes" "pass" "$OUTCOME"

# ── A8 ───────────────────────────────────────────────────────────────────────
JUDGE=("$CORRESP"); JUDGE_RC=0
_run
_AP="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null)"
assert_contains "[A8] its test files are run for it on the old code when it finishes (#2506: it runs nothing else)" "$_AP" \
    "When you finish, the test files you create or change are run on the code from before this change"
assert_contains "[A8] ...where each must fail for the reason it intends" "$_AP" "must fail there for the reason you intend"
assert_eq "[A8] it is no longer told to run nothing" "0" "$(grep -c 'Do not run anything' <<< "$_AP" || true)"
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
assert_contains "[A9] ...and says each must fail on the code from before this change (A11)" "$_SUM" \
    "Each [code] requirement's test must fail on the code from before this change, and pass once the code is written"

# ── A10 / A11 ────────────────────────────────────────────────────────────────
JUDGE=("$CORRESP"); JUDGE_RC=0
_run
_AP="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null)"
assert_contains "[A10] findings from other stages about its tests are its own" "$_AP" \
    "Findings from other stages about your tests are yours"
assert_contains "[A10] ...naming a test that already passes on the old code" "$_AP" \
    "a test that already passes on the code from before this change"
assert_contains "[A10] ...a test that fails on the new code" "$_AP" "a test that fails on the new code"
assert_contains "[A10] ...a test that flags code that already meets its requirement" "$_AP" \
    "a test that flags code that already meets its requirement"
assert_contains "[A10] ...and a test file far slower than the rest" "$_AP" "a test file far slower than the rest"
assert_contains "[A10] ...and a test build says is wrong, with its reason (#2441)" "$_AP" \
    "a test build says is wrong (build-tests findings), with its reason"
assert_contains "[A10] it answers each one on its own line" "$_AP" "ANSWER <the finding as listed>:"
assert_eq "[A11] it is not told its assertions fail on the code as it is today" "0" \
    "$(grep -c 'expected to fail on the code as it is today' <<< "$_AP" || true)"
assert_contains "[A11] ...but on the code from before this change" "$_AP" \
    "are run on the code from before this change"

# ── A14 ──────────────────────────────────────────────────────────────────────
assert_contains "[A14] told a test of its fails, it runs it and finds why first" "$_AP" \
    "When you are told a test of yours fails, run that test file and find out why before you change it"
assert_contains "[A14] ...and never deletes an assertion to make it pass" "$_AP" \
    "never delete an assertion to make a test pass"

# ── A15 ──────────────────────────────────────────────────────────────────────
assert_contains "[A15] it runs only a test file of its own that it is told fails" "$_AP" \
    "Run nothing else: run only a test file of yours that you are told fails, and never the suite or lint"
assert_eq "[A15] ...and is no longer told to run nothing at all" "0" "$(grep -c 'Run nothing:' <<< "$_AP" || true)"

# ── A12 ──────────────────────────────────────────────────────────────────────
JUDGE=("$CORRESP"); JUDGE_RC=0
ANSWERS="ANSWER test finding 2: done — SPEC-1's assertion now checks the reason the old code never writes"
_run
assert_contains "[A12] the answer is in test-author's result" \
    "$(jq -r '.data.answers[]? // empty' "$A/test-author-result.json" 2>/dev/null)" "test finding 2: done"
assert_contains "[A12] ...and in its summary" "$(cat "$A/test-author-summary.md" 2>/dev/null)" "test finding 2: done"
ANSWERS="ANSWER test finding 3: wrong — the test is right   "
_run
assert_eq "[A12] an answer keeps no trailing spaces (review on PR #2438)" \
    "test finding 3: wrong — the test is right" "$(jq -r '.data.answers[0] // empty' "$A/test-author-result.json" 2>/dev/null)"
# #2460: a finding answered twice keeps only its latest answer.
ANSWERS=$'ANSWER test finding 1: wrong — the label is there\nANSWER test finding 2: done — fixed\nANSWER test finding 1: done — moved the label onto the assert line'
_run
assert_eq "[A12] a finding answered twice keeps only its latest answer" \
    "test finding 1: done — moved the label onto the assert line|test finding 2: done — fixed" \
    "$(jq -r '[.data.answers[]?] | sort | join("|")' "$A/test-author-result.json" 2>/dev/null)"
ANSWERS=""

# ── A13 ──────────────────────────────────────────────────────────────────────
# The engine's answer check (zb_answers_finish, finding-answers-test.sh B1-B3)
# is handed test-author's prompt and reply, and what it returns is kept.
eval "_a13_real_$(declare -f zb_answers_finish)"
zb_answers_finish() {
    local -n _a13a="$1"; printf '%s' "$2" > "$TEST_TEMP_DIR/finish-prompt"; printf '%s' "$3" > "$TEST_TEMP_DIR/finish-reply"
    _a13a+=("lens-sre-code finding 1: not mine — a code fix"); _ZB_ANS_SHOWN=1; _ZB_ANS_MISSING=""
}
JUDGE=("$CORRESP"); JUDGE_RC=0
_run
assert_contains "[A13] the check is handed test-author's prompt" "$(cat "$TEST_TEMP_DIR/finish-prompt" 2>/dev/null)" "SPEC-1"
assert_contains "[A13] ...and its reply" "$(cat "$TEST_TEMP_DIR/finish-reply" 2>/dev/null)" "LOOP_COMPLETE"
assert_eq "[A13] what it returns is kept in its result" \
    "lens-sre-code finding 1: not mine — a code fix" "$(jq -r '.data.answers[0] // empty' "$A/test-author-result.json" 2>/dev/null)"
assert_eq "[A13] ...with how many findings it was shown" "1" "$(jq -r '.data.findings_shown // "none"' "$A/test-author-result.json" 2>/dev/null)"
assert_contains "[A13] ...and its summary says so" "$(cat "$A/test-author-summary.md" 2>/dev/null)" "answered: lens-sre-code finding 1: not mine"
eval "$(declare -f _a13_real_zb_answers_finish | sed '1s/_a13_real_//')"

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
