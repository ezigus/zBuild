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
#             line is the first finding, "and N more"; the folded part lists
#             every finding; nothing of the summary is shown
# W2 [change] a map member (a lens) reads its own result, named on its event,
#             and a lens's finding is its message and file
# W3 [guard]  a try that did not pass and has no findings shows its summary
# W4 [guard]  a try that passed shows its summary, whatever its result holds
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
assert_contains "[W1] the row's line is the first finding" "$w1" \
    "what failed: SKIP-1 Then 1 is not asserted: the test checks the file, not the run (and 1 more)"
assert_contains "[W1] the folded part lists every finding" "$w1" "BNDY-1 describes what a file contains"
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

print_test_results
exit $((FAIL > 0))
