#!/usr/bin/env bash
# tests/unit/lens-reply-lines-test.sh — a lens answers in plain lines, like every
# other judge; nothing in its answer is escaped (#2598 R1, ADR-038, ADR-072 §3).
#
# #2532 run 45231040380: a lens's JSON quote of `printf '… macos ;;\n' > …` had
# to be written `\\n`; the lens wrote `\n`, JSON read it as a line break, the
# quote was not in the file twice, and the run stopped.
#
# L1 [change] a quote holding `\n` is read as written and found in its file
# L2 [change] every field of a finding is read, for each finding
# L3 [change] a suspicion, a question (UNCLEAR … |) and an answer (UNCLEAR …:)
#             are read into their lists
# L4 [change] formatting a model adds (a list mark, bold keys) is set aside
# L5 [change] an answer in another form is told the form it must take
# L6 [change] the prompt asks for the lines, not a JSON object
# L7 [change] `SCORE: 10` alone is a usable answer with no finding
# L8 [change] `Finding 1`, `## FINDING` and `**Finding 2**` open a finding (review on #2598)
# L9 [change] a field line outside any finding is no answer: it is asked again
# L10 [change] a wrapped line that looks like a key (`Note: …`) carries on its field
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a lens answers in plain lines (#2598)"
setup_test_env "lens-reply-lines"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" 2>/dev/null

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests"
cat > "$R/tests/guard.sh" <<'EOF'
printf '    Darwin)  ZBUILD_PLATFORM=macos ;;\n' > "$_zbp_inject"
echo "second line"
EOF

print_test_section "L1-L2: findings"
REP=$(cat <<'EOF'
SCORE: 6
FINDING
severity: medium
category: coverage
fix: test
introduced: yes
quote: tests/guard.sh | printf '    Darwin)  ZBUILD_PLATFORM=macos ;;\n' > "$_zbp_inject"
message: the guard misses a two-line form
trigger: a later change writes the value on one line and compares it on another
accepted if: a guard catches the two-line form
also at: tests/guard.sh | echo "second line"
FINDING
severity: low
category: wording
fix: code
introduced: no
quote: tests/guard.sh | echo "second line"
message: a second one
trigger: any run
accepted if: it reads well
EOF
)
J=""; P=""; _rl_reply_problem "$REP" J P
assert_eq "[L2] the answer is usable" "" "$P"
assert_eq "[L2] two findings" "2" "$(jq '.findings | length' <<< "$J")"
assert_eq "[L2] the score" "6" "$(jq '.score' <<< "$J")"
assert_eq "[L2] fields of finding 1" 'medium|coverage|test|true|tests/guard.sh|the guard misses a two-line form|a guard catches the two-line form' \
    "$(jq -r '.findings[0] | [.severity, .category, .fix, (.introduced|tostring), .file, .message, .accepted_if] | join("|")' <<< "$J")"
assert_eq "[L2] its other place" 'tests/guard.sh | echo "second line"' "$(jq -r '.findings[0].also_at[0]' <<< "$J")"
assert_eq "[L2] finding 2 was not introduced" "false" "$(jq -r '.findings[1].introduced' <<< "$J")"
assert_eq "[L1] the quote is kept as written, its \\n two characters" \
    "printf '    Darwin)  ZBUILD_PLATFORM=macos ;;\\n' > \"\$_zbp_inject\"" "$(jq -r '.findings[0].quote' <<< "$J")"
Q="unset"; [[ -n "$J" ]] && { Q=""; _rl_quote_problem_v Q "$J" "" "$R" ""; }
assert_eq "[L1] ...and found in its file" "" "$Q"

print_test_section "L3: suspicions and questions"
REP3=$(cat <<'EOF'
SCORE: 9
SUSPICION
quote: tests/guard.sh | echo "second line"
suspicion: it may print twice
confirm by: run it twice
fix: code
UNCLEAR DSPLAT-1 | "the host" | the machine or the target | ASSUMED: the target
UNCLEAR DSPLAT-2: open
EOF
)
J=""; P=""; _rl_reply_problem "$REP3" J P
assert_eq "[L3] no finding" "0" "$(jq '.findings | length' <<< "$J")"
assert_eq "[L3] the suspicion" 'tests/guard.sh|echo "second line"|it may print twice|run it twice|code' \
    "$(jq -r '[.unclear[] | objects][0] | [.file, .quote, .suspicion, .confirm_by, .fix] | join("|")' <<< "$J")"
assert_eq "[L3] the question" 'UNCLEAR DSPLAT-1 | "the host" | the machine or the target | ASSUMED: the target' "$(jq -r '[.unclear[] | strings][0]' <<< "$J")"
assert_eq "[L3] the answer" "UNCLEAR DSPLAT-2: open" "$(jq -r '.unclear_answers[0]' <<< "$J")"

print_test_section "L4: formatting set aside"
REP4=$'**SCORE:** 7\n- **FINDING**\n- **severity:** high\n- **fix:** code\n- **introduced:** yes\n- **quote:** tests/guard.sh | echo "second line"\n- **message:** m\n- **trigger:** t\n- **accepted if:** a'
J=""; P=""; _rl_reply_problem "$REP4" J P
assert_eq "[L4] read through the marks" "7|high|tests/guard.sh|echo \"second line\"" "$(jq -r '"\(.score)|\(.findings[0].severity)|\(.findings[0].file)|\(.findings[0].quote)"' <<< "$J")"

print_test_section "L5-L7"
J=""; P=""; _rl_reply_problem '{"score": 10, "findings": []}' J P
assert_contains "[L5] a JSON answer is told the form" "$P" "SCORE:"
J=""; P=""; _rl_reply_problem "SCORE: 10" J P
assert_eq "[L7] SCORE: 10 alone is usable" "" "$P"
assert_eq "[L7] ...with no finding" "0" "$(jq '.findings | length' <<< "$J")"
_pr="$(_rl_build_lens_prompt security "THE CHANGE" "" 2>/dev/null || true)"
assert_contains "[L6] the prompt asks for a SCORE line" "$_pr" "SCORE: <"
if [[ "$_pr" == *"EXACTLY ONE JSON object"* ]]; then assert_fail "[L6] ...and no JSON object" "still asks for JSON"; else assert_pass "[L6] ...and no JSON object"; fi

print_test_section "L8-L10: headings, stray fields, wrapped lines"
J=""; P=""; _rl_reply_problem $'SCORE: 3\nFinding 1\nseverity: high\nquote: tests/guard.sh | echo "second line"\nmessage: a\n## FINDING 2\nseverity: low\nmessage: b\n**Finding 3**\nmessage: c' J P
assert_eq "[L8] three findings under three heading forms" "a,b,c" "$(jq -r '[.findings[].message] | join(",")' <<< "$J" 2>/dev/null)"
J=""; P=""; _rl_reply_problem $'SCORE: 3\nseverity: high\nquote: tests/guard.sh | echo "second line"\nmessage: no block' J P
assert_contains "[L9] a field outside any finding is asked again" "$P" "not in the asked form"
J=""; P=""; _rl_reply_problem $'SCORE: 4\nFINDING\nmessage: the guard misses\nNote: it also misses a third form\ntrigger: t' J P
assert_eq "[L10] the wrapped line stays in its field" "the guard misses Note: it also misses a third form" "$(jq -r '.findings[0].message' <<< "$J" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
