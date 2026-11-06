#!/usr/bin/env bash
# tests/unit/status-row-findings-test.sh — a row for a try that did not pass
# says what failed (ADR-064 §4, amended 2026-11-06, #2476).
#
# Why: on #1805 run 42127743259 a failing design try's row read "the design fails
# 2 check(s)" and, folded, "The findings are in design's result. This try is
# kept as the working copy…"; test-author's read "8 finding(s) about its
# assertions are open — the next try fixes them". Nothing said what failed:
# since #2470 the findings live in the stage's result only, and the row was
# built from the summary only. The row is for the person reading the issue.
#
# W1 [change] a try that did not pass, whose result holds findings: the row's
#             line says how many (#2480: not the first finding, which the folded
#             list repeated); the folded part lists every finding once; nothing
#             of the summary is shown
# W2 [change] a map member (a lens) reads its own result, named on its event,
#             and a lens's finding is its message and file
# W3 [guard]  a try that did not pass and has no findings shows its summary
# W4 [guard]  a try that passed shows its summary, whatever its result holds
# W5 [change] #2480: findings with a severity are counted by it
# W6 [change] #2480: one finding of several lines: its first line heads the row,
#             the rest is folded, and the first line is not said twice
# W7 [change] #2480: a try run again because its result held findings shows
#             as failed, not `unusable` (test-author's own label for "my check
#             found something", #2460); one with no findings stays unusable
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a row for a try that did not pass says what failed (#2476)"
setup_test_env "status-row-findings"

# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$REPO_ROOT/scripts/lib/run-status-comment.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"

S="$TEST_TEMP_DIR/state"; A="$S/artifacts"; mkdir -p "$A"
_row() {   # <seq> <stage> <verdict> [extra-json]
    jq -cn --arg q "$1" --arg s "$2" --arg v "$3" --argjson x "${4:-{\}}" \
        '{key:$q, seq:$q, stage:$s, kind:"agent", started_ts:"2026-11-06T12:00:00.000Z",
          ended_ts:"2026-11-06T12:05:00.000Z", verdict:$v, rc:null} + $x'
}

# The stage's own writers make its files (#1799): the result with its findings,
# the summary with the boilerplate the row must no longer show.
stage_result_write "$A/judge-result.json" unusable "the design fails 2 of its checks" \
    "{\"findings\": $(printf '%s\n' \
        "SKIP-1 Then 1 is not asserted: the test checks the file, not the run" \
        $'BNDY-1 describes what a file contains\x1e  Given: a test file' | stage_findings_json)}"
stage_summary_write "$A/judge-summary.md" judge fail "the design fails 2 check(s)" \
    "The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged."

# ── W1 ───────────────────────────────────────────────────────────────────────
w1="$(rsc_render_row "$S" "$(_row 3.1.1.1.1 judge unusable)")"
assert_eq "[W1] the row's line says how many failed" "what failed: 2 findings" "$(sed -n 1p <<< "$w1" | sed 's/.* — //')"
assert_contains "[W1] the folded part lists every finding" "$w1" "BNDY-1 describes what a file contains"
assert_eq "[W1] …each once" "1" "$(grep -c "SKIP-1 Then 1 is not asserted" <<< "$w1")"
if grep -qF "working copy" <<< "$w1" || grep -qF "fails 2 check(s)" <<< "$w1"; then
    assert_fail "[W1] nothing of the summary is shown" "$w1"
else
    assert_pass "[W1] nothing of the summary is shown"
fi

# ── W2 ───────────────────────────────────────────────────────────────────────
printf '%s\n' '{"lens":"correctness","findings":[{"file":"core/x.sh","line":12,"severity":"high","message":"the loop never ends","introduced":true,"fix":"code"}]}' \
    > "$A/lens-correctness.json"
