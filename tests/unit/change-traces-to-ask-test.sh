#!/usr/bin/env bash
# tests/unit/change-traces-to-ask-test.sh — everything a stage adds traces to
# something that asks for it (#2575, ADR-068 §8, ADR-069).
#
# Why: #1764 run 44782866204 — a config/shape-change-paths.txt line came from a
# design step that had since been removed, and nothing undid it. The check said
# to add a test, and test-author added one that pins a change nothing asks for.
#
# A1 [code] build's prompt: every change traces to a design step or a failing
#           test; what a step that was removed built is undone
# A2 [code] test-author's prompt: every test and assertion traces to a SPEC; a
#           test for a change no SPEC asks for is not test-author's — it answers
#           not mine
# A3 [code] test-author's own check refuses an assertion its branch added that
#           names no SPEC and tests a change no SPEC asks for: the try is
#           unusable, the finding names the file, the line and why
# A4 [guard] an untagged assertion the check finds a SPEC asks for is no finding
# A5 [guard] an assertion tagged with a SPEC is not sent to that check at all
# Review on #2575:
# A6 [code]  every untagged line is judged — 35 across two files, in more than
#            one call when needed — none left out
# A7 [code]  a second try with the same lines makes no call: each line's answer
#            is kept beside test-author's result, by file and line content
# A8 [code]  a line the check leaves unanswered ends the try unusable, the
#            reason naming this check
# A9 [code]  the check is shown the design's steps: a test changed for what a
#            step changes ("asked | STEP: <n>") is no finding
# A10 [code] the check is told that a helper's line a tagged assertion calls
#            traces to that assertion's SPEC
# A11 [code] an assertion the default branch already has, that only lost its
#            stale tag, is not judged
# A12 [code] an `expect=` variable, or `$assert_ok`, is not a check line
# A13 [code] a test file whose name holds `=` is read like any other
# Second review on #2575:
# A14 [code] only asked answers are kept: an unasked line is judged again on
#            the next try
# A15 [code] an asked answer naming a SPEC not in the contract, or a step past
#            the last, is no answer
# A16 [code] a try with nothing new to judge does not rewrite the kept answers
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "everything a stage adds traces to an ask (#2575)"
setup_test_env "change-traces-to-ask"

print_test_section "A1: build's prompt"
# shellcheck source=../../plugins/agent/build/lib/prompt.sh
source "$REPO_ROOT/plugins/agent/build/lib/prompt.sh"
_bp="$(_build_compose_instructions | tr -s '[:space:]' ' ')"
assert_contains "[A1] every change traces to a design step or a failing test" "$_bp" \
    "Every change you make traces to a design step or to a failing test"
assert_contains "[A1] ...what a removed step built is undone" "$_bp" \
    "When a step is gone from the design, undo what you built for it"
assert_contains "[A1] ...unless the current design's steps now name it" "$_bp" \
    "undo what you built for it, unless the current design's steps now name it"

# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
T1="$(acceptance_spec_tag SPEC-1)"

# The author's model writes tests/a-test.sh: SPEC-1's tagged assertion, then
# the line in $EXTRA (none when empty).
EXTRA=""
route_to_model_loop() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/author-calls"
    cp "$2" "$TEST_TEMP_DIR/author-prompt-$n"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "  ✗ %%s it holds\\n" "%s"\n' "$T1"
        [[ -n "$EXTRA" ]] && printf '%s\n' "$EXTRA"
        printf 'exit 1\n'
    } > "$R/tests/a-test.sh"
    [[ -n "${AUTHOR_HOOK:-}" ]] && "$AUTHOR_HOOK"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"; _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# The checks: the SPEC check agrees; the check of untagged lines answers
# $VERDICT for each line it is shown, and keeps what it was asked.
VERDICT="unasked | WHY: it pins the shape-change list, which no SPEC mentions"
route_to_model() {
    if [[ "$2" == *"carry no requirement's tag"* ]]; then
        printf '%s' "$2" > "$TEST_TEMP_DIR/unasked-prompt"
        printf '%s\n' "$2" >> "$TEST_TEMP_DIR/unasked-prompts"
        printf 'x' >> "$TEST_TEMP_DIR/unasked-calls"
        local l
        while IFS= read -r l; do
            [[ "$l" =~ ^-\ (tests/[^ ]+\ line\ [0-9]+): ]] || continue
            printf '%s\n' "${BASH_REMATCH[1]}" >> "$TEST_TEMP_DIR/unasked-keys"
            [[ -n "$VERDICT" ]] && printf -- '- %s: %s\n' "${BASH_REMATCH[1]}" "$VERDICT"
        done <<< "$2"
        return 0
    fi
    zb_test_check_ok "$2"
}

