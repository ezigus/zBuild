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
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"; _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# The checks: the SPEC check agrees; the check of untagged lines answers
# $VERDICT for each line it is shown, and keeps what it was asked.
VERDICT="unasked | WHY: it pins the shape-change list, which no SPEC mentions"
route_to_model() {
    if [[ "$2" == *"carry no requirement's tag"* ]]; then
        printf '%s' "$2" > "$TEST_TEMP_DIR/unasked-prompt"
        local l
        while IFS= read -r l; do
            [[ "$l" =~ ^-\ (tests/[^ ]+\ line\ [0-9]+): ]] && printf '%s: %s\n' "${BASH_REMATCH[1]}" "$VERDICT"
        done <<< "$2"
        return 0
    fi
    zb_test_check_ok "$2"
}

_run() {
    rm -rf "$TEST_TEMP_DIR/run" "$TEST_TEMP_DIR"/author-* "$TEST_TEMP_DIR/unasked-prompt"
    local d="$TEST_TEMP_DIR/run"; R="$d/repo"; A="$d/state/artifacts"
    mkdir -p "$A" "$R/tests" "$R/config"
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && printf 'scripts/lib/a.sh\n' > config/shape-change-paths.txt \
        && git add -A && git commit -q -m seed && git checkout -q -b work ) >/dev/null 2>&1
    printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
    cat > "$A/design.md" <<'MD'
# Design
```acceptance
SPEC-1[code]: an empty input returns rc 1
WIRING: none
```
MD
    export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
    test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$A/test-author-result.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$A/test-author-result.json" 2>/dev/null || true)"
}

print_test_section "A2: test-author's prompt"
EXTRA=""; _run
_ap="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null)"
assert_contains "[A2] every test and assertion traces to a SPEC" "$_ap" \
    "Every test and assertion you write traces to a SPEC below, and carries its tag."
assert_contains "[A2] ...a test for a change no SPEC asks for is not yours: not mine" "$_ap" \
    "What you own is the tests the SPECs ask for: a finding that asks for a test of a change no SPEC asks for, answer not mine"

print_test_section "A3: the check refuses an untagged assertion nothing asks for"
EXTRA='assert_contains "lists the design plugin" "$(cat config/shape-change-paths.txt)" "plugins/agent/design/plugin.sh"'
_run
assert_eq "[A3] the try is unusable, for the next try to fix" "unusable" "$OUTCOME"
assert_contains "[A3] the finding names the file and line, and that no SPEC asks for it" "$FINDINGS" \
    "tests/a-test.sh line 3 tests something no SPEC asks for"
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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