stage_result_add "$A/lens-correctness.json" fail "the correctness lens found a high problem the change introduced"
stage_summary_write "$A/lens-correctness-summary.md" review-lens-correctness fail "reviewed the change — 1 finding(s), score 40" "- artifact: lens-correctness.json"
w2="$(rsc_render_row "$S" "$(_row 3.2.1 review_lenses.correctness fail \
    "{\"member\":true,\"summary_path\":\"$A/lens-correctness-summary.md\",\"result_path\":\"$A/lens-correctness.json\"}")")"
assert_contains "[W2] a lens row says what it found, and where" "$w2" "what failed: high: the loop never ends (core/x.sh:12)"

# ── W3 ───────────────────────────────────────────────────────────────────────
stage_result_write "$A/quiet-result.json" timed_out "the model call ran out of time"
stage_summary_write "$A/quiet-summary.md" quiet timed_out "ran out of time after reading 40 files"
assert_contains "[W3] no findings: the summary as before" \
    "$(rsc_render_row "$S" "$(_row 4 quiet timed_out)")" "ran out of time after reading 40 files"

# ── W4 ───────────────────────────────────────────────────────────────────────
stage_result_write "$A/fine-result.json" pass "ok" '{"findings":[{"n":1,"text":"an advisory note"}]}'
stage_summary_write "$A/fine-summary.md" fine pass "wrote tests for LOOP-1 and KEEP-1"
w4="$(rsc_render_row "$S" "$(_row 5 fine pass)")"
assert_contains "[W4] a pass row shows its summary" "$w4" "wrote tests for LOOP-1 and KEEP-1"
if grep -qF "what failed" <<< "$w4"; then assert_fail "[W4] …and never says what failed" "$w4"
else assert_pass "[W4] …and never says what failed"; fi

# ── W5 ───────────────────────────────────────────────────────────────────────
printf '%s\n' '{"lens":"sre","findings":[{"file":"a.sh","severity":"medium","message":"M-ONE"},{"file":"a.sh","severity":"high","message":"H-ONE"},{"file":"a.sh","severity":"medium","message":"M-TWO"}]}' \
    > "$A/lens-sre.json"
stage_result_add "$A/lens-sre.json" fail "the sre lens found a high problem"
w5="$(rsc_render_row "$S" "$(_row 3.2.6 review_lenses.sre fail "{\"member\":true,\"result_path\":\"$A/lens-sre.json\"}")")"
assert_contains "[W5] findings are counted by severity, highest first" "$w5" "what failed: 3 findings: 1 high, 2 medium"
assert_eq "[W5] …and each is listed once" "1" "$(grep -c "M-ONE" <<< "$w5")"

# ── W6 ───────────────────────────────────────────────────────────────────────
stage_result_write "$A/ta-result.json" unusable "its own check found 1 SPEC to fix" \
    "{\"findings\": $(printf '%s\n' $'ENTR-1 Given: the test never puts the state under runs/x\x1eENTR-1[code]: the paths restore\x1e  Given: a run is interrupted [FIX IN TEST: …]' | stage_findings_json)}"
w6="$(rsc_render_row "$S" "$(_row 3.2.1.2.2 ta unusable)")"
assert_contains "[W6] one finding: its first line heads the row" "$w6" "what failed: ENTR-1 Given: the test never puts the state under runs/x"
assert_contains "[W6] …the rest is folded" "$w6" "ENTR-1[code]: the paths restore"
assert_eq "[W6] …and the first line is said once" "1" "$(grep -c "the test never puts the state" <<< "$w6")"

# ── W7 ───────────────────────────────────────────────────────────────────────
assert_contains "[W7] a try run again for its findings shows as failed" "$w6" "· **fail** —"
stage_result_write "$A/noread-result.json" unusable "the reply could not be read"
stage_summary_write "$A/noread-summary.md" noread unusable "the judge's reply had no line for LOOP-1"
assert_contains "[W7] …one with no findings stays unusable" "$(rsc_render_row "$S" "$(_row 6 noread unusable)")" "· **unusable** —"

print_test_results
exit $((FAIL > 0))