STEPS_BLOCK=""
SEED_HOOK=""
_run() {
    rm -rf "$TEST_TEMP_DIR/run" "$TEST_TEMP_DIR"/author-* "$TEST_TEMP_DIR"/unasked-*
    local d="$TEST_TEMP_DIR/run"; R="$d/repo"; A="$d/state/artifacts"
    mkdir -p "$A" "$R/tests" "$R/config"
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && printf 'scripts/lib/a.sh\n' > config/shape-change-paths.txt \
        && { [[ -z "$SEED_HOOK" ]] || "$SEED_HOOK"; } \
        && git add -A && git commit -q -m seed && git checkout -q -b work ) >/dev/null 2>&1
    printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
    { printf '# Design\n%s' "$STEPS_BLOCK"; cat <<'MD'
```acceptance
SPEC-1[code]: an empty input returns rc 1
WIRING: none
```
MD
    } > "$A/design.md"
    _again
}
# _again — test-author's next try, over the same run.
_again() {
    local d="$TEST_TEMP_DIR/run"
    rm -f "$TEST_TEMP_DIR"/unasked-*
    export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
    test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$A/test-author-result.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$A/test-author-result.json" 2>/dev/null || true)"
}

print_test_section "A2: test-author's prompt"
EXTRA=""; _run
_ap="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null)"
assert_contains "[A2] every test and assertion traces to a SPEC" "$_ap" \
    "Every test and assertion you write traces to a SPEC below, and carries its tag; a change to an existing test for what a design step changes traces to that step."
assert_contains "[A2] ...a test for a change no SPEC asks for is not yours: not mine" "$_ap" \
    "What you own is the tests the SPECs ask for: a finding that asks for a test of a change no SPEC asks for, answer not mine"

print_test_section "A3: the check refuses an untagged assertion nothing asks for"
EXTRA='assert_contains "lists the design plugin" "$(cat config/shape-change-paths.txt)" "plugins/agent/design/plugin.sh"'
_run
assert_eq "[A3] the try is unusable, for the next try to fix" "unusable" "$OUTCOME"
assert_contains "[A3] the finding names the file and line, and that no SPEC asks for it" "$FINDINGS" \
    "tests/a-test.sh line 3 tests something no SPEC or design step asks for"
assert_contains "[A3] ...with the check's reason" "$FINDINGS" "it pins the shape-change list, which no SPEC mentions"
assert_contains "[A3] ...and says to take it out" "$FINDINGS" "take it out"

print_test_section "A4: an untagged assertion a SPEC asks for"
VERDICT="asked | SPEC: SPEC-1"; _run
assert_eq "[A4] it is no finding" "pass" "$OUTCOME"

print_test_section "A5: a tagged assertion is not sent"
VERDICT="unasked | WHY: x"; EXTRA=""; _run
assert_eq "[A5] with only tagged assertions, the try passes" "pass" "$OUTCOME"
if [[ -s "$TEST_TEMP_DIR/unasked-prompt" ]] && grep -qF "tests/a-test.sh line 2" "$TEST_TEMP_DIR/unasked-prompt"; then
    assert_fail "[A5] ...and the tagged line was not sent to the check" "it was"
else
    assert_pass "[A5] ...and the tagged line was not sent to the check"
fi

print_test_section "A6/A7: every line judged, each once"
_many() {
    local i
    for i in $(seq 1 20); do printf 'assert_eq "case %s" x x\n' "$i"; done >> "$R/tests/a-test.sh"
    for i in $(seq 1 15); do printf 'assert_eq "other %s" x x\n' "$i"; done > "$R/tests/b-test.sh"
}
VERDICT="asked | SPEC: SPEC-1"; EXTRA=""; AUTHOR_HOOK=_many; _run
assert_eq "[A6] all 35 untagged lines are judged" "35" "$(sort -u "$TEST_TEMP_DIR/unasked-keys" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[A6] ...from both files" "15" "$(sort -u "$TEST_TEMP_DIR/unasked-keys" 2>/dev/null | grep -c "^tests/b-test.sh line" || true)"
assert_eq "[A6] ...and the try passes" "pass" "$OUTCOME"
_again
assert_eq "[A7] the next try with the same lines makes no call" "0" "$(wc -c < "$TEST_TEMP_DIR/unasked-calls" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "[A7] ...and still passes" "pass" "$OUTCOME"
AUTHOR_HOOK=""

