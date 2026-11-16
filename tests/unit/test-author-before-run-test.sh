#!/usr/bin/env bash
# tests/unit/test-author-before-run-test.sh — test-author's model writes tests
# and runs nothing; test-author's own script then runs the test files that call
# created or changed on the code from before this change (#2445, ADR-068 §6).
#
# Why: #2442 had the model run its own tests — a model deciding for itself
# whether its tests fail, which nothing checked. A script runs them instead, and
# only what it finds sends test-author round again. The model is also shown, by
# script, which tests are already written, so a round with nothing to do ends at
# once (#1754 run 41249802310: test-author spent 10–15 minutes a round re-reading
# tests that were already right).
#
# B1 [change] the model is told to run nothing, and that its new and changed
#             test files are run afterwards on the code from before this change
# B2 [change] a [code] requirement's test that passes on that code is a finding
#             that ends the try unusable (#2460: the engine runs it again)
#             that goes back to the model, naming the requirement and the file;
#             still so when the rounds run out: outcome fail, the finding listed
# B3 [guard]  a test that fails there, as it must, is no finding: outcome pass
# B4 [change] a test file whose output holds no line tagged for its SPEC is a
#             finding that says only that: "no line tagged [<id>] appeared in
#             <file>'s output" — never a guess at why (#2554, ADR-069)
# B5 [change] only the files the call created or changed are run: a test file
#             it left as it was is not
# B6 [change] the prompt lists, found by script, each test file and the
#             requirements whose tag it already holds; a file holding none of
#             them is no requirement's test, and is not listed (#2508)
# B7 [change] the prompt says that when every requirement already has its test
#             and no finding is open, it confirms them and finishes
# B8 [change] a test path that leaves the repository (absolute, or with ..) is
#             never copied or run, nor listed in the prompt (review on #2446)
# B10 [change] the list names each requirement that needs a test and has none
#             found yet: "Not written yet: <ids>" (#2506; #1805 run 42556446368:
#             design added DSFSTG-3, the list showed it missing only by leaving it
#             out, and test-author's notes said all 16 were done)
# B9 [guard]  a changed [no-code] test that passes on the old code is no
#             finding: it need not fail there (review on #2446)
# B11 [change] a [done] requirement gets a test too (#2517, ADR-069): it is in the
#             prompt with its tag, its test must pass after the change and need
#             not fail before; a design whose every requirement is done still
#             calls the model; a [done] test that passes on the old code is no
#             finding, and one that fails there is (the old code is said to do it)
# B12 [change] #1764 run 43772987273: a file that runs to the end with failures
#             and tags its assertion [SPEC-1/2] gets the plain finding, whatever
#             its exit code, and no "stopped before" (#2554, ADR-069)
# B13 [change] text shaped like a tag that names more than one SPEC is a finding
#             naming the file, the line and the rule (#2554, ADR-036)
# B14 [change] two tags side by side in one label are a finding naming the line
#             (ADR-036); tags in two arguments of one line are not
# B16 [change] a test file the call created (not in git yet) is checked whole
# B17 [guard]  a line the default branch already has is other work's: two tags
#             or an odd tag there is no finding (ADR-036)
# B18 [guard]  test code that only mentions a tag is no finding: a grep for
#             '\[SPEC-1\]', a [[ … == SPEC-1 ]] test, the expected text of an
#             assertion naming another tag, another issue's [#9/SPEC-1]
# B19 [change] a committed line on the branch (test-author's try 2) is checked,
#             whatever the user's diff settings (mnemonicPrefix, an external
#             diff) — review on #2554
# B20 [change] at most 10 tag findings, then "and N more"
# B15 [change] the prompt says each tag names one SPEC, one per line, and an
#             assertion proving two SPECs is written twice (ADR-036)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "test-author's tests are run by script, on the old code (#2445)"
setup_test_env "test-author-before-run"

# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
T1="$(acceptance_spec_tag SPEC-1)"; T2="$(acceptance_spec_tag SPEC-2)"

