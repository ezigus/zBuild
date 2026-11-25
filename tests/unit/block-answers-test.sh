#!/usr/bin/env bash
# tests/unit/block-answers-test.sh — every stage answers in one block form, each
# quote on its own line (#2609, ADR-072 §3).
#
# 29 quote fixes in November each taught the checker one more way a model
# mis-copies a line. On #2533 run 45403848593 build wrote its own words into
# its quote (`step 4: done — <file> | \`<line>\` with §3a–§3e …`) and lost a
# 17-minute try: its one-line answer had no place for them.
#
# B1 [change] the shared reader turns a block — an answer's head, then one field
#             a line — into the one line each stage reads: WHY, ACCEPTED IF and
#             QUOTE in that order whatever order they came in, a wrapped field
#             carried on, a note set aside, marks around a label set aside
# B2 [guard]  the old one-line form is read as it was (an answer saved by an
#             earlier run)
# B3 [change] build's `step N: done` block, its words in a note: the quote is
#             only the line
# B5 [change] a blank line ends a block; a second block is its own answer
# B8 [guard]  (review) a reply that is not a block — an ANSWER with a note, a
#             list item, a summary — is joined as it was; a block is one with a
#             why:, accepted if: or quote: line
# B6 [guard]  the table: each way a model has mis-copied a quote, written on a
#             quote: line, reaches the shared quote check whole and is found —
#             marks, quote marks, escapes, `…`, part of a line, a file in marks
# B7 [guard]  every prompt that asks for a quote asks for the block form, and
#             none still shows a one-line `| QUOTE:` form
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/reply-units.sh
source "$REPO_ROOT/scripts/lib/reply-units.sh"
print_test_header "every stage answers in one block form (#2609)"
setup_test_env "block-answers"
_j() { local o; zb_reply_join_v o "$1"; printf '%s' "$o"; }

print_test_section "B1: a block is read as one answer"
assert_eq "[B1] head, then why / accepted if / quote, in their order" \
    "UNMET: [fix-code] RQHBT-1 | WHY: no heartbeat | ACCEPTED IF: the line is written | QUOTE: scripts/x.sh | x() {" \
    "$(_j $'UNMET: [fix-code] RQHBT-1\nwhy: no heartbeat\naccepted if: the line is written\nquote: scripts/x.sh | x() {')"
assert_eq "[B1] ...whatever order the fields came in" \
    "UNMET: RQHBT-1 | WHY: w | ACCEPTED IF: a | QUOTE: f.sh | l" \
    "$(_j $'UNMET: RQHBT-1\nquote: f.sh | l\naccepted if: a\nwhy: w')"
assert_eq "[B1] ...a wrapped field carries on" \
    "UNMET: RQHBT-1 | WHY: one two | QUOTE: f.sh | l" \
    "$(_j $'UNMET: RQHBT-1\nwhy: one\n  two\nquote: f.sh | l')"
assert_eq "[B1] ...marks around a label are set aside" \
    "RQCL-1: uncovered | WHY: w | QUOTE: the issue's words" \
    "$(_j $'RQCL-1: uncovered\n- **why:** w\n`quote:` the issue\'s words')"

assert_eq "[B1] ...design's status fields keep their order, before WHY" \
    "DSHBT-3 Title: status | DOC: no | BEFORE: yes | WORK: no | WHY: w | ACCEPTED IF: a | QUOTE: f.sh | l" \
    "$(_j $'DSHBT-3 Title: status\ndoc: no\nbefore: yes\nwork: no\nwhy: w\naccepted if: a\nquote: f.sh | l')"

assert_eq "[B1] ...a quote is one line: prose after it is not the quote" \
    $'step 2: done | QUOTE: a.sh | foo\n\nThen I ran the tests and they pass.' \
    "$(_j $'step 2: done\nquote: a.sh | foo\nThen I ran the tests and they pass.')"
assert_eq "[B1] ...a head that wraps keeps its fields" \
    "UNMET: [fix-code] R3 the change does not handle the empty case | WHY: no check | QUOTE: src/a.sh | x" \
    "$(_j $'UNMET: [fix-code] R3 the change does not handle\nthe empty case\nwhy: no check\nquote: src/a.sh | x')"