print_test_section "A8: a line left unanswered"
VERDICT=""; EXTRA='assert_eq "unanswered" x x'; _run
assert_eq "[A8] the try is unusable" "unusable" "$OUTCOME"
assert_contains "[A8] ...the reason names this check" \
    "$(jq -r '.reason // empty' "$A/test-author-result.json" 2>/dev/null)" "the check that each untagged assertion traces to a SPEC or a design step"

print_test_section "A9/A10: the steps, and helpers"
STEPS_BLOCK=$'```steps\n- rename the claim reader | areas: scripts/lib/claim.sh\n```\n'
VERDICT="asked | STEP: 1"; EXTRA='assert_eq "reads the renamed claim reader" x x'; _run
assert_contains "[A9] the check is shown the design's steps" "$(cat "$TEST_TEMP_DIR/unasked-prompt" 2>/dev/null)" \
    "1. rename the claim reader | areas: scripts/lib/claim.sh"
assert_eq "[A9] a line changed for what a step changes is no finding" "pass" "$OUTCOME"
assert_contains "[A10] a helper's line a tagged assertion calls traces to its SPEC" \
    "$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/unasked-prompt" 2>/dev/null)" \
    "A line in a helper that a tagged assertion calls traces to that assertion's SPEC."
STEPS_BLOCK=""

print_test_section "A11: an old assertion that only lost its stale tag"
_seed11() { printf 'assert_eq "[SPEC-9] old check" x x\n' > tests/old-test.sh; }
_strip11() { printf 'assert_eq "old check" x x\n' > "$R/tests/old-test.sh"; }
SEED_HOOK=_seed11; AUTHOR_HOOK=_strip11; VERDICT="unasked | WHY: x"; EXTRA=""; _run
assert_eq "[A11] it is not judged" "0" "$(grep -c 'old-test.sh' <<< "$(cat "$TEST_TEMP_DIR/unasked-keys" 2>/dev/null)" || true)"
SEED_HOOK=""; AUTHOR_HOOK=""

print_test_section "A12/A13: what is a check line, and odd file names"
_odd() { printf 'assert_eq "odd" x x\n' > "$R/tests/a=b-test.sh"; }
AUTHOR_HOOK=_odd; VERDICT="asked | SPEC: SPEC-1"
EXTRA=$'expect="x"\nif $assert_ok; then :; fi'; _run
assert_eq "[A12] an expect= variable or \$assert_ok is not sent" "0" "$(grep -c 'a-test.sh' <<< "$(cat "$TEST_TEMP_DIR/unasked-keys" 2>/dev/null)" || true)"
assert_contains "[A13] a file named with = is read" "$(cat "$TEST_TEMP_DIR/unasked-keys" 2>/dev/null)" "tests/a=b-test.sh line 1"
AUTHOR_HOOK=""

print_test_section "A14/A16: what is kept"
VERDICT="unasked | WHY: x"; EXTRA='assert_eq "pins it" x x'; AUTHOR_HOOK=""; STEPS_BLOCK=""; _run
_again
assert_eq "[A14] an unasked line is judged again on the next try" "1" "$(wc -c < "$TEST_TEMP_DIR/unasked-calls" 2>/dev/null | tr -d ' ' || echo 0)"
VERDICT="asked | SPEC: SPEC-1"; _run
: > "$TEST_TEMP_DIR/mark"
_kt="$TEST_TEMP_DIR/run/state/artifacts/test-author-unasked.tsv"
touch -t 200001010000 "$_kt" 2>/dev/null
_again
assert_eq "[A16] the kept answers are not rewritten when nothing changed" "no" \
    "$([[ "$_kt" -nt "$TEST_TEMP_DIR/mark" ]] && echo yes || echo no)"

print_test_section "A15: an asked answer is checked"
VERDICT="asked | SPEC: SPEC-99"; _run
assert_eq "[A15] a SPEC not in the contract is no answer: unusable" "unusable" "$OUTCOME"
STEPS_BLOCK=$'```steps\n- one step | areas: scripts/lib/claim.sh\n```\n'
VERDICT="asked | STEP: 5"; _run
assert_eq "[A15] a step past the last is no answer: unusable" "unusable" "$OUTCOME"
STEPS_BLOCK=""

cleanup_test_env
print_test_results
exit $((FAIL > 0))