# A test file body: passes — prints ✓ for its tag; fails — prints ✗ and exits 1;
# crash — exits before its tagged assertion runs (#2508: the tag is what makes
# it the requirement's test).
_body() {
    case "$1" in
        passes) printf '#!/usr/bin/env bash\nprintf "  ✓ %%s it holds\\n" "%s"\n' "$2" ;;
        fails)  printf '#!/usr/bin/env bash\nprintf "  ✗ %%s it holds\\n" "%s"\nexit 1\n' "$2" ;;
        crash)  printf '#!/usr/bin/env bash\nsource ./no-such-helper.sh || exit 2\nprintf "  ✓ %%s it holds\\n" "%s"\n' "$2" ;;
        # #1764 run 43772987273: the SPEC's tag sits in a comment, the assertion
        # is tagged for two SPECs, and the file runs to the end (exit = failures).
        mistag) printf '#!/usr/bin/env bash\n# Then — %s an empty input returns rc 1\nprintf "  ✗ %%s it holds\\n" "[SPEC-1/2]"\nexit 12\n' "$2" ;;
        twotags) printf '#!/usr/bin/env bash\nprintf "  ✗ %%s it holds\\n" "%s [SPEC-2]"\nexit 1\n' "$2" ;;
    esac
}
# The author's model: round n writes tests/a-test.sh as ${WRITE[n-1]} (the last
# repeats); "same" leaves it as it is.
WRITE=(fails)
route_to_model_loop() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/author-calls"
    cp "$2" "$TEST_TEMP_DIR/author-prompt-$n"
    local w="${WRITE[$((n - 1))]:-${WRITE[${#WRITE[@]}-1]}}"
    [[ "$w" == same ]] || _body "$w" "$T1" > "$R/tests/a-test.sh"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# The correspondence check always agrees: only the script's findings matter here.
route_to_model() { zb_test_check_ok "$2"; }

_run() {
    rm -rf "$TEST_TEMP_DIR/run" "$TEST_TEMP_DIR"/author-*
    local d="$TEST_TEMP_DIR/run"; R="$d/repo"; A="$d/state/artifacts"
    mkdir -p "$A" "$R/tests"
    # The issue's own test files are its branch's (ADR-069 §11): main has
    # none, the branch adds them.
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && : > README && git add -A && git commit -q -m seed && git checkout -q -b work ) >/dev/null 2>&1
    _body passes "$T2" > "$R/tests/b-test.sh"
    ( cd "$R" && : > tests/a-test.sh && git add -A && git commit -q -m tests ) >/dev/null 2>&1
    printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
    if [[ -n "${DESIGN_MD:-}" ]]; then printf '%s\n' "$DESIGN_MD" > "$A/design.md"; else
    cat > "$A/design.md" <<'MD'
# Design
```acceptance
SPEC-1[code]: an empty input returns rc 1
SPEC-2[no-code]: the docs say so
WIRING: none
```
MD
    fi
    export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
    test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1
    RC=$?
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$A/test-author-result.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$A/test-author-result.json" 2>/dev/null || true)"
    CALLS="$(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0)"
}

# ── B1 / B6 / B7 ─────────────────────────────────────────────────────────────
WRITE=(fails); _run
_AP="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null)"
assert_contains "[B1] the model runs nothing else (#2506); its new and changed test files are run afterwards on the old code" "$_AP" \
    "Run nothing else: run only a test file of yours that you are told fails"
assert_contains "[B1] ...its new and changed test files are run afterwards on the old code" "$_AP" \
    "When you finish, the test files you create or change are run on the code from before this change"
assert_eq "[B1] it is no longer told to run its test files itself" "0" \
    "$(grep -c 'Run the test files you write' <<< "$_AP" || true)"
