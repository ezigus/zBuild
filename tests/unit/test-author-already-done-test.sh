#!/usr/bin/env bash
# tests/unit/test-author-already-done-test.sh — test-author reports a [code]
# requirement the code from before the change already meets, instead of looking
# for a test that cannot fail there; the report, its quote checked in that
# code, ends the round with a finding for the requirement (ADR-069, amended
# 2026-11-14, #2543; ADR-068 §3).
#
# Why: on #1700 run 43617030653 DSPRB-2 was marked [code], but the old code
# already met it (its stat fallback returns a valid mode). test-author spent two
# whole calls — 79k characters of thinking — looking for a test that fails on
# the old code, wrote nothing, and two rounds were lost.
#
# D1 [change] the prompt says how to report such a requirement, in the
#             form the stage reads, and that the quote is checked there; it names
#             no other stage
# D2 [change] a report whose quote is in the code from before the change: the
#             stage fails, ends the round, and its finding says the old code
#             already does it, naming the evidence; the tests written for the
#             other requirements are committed; its own check is not run
# D3 [change] a report whose quote is not in that code is a finding back to
#             test-author: the try ends unusable, and the round goes on
# D4 [guard]  a report for a requirement not marked [code] changes nothing
# D5 [change] a reported requirement counts as handled for ending the call
# D6 [guard]  the finding keeps test-author's own topic (not one build takes)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "test-author reports a requirement the old code already meets (#2543)"
setup_test_env "test-author-already-done"

# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
T2="$(acceptance_spec_tag SPEC-2)"

# The author's model: writes SPEC-2's test (it fails on the old code, as a
# [code] test must) and replies ${REPLY_LINES}.
route_to_model_loop() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/author-calls"
    cp "$2" "$TEST_TEMP_DIR/author-prompt-$n"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'assert_eq() { if [[ "$2" == "$3" ]]; then printf "  ✓ %%s\\n" "$1"; else printf "  ✗ %%s\\n" "$1"; return 1; fi; }\n'
        printf 'calls=2\n'
        printf 'assert_eq "%s exactly one stat runs" "1" "$calls" || exit 1\n' "$T2"
    } > "$R/tests/b-test.sh"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_LAST_RESPONSE="${REPLY_LINES:-}"$'\n'"LOOP_COMPLETE"
    return 0
}
# test-author's own check: counts its calls, and agrees.
route_to_model() {
    printf 'x' >> "$TEST_TEMP_DIR/judge-calls"
    zb_test_check_ok "$2"
}

_run() {
    rm -rf "$TEST_TEMP_DIR/run" "$TEST_TEMP_DIR"/author-* "$TEST_TEMP_DIR"/judge-*
    local d="$TEST_TEMP_DIR/run"; R="$d/repo"; A="$d/state/artifacts"
    mkdir -p "$A" "$R/tests" "$R/scripts"
    # The code from before the change: the fallback that already meets SPEC-1.
    printf '#!/usr/bin/env bash\nmode_of() { stat -f %%Lp "$1" 2>/dev/null || stat -c %%a "$1"; }\n' > "$R/scripts/x.sh"
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && : > tests/b-test.sh && git add -A && git commit -q -m seed \
        && git checkout -q -b work \
        && printf 'added_by_this_branch=1\n' >> scripts/x.sh && git commit -qam change ) >/dev/null 2>&1
    printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
    cat > "$A/design.md" <<'MD'
# Design
```acceptance
SPEC-1[code]: the mode check returns a valid mode when the platform setting is wrong
  When: the mode check runs with the platform setting wrong for the host
  Then: it returns a valid octal mode
SPEC-2[code]: the mode check runs stat once
  When: the mode check runs on an existing file
  Then: exactly one stat runs
SPEC-3[no-code]: the docs list the probe
WIRING: none
```
MD
    export ZBUILD_REPO_ROOT="$R" ZBUILD_STATE_DIR="$d/state" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
    test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1
    RC=$?
    RES="$A/test-author-result.json"
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$RES" 2>/dev/null || echo MISSING)"
    ENDS="$(jq -r '.data.ends_round // false' "$RES" 2>/dev/null || echo false)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$RES" 2>/dev/null || true)"
    TOPICS="$(jq -r '[.data.findings[]?.topic // empty] | join(",")' "$RES" 2>/dev/null || true)"
    JUDGED="$(cat "$TEST_TEMP_DIR/judge-calls" 2>/dev/null || true)"
    COMMITTED="$(git -C "$R" log --format=%s -1 -- tests/b-test.sh 2>/dev/null || true)"
    judge_base_release "$d/state" "$R" test >/dev/null 2>&1 || true
}

REPORT_OK='SPEC-1: already_done | WHY: when the first stat form fails it runs the other, which returns a valid mode | QUOTE: scripts/x.sh | mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }'
REPORT_NEW='SPEC-1: already_done | WHY: it is set | QUOTE: scripts/x.sh | added_by_this_branch=1'

print_test_section "D1/D5: the prompt says how to report it"
REPLY_LINES="" _run
_AP="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-1" 2>/dev/null)"
assert_contains "[D1] the prompt gives the report's form" "$_AP" "<SPEC id>: already_done | WHY: <how the code from before this change already does it> | QUOTE: <file> | <one line of that file, copied as it is>"
assert_contains "[D1] ...says not to write a test for it" "$_AP" "do not write a test for it"
assert_contains "[D1] ...and that the quote is checked in the code from before this change" "$_AP" "The QUOTE is checked in the code from before this change"
if grep -qiE '\bdesign\b' <<< "$(sed -n '/requirement may be one the code from before/,/The QUOTE is checked/p' "$TEST_TEMP_DIR/author-prompt-1")"; then
    assert_fail "[D1] the rule names no other stage" "it says design"
else assert_pass "[D1] the rule names no other stage"; fi
assert_contains "[D5] a reported requirement counts as handled for ending the call" "$_AP" "has its assertion written to disk or is reported already_done"

print_test_section "D2: a report whose quote is in the old code ends the round"
REPLY_LINES="$REPORT_OK" _run
assert_eq "[D2] the stage fails" "fail" "$OUTCOME"
assert_eq "[D2] ...rc 1" "1" "$RC"
assert_eq "[D2] ...and ends the round" "true" "$ENDS"
assert_contains "[D2] the finding names the requirement" "$FINDINGS" "SPEC-1"
assert_contains "[D2] ...says the old code already does it" "$FINDINGS" "the code from before this change already does this"
assert_contains "[D2] ...and names the evidence" "$FINDINGS" "scripts/x.sh | mode_of()"
assert_contains "[D2] the other requirement's test is committed" "$COMMITTED" "test-author"
assert_eq "[D2] its own check is not run" "" "${JUDGED:-}"

print_test_section "D3: a quote not in the old code is a finding back to test-author"
REPLY_LINES="$REPORT_NEW" _run
assert_eq "[D3] the try ends unusable" "unusable" "$OUTCOME"
assert_eq "[D3] ...and does not end the round" "false" "$ENDS"
assert_contains "[D3] the finding says the quote is not in the code from before this change" "$FINDINGS" "SPEC-1's already_done quote"

print_test_section "D4: a report for a requirement not marked [code]"
REPLY_LINES='SPEC-3: already_done | WHY: the docs list it | QUOTE: scripts/x.sh | mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }' _run
assert_eq "[D4] it does not end the round" "false" "$ENDS"

print_test_section "D6: the finding's topic"
REPLY_LINES="$REPORT_OK" _run
assert_eq "[D6] the finding names no topic of its own: it goes by test-author's" "" "$TOPICS"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