print_test_section "B8: a reply that is not a block is left as it was"
assert_eq "[B8] an ANSWER's note stays its words" \
    "ANSWER LENS-3: wrong — the finding misreads it Note: the function already checks the path first" \
    "$(_j $'ANSWER LENS-3: wrong — the finding misreads it\nNote: the function already checks the path first')"
assert_eq "[B8] ...a list item's note too" "- the change adds a guard note: something important" \
    "$(_j $'- the change adds a guard\nnote: something important')"
assert_eq "[B8] ...and a summary's Work: line" "COMMIT_SUMMARY: fix the bug Work: done in two files" \
    "$(_j $'COMMIT_SUMMARY: fix the bug\nWork: done in two files')"

print_test_section "B2: the old one-line form"
_old='UNMET: [fix-code] RQHBT-1 | WHY: w | ACCEPTED IF: a | QUOTE: f.sh | l'
assert_eq "[B2] an old one-line answer reads as it was" "$_old" "$(_j "$_old")"

print_test_section "B3: build's step answer"
assert_eq "[B3] the quote is only the line; the words are a note" \
    "step 4: done | QUOTE: docs/adr/ADR-005.md | ### §3 (amended 2026-11-24, #2533) — Heartbeat" \
    "$(_j $'step 4: done\nquote: docs/adr/ADR-005.md | ### §3 (amended 2026-11-24, #2533) — Heartbeat\nnote: adds §3a–§3e and their Enforced by entries')"

print_test_section "B5: a blank line ends a block"
assert_eq "[B5] two blocks are two answers" \
    $'MET: RQHBT-2\n\nUNMET: RQHBT-1 | WHY: w | QUOTE: f.sh | l' \
    "$(_j $'MET: RQHBT-2\n\nUNMET: RQHBT-1\nwhy: w\nquote: f.sh | l')"

print_test_section "B6: every mis-copied form, through a block, to the shared check"
# shellcheck source=../../scripts/lib/judge-quotes.sh
source "$REPO_ROOT/scripts/lib/judge-quotes.sh"
QR="$TEST_TEMP_DIR/qr"; mkdir -p "$QR/scripts"
printf '%s\n' 'run() {' '    printf "%s" "$x" | tee `out` && echo done' '}' > "$QR/scripts/a.sh"
_q6() {   # <form of the quote> — what the stage hands the check, from a block
    local j q w; zb_reply_join_v j $'UNMET: RQX-1\nwhy: w\nquote: '"$1"
    q="${j#*| QUOTE: }"
    if judge_quote_check_v w "$q" "" "$QR"; then printf ok; else printf 'bad: %s' "$w"; fi
}
LN='    printf "%s" "$x" | tee `out` && echo done'
for _form in "scripts/a.sh | $LN" \
             "scripts/a.sh | \`$LN\`" \
             "scripts/a.sh | **$LN**" \
             "\`scripts/a.sh\` | $LN" \
             "scripts/a.sh | ${LN//\"/\\\"}" \
             "scripts/a.sh | ${LN//\`/\\\`}" \
             "scripts/a.sh | printf \"%s\" \"\$x\" | tee …" \
             "scripts/a.sh | tee \`out\` && echo done"; do
    assert_eq "[B6] found: $_form" "ok" "$(_q6 "$_form")"
done

print_test_section "B7: every prompt that asks for a quote asks for the block form"
for _pf in plugins/agent/issue-acceptance/plugin.sh plugins/agent/design/lib/coverage-prompt.sh \
           plugins/agent/test-author/lib/correspondence-prompt.sh plugins/agent/test-author/plugin.sh \
           plugins/agent/build/lib/steps.sh plugins/agent/review-lens/lib/check.sh scripts/lib/unclear.sh; do
    _pt="$(<"$REPO_ROOT/$_pf")"
    assert_contains "[B7] $_pf asks for the block form" "${_pt//$'\n'/ }" "A quote: line holds only the"
    _old_form=""; while IFS= read -r _pl; do
        [[ "$_pl" =~ ^[[:space:]]*\<[^\>]*\>.*\|\ QUOTE:\ \< || "$_pl" =~ ^[A-Z][A-Za-z]*:.*\|\ QUOTE:\ \< ]] && _old_form+="$_pl"$'\n'
    done <<< "$_pt"
    assert_eq "[B7] $_pf shows no one-line | QUOTE: form" "" "$_old_form"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