assert_contains "[B6] the prompt lists what is already written" "$_AP" "Already written (found by script"
assert_contains "[B6] ...each test file with the requirements whose tag it holds" "$_AP" "tests/b-test.sh: SPEC-2"
assert_eq "[B6] ...and not a file that holds none of them" "0" "$(grep -c 'tests/a-test.sh:' <<< "$_AP" || true)"
assert_contains "[B10] the list names the requirement with no test yet" "$_AP" "Not written yet: SPEC-1"
_nwy="$(grep -o 'Not written yet: [^.]*' "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null || true)"
assert_eq "[B10] ...and only it: SPEC-2's test is written" "Not written yet: SPEC-1" "$_nwy"
assert_contains "[B7] with every test written and nothing open, it confirms and finishes" "$_AP" \
    "confirm they test what their requirement demands and end with LOOP_COMPLETE"

# ── B3 ───────────────────────────────────────────────────────────────────────
assert_eq "[B3] a test that fails on the old code, as it must, is no finding" "pass" "$OUTCOME"
assert_eq "[B3] ...and the model is called once" "1" "$CALLS"

# ── B2 ───────────────────────────────────────────────────────────────────────
# #2460: the engine owns every retry — the finding ends the try `unusable`, and
# the engine's next try is told it under Previous work.
WRITE=(passes fails); _run
assert_eq "[B2] a [code] test that passes on the old code ends the try after one call" "1" "$CALLS"
assert_eq "[B2] ...unusable, for the engine to run test-author again" "unusable" "$OUTCOME"
assert_contains "[B2] ...the result names the requirement" "$FINDINGS" "SPEC-1"
assert_contains "[B2] ...the file, and that it passes on the code from before this change" "$FINDINGS" \
    "tests/a-test.sh passes on the code from before this change"

# ── B4 ───────────────────────────────────────────────────────────────────────
WRITE=(crash fails); _run
assert_contains "[B4] a file whose output holds no line tagged for its SPEC is a finding (in the result, #2460)" \
    "$FINDINGS" "SPEC-1: no line tagged $T1 appeared in tests/a-test.sh's output on the code from before this change"
assert_eq "[B4] ...that guesses no cause: no \"stopped before\"" "0" "$(grep -c 'stopped before' <<< "$FINDINGS" || true)"

# ── B5 ───────────────────────────────────────────────────────────────────────
# b-test.sh passes on the old code, but it is [no-code] and the call did not
# touch it; a-test.sh is unchanged by the call (seeded empty, "same").
WRITE=(same); _run
assert_eq "[B5] files the call left as they were are not run: no finding" "pass" "$OUTCOME"

# ── B9 ───────────────────────────────────────────────────────────────────────
# The call changes b-test.sh, a [no-code] requirement's test that passes on the
# old code, as it may; a-test.sh fails there, as it must.
route_to_model_loop() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/author-calls"
    _body fails "$T1" > "$R/tests/a-test.sh"
    { _body passes "$T2"; printf '# changed\n'; } > "$R/tests/b-test.sh"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"; _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"; return 0
}
_run
assert_eq "[B9] a changed [no-code] test passing on the old code is no finding" "pass" "$OUTCOME"

# ── B8 ───────────────────────────────────────────────────────────────────────
OUTSIDE="$TEST_TEMP_DIR/outside-test.sh"
printf '#!/usr/bin/env bash\ntouch "%s.ran"\n' "$OUTSIDE" > "$OUTSIDE"
_d8="$TEST_TEMP_DIR/b8"; mkdir -p "$_d8/repo"
( cd "$_d8/repo" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
    && : > seed && git add -A && git commit -q -m seed ) >/dev/null 2>&1
cp "$OUTSIDE" "$_d8/outside-test.sh"
printf '```acceptance\nSPEC-1[code]: x\n```\n' > "$_d8/design.md"
(
    acceptance_list_testfiles() { printf '../outside-test.sh\n'; }
    acceptance_list_testfiles_for_spec() { printf '../outside-test.sh\n'; }
    _ta_before_run "$_d8/design.md" "$_d8/repo" ""
) >/dev/null 2>&1
assert_file_not_exists "[B8] a test path outside the repository is never run" "$OUTSIDE.ran"
_wl="$( acceptance_list_testfiles() { printf '../outside-test.sh\ntests/a-test.sh\n'; }
        acceptance_list_spec_ids() { :; }
        _ta_written_list "$_d8/design.md" "$_d8/repo" )"
if grep -qF 'outside-test.sh' <<< "$_wl"; then
    assert_fail "[B8] ...nor listed in the prompt" "$_wl"
else
    assert_pass "[B8] ...nor listed in the prompt"
fi

# ── B11 ──────────────────────────────────────────────────────────────────────
print_test_section "B11: a [done] requirement gets a test that must pass at the end"
# SPEC-1 is [done]: the model writes tests/a-test.sh for it (WRITE), tagged T1.
# The author's model as at the top (a section above replaced it).
route_to_model_loop() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/author-calls"
    cp "$2" "$TEST_TEMP_DIR/author-prompt-$n"
    local w="${WRITE[$((n - 1))]:-${WRITE[${#WRITE[@]}-1]}}"
    [[ "$w" == same ]] || _body "$w" "$T1" > "$R/tests/a-test.sh"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
DESIGN_MD='# Design
```acceptance
SPEC-1[done]: an empty input returns rc 1 evidence: tests/b-test.sh
WIRING: none
```'
WRITE=(passes); _run
_AP="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null)"
assert_eq "[B11] a design whose every requirement is done still calls the model" "1" "$CALLS"
assert_contains "[B11] the [done] requirement is in the prompt" "$_AP" "SPEC-1 [done] an empty input returns rc 1"
assert_contains "[B11] ...with its tag" "$_AP" "tag: $T1"
assert_contains "[B11] ...and what its test must do: pass after the change, without having to fail before" "$_AP" \
    "its test must pass after this change; it need not fail before"
assert_eq "[B11] a [done] test that passes on the old code is no finding" "pass" "$OUTCOME"
WRITE=(fails); _run
assert_contains "[B11] a [done] test that fails on the old code is a finding" "$FINDINGS" \
    "SPEC-1: tests/a-test.sh fails on the code from before this change, which the design says already does this"
unset DESIGN_MD

# ── B12 / B13 / B14 / B15 ────────────────────────────────────────────────────
print_test_section "B12-B15: a tag names one SPEC, and the before-run says only what it saw"
WRITE=(mistag); _run
assert_contains "[B12] a file that runs to the end, its assertion tagged [SPEC-1/2]: the plain finding" "$FINDINGS" \
    "SPEC-1: no line tagged $T1 appeared in tests/a-test.sh's output on the code from before this change"
assert_eq "[B12] ...whatever its exit code: no \"stopped before\"" "0" "$(grep -c 'stopped before' <<< "$FINDINGS" || true)"
assert_eq "[B12] ...and no exit code read into it" "0" "$(grep -c '(exit ' <<< "$FINDINGS" || true)"
assert_contains "[B13] text shaped like a tag naming two SPECs is a finding: file, line, rule" "$FINDINGS" \
    "tests/a-test.sh line 3: [SPEC-1/2] is not a tag — a tag names one SPEC: [<id>]. An assertion that proves two SPECs is written twice, one line per SPEC, each with its own tag"
assert_eq "[B13] ...and the try is unusable, for the next try to fix" "unusable" "$OUTCOME"
WRITE=(twotags); _run
assert_contains "[B14] two tags on one line are a finding naming the line" "$FINDINGS" \
    "tests/a-test.sh line 2 holds two tags ($T1, [SPEC-2]) — one tag per line: write the assertion once for each SPEC"
WRITE=(fails); _run
assert_eq "[B14] a file with one good tag a line has no tag finding" "pass" "$OUTCOME"
_AP="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null)"
assert_contains "[B15] the prompt: each tag names one SPEC, one per line" "$_AP" \
    "Each tag names one SPEC, exactly as shown — e.g. $T1 — and a line holds one tag."
assert_contains "[B15] ...an assertion proving two SPECs is written twice" "$_AP" \
    "An assertion that proves two SPECs is written twice, one line per SPEC, each with its own tag."
assert_eq "[B15] ...and it no longer says a test may stop before its assertion runs" "0" \
    "$(grep -c 'stops before its assertion runs' <<< "$_AP" || true)"

# ── B16 / B17 / B18 / B19 / B20 ──────────────────────────────────────────────
_d16="$TEST_TEMP_DIR/b16"; R16="$_d16/repo"; mkdir -p "$R16/tests"
printf 'assert_eq "%s %s" x x\nassert_eq "[SPEC-1/2] old" x x\n' "$T1" "$T2" > "$R16/tests/old-test.sh"
( cd "$R16" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
    && git add -A && git commit -q -m seed && git checkout -q -b work ) >/dev/null 2>&1
printf 'assert_eq "[SPEC-2, SPEC-1] new" x x\n' > "$R16/tests/new-test.sh"
printf '```acceptance\nSPEC-1[code]: x\nSPEC-2[code]: y\n```\n' > "$_d16/design.md"
_shape() { _ta_tag_shape "$_d16/design.md" "$R16"; _tf="$(printf '%s\n' ${_TA_TAG_FINDINGS[@]+"${_TA_TAG_FINDINGS[@]}"})"; }
_shape
assert_contains "[B16] a new test file, not in git yet, is checked whole" "$_tf" \
    "tests/new-test.sh line 1: [SPEC-2, SPEC-1] is not a tag"
assert_eq "[B17] lines the default branch already has give no finding" "0" "$(grep -c 'old-test.sh' <<< "$_tf" || true)"

rm -f "$R16/tests/new-test.sh"
cat > "$R16/tests/ok-test.sh" <<'SH'
n=$(grep -c '\[SPEC-1\]' <<< "$out")
if [[ "$id" == SPEC-1 ]]; then :; fi
assert_contains "[SPEC-2] msg" "$out" "[SPEC-1] appeared"
assert_eq "[#9/SPEC-1] another issue's tag" x x
printf '{"covers":["SPEC-1","SPEC-2"]}' > "$f"
v="${_brf[SPEC-1]}"; assert_eq "[SPEC-2] arr" "$v" x
assert_contains "[SPEC-1] output names its tag" "$out" "[SPEC-1]"
SH
_shape
assert_eq "[B18] test code that only mentions a tag gives no finding" "" "$_tf"

rm -f "$R16/tests/ok-test.sh"
printf 'assert_eq "[SPEC-1/2] committed" x x\n' > "$R16/tests/c-test.sh"
( cd "$R16" && git add -A && git commit -q -m try1 \
    && git config diff.mnemonicPrefix true && git config diff.external false ) >/dev/null 2>&1
_shape
assert_contains "[B19] a committed branch line is checked, whatever the diff settings" "$_tf" \
    "tests/c-test.sh line 1: [SPEC-1/2] is not a tag"
( cd "$R16" && git config --unset diff.mnemonicPrefix; git config --unset diff.external ) >/dev/null 2>&1

# C3 (review on #2554): only the lines the branch added, at their own numbers.
rm -f "$R16/tests/c-test.sh"; ( cd "$R16" && git add -A && git commit -q -m clean ) >/dev/null 2>&1
printf 'assert_eq "x" x x\nassert_eq "y" x x\nassert_eq "[SPEC-2/1] added" x x\n' >> "$R16/tests/old-test.sh"
_shape
assert_eq "[B17] a changed default-branch file: one finding, on the line the branch added" \
    "tests/old-test.sh line 5: [SPEC-2/1] is not a tag" "${_tf%% — *}"
( cd "$R16" && git checkout -q -- tests/old-test.sh ) >/dev/null 2>&1

for _i in $(seq 1 15); do printf 'assert_eq "[SPEC-1/%s] x" x x\n' "$_i"; done > "$R16/tests/many-test.sh"
_shape
assert_eq "[B20] at most 10 tag findings…" "11" "${#_TA_TAG_FINDINGS[@]}"
assert_contains "[B20] …then one saying how many more" "$_tf" "and 5 more lines like these"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
