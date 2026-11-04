#!/usr/bin/env bash
# tests/unit/reply-multiline-test.sh — what a model says is read whole, however
# many lines it spans, and one item is never split into two (#2460).
#
# Why: every reader of a model's reply took one line per item. A wrapped
# REQUIREMENT, UNMET, REASON or ANSWER kept only its first half; a list written
# under its key as bullets was lost; and items were split on ';', so one
# requirement holding a ';' became two. A wrapped "the test is wrong:" answer
# was dropped entirely.
#
# J1 [change] zb_reply_join_v joins a continued line to the line it continues
# J2 [guard]  ...never across a blank line, and never into a new KEY:, ANSWER,
#             list item or LOOP_COMPLETE
# J3 [change] ...a list under an empty KEY: becomes one KEY: line per item
# Q1 [change] intake keeps a wrapped requirement whole, and a missing one that
#             holds ';' stays one requirement
# Q2 [change] issue-acceptance keeps a wrapped UNMET whole (#2464: its WHY and
#             QUOTE on the lines that continue it)
# Q3 [change] design's coverage check reads its item lines bulleted, one per
#             line, a wrapped one whole
#             or as bullets, and never splits one on ';'
# Q4 [change] test-author's check reads a REASON on the line after its SPEC's
#             verdict, and a REASON holding '|' whole
# Q5 [change] test-author keeps a wrapped ANSWER whole
# Q6 [change] build reads a wrapped "the test is wrong:" and "not reproduced:"
# Q7 [change] a COMMIT_SUMMARY whose text is on the next line is read
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "what a model says is read whole (#2460)"
setup_test_env "reply-multiline"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

# ── J1-J3 ────────────────────────────────────────────────────────────────────
# shellcheck source=../../scripts/lib/reply-units.sh
source "$REPO_ROOT/scripts/lib/reply-units.sh" 2>/dev/null || true
_j=""
zb_reply_join_v _j $'REASON: the timeout is not applied\n  to the retry path\nUNMET: [fix-code] R-2: a hung retry\nblocks forever\n\nprose after a blank\nANSWER test finding 1: done\nLOOP_COMPLETE' 2>/dev/null
assert_contains "[J1] a continued line joins the line it continues" "$_j" "REASON: the timeout is not applied to the retry path"
assert_contains "[J1] ...for each item" "$_j" "UNMET: [fix-code] R-2: a hung retry blocks forever"
_lacks "[J2] never across a blank line" "$_j" "forever prose"
assert_contains "[J2] ...nor into an ANSWER or LOOP_COMPLETE" "$_j" $'ANSWER test finding 1: done\nLOOP_COMPLETE'
zb_reply_join_v _j $'MISSING:\n- Tests for R1-R5 must use a cycle\n- A test pins each side;\n  both ways' 2>/dev/null
assert_contains "[J3] a list under an empty key becomes one key line per item" "$_j" "MISSING: Tests for R1-R5 must use a cycle"
assert_contains "[J3] ...and an item's continued line joins it" "$_j" "MISSING: A test pins each side; both ways"

# ── Q1 ───────────────────────────────────────────────────────────────────────
(
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
    route_to_model() {
        if [[ "$2" == *"THE LIST:"* ]]; then printf 'MISSING: RTRY-1 retries 3 times; on the last failure it exits 2\n'
        else printf 'REQUIREMENT: GATE-1 the gate must reject a test that\n  passes on the old code\nREQUIREMENT: SUMM-1 the summary names the file\n'; fi
    }
    _j=""; _intake_requirements_json_v _j '{"title":"t","body":"b"}' >/dev/null 2>&1
    printf '%s' "$_j" > "$TEST_TEMP_DIR/q1.json"
)
_q1="$(jq -r '.requirements[].text' "$TEST_TEMP_DIR/q1.json" 2>/dev/null)"
assert_contains "[Q1] a wrapped requirement is kept whole" "$_q1" "the gate must reject a test that passes on the old code"
assert_contains "[Q1] a missing requirement holding ';' stays one" "$_q1" "retries 3 times; on the last failure it exits 2"
assert_eq "[Q1] ...three requirements, not four" "3" "$(jq '.requirements | length' "$TEST_TEMP_DIR/q1.json" 2>/dev/null)"

# ── Q2 ───────────────────────────────────────────────────────────────────────
(
    ad="$TEST_TEMP_DIR/q2/state/artifacts"; sd="${ad%/artifacts}"; mkdir -p "$ad"
    git -C "$TEST_TEMP_DIR/q2" init -q -b main >/dev/null 2>&1
    printf '{"schema_version":1}\n' > "$sd/pipeline-state.json"
    printf '# Design\n```acceptance\nSPEC-1[code]: x\nTESTFILES:\nSPEC-1: tests/a.sh\nWIRING: none\n```\n' > "$ad/design.md"
    zb_test_issue_output "$sd" "ISSUE-TEXT: the retry is bounded" >/dev/null
    printf 'diff --git a/foo.sh b/foo.sh\n' > "$ad/d.patch"
    jq -n --arg g "$sd/intake-result.json" --arg d "$ad/design.md" --arg p "$ad/d.patch" \
        '{schema_version:2, stage:"issue-acceptance", inputs:{a:$g, b:$d, c:$p}}' > "$sd/idx.json"
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf 'UNMET: [fix-code] the retry | WHY: the timeout is not applied to the retry path,\n  so a hung retry blocks forever | QUOTE: "the retry is bounded"\n'; }
    ZBUILD_STAGE_INPUTS="$sd/idx.json" ZBUILD_ARTIFACT_DIR="$ad" ZBUILD_REPO_ROOT="${sd%/state}" \
        issue_acceptance_run issue-acceptance "$sd/pipeline-state.json" >/dev/null 2>&1
)
_q2="$TEST_TEMP_DIR/q2/state/artifacts/issue-acceptance-result.json"
assert_contains "[Q2] a wrapped UNMET is kept whole" "$(jq -r '[.data.unmet[]?, .data.findings[]?.text?] | map(strings) | join("\n")' "$_q2" 2>/dev/null)" "so a hung retry blocks forever"
assert_contains "[Q2] ...with the quote on its continued line" "$(jq -r '.data.unmet[0] // ""' "$_q2" 2>/dev/null)" '"the retry is bounded"'

# ── Q3 ───────────────────────────────────────────────────────────────────────
(
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    d="$TEST_TEMP_DIR/q3.md"
    printf '# Design\n```acceptance\nSPEC-1[code]: x covers: R-1\nTESTFILES:\nSPEC-1: tests/a.sh\nWIRING: none\n```\n' > "$d"
    route_to_model() { printf -- '- R-1: covered\n- R-2: uncovered | WHY: retries 3 times; then exits 2 | QUOTE: "retries"\n- R-3: uncovered | WHY: names the file,\n  and only the file | QUOTE: "names"\n- SPEC-1: ok\n'; }
    _design_coverage "$d" $'- R-1: x\n- R-2: retries\n- R-3: names' T2 >/dev/null 2>&1
    printf '%s\n' "${_DESIGN_UNCOVERED[@]}" > "$TEST_TEMP_DIR/q3.txt"
)
_q3="$(cat "$TEST_TEMP_DIR/q3.txt" 2>/dev/null)"
assert_contains "[Q3] a bulleted item, wrapped, is read whole" "$_q3" "R-3: names the file, and only the file"
assert_contains "[Q3] ...and one holding ';' stays one" "$_q3" "R-2: retries 3 times; then exits 2"
assert_eq "[Q3] ...two items" "2" "$(grep -c . "$TEST_TEMP_DIR/q3.txt" 2>/dev/null || true)"

# ── Q4 ───────────────────────────────────────────────────────────────────────
(
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    _l=""; _sc_batch_line_v _l $'SPEC-1: VERDICT: partial\nREASON: it checks grep x | wc -l, not the file\nSPEC-2: VERDICT: corresponds | REASON: ok' SPEC-1
    printf '%s\n' "$(_sc_parse_verdict "$_l")" "$(_sc_parse_reason "$_l")" > "$TEST_TEMP_DIR/q4.txt"
)
assert_eq "[Q4] the verdict is read" "partial" "$(sed -n 1p "$TEST_TEMP_DIR/q4.txt" 2>/dev/null)"
assert_eq "[Q4] a REASON on the next line, holding '|', is read whole" "it checks grep x | wc -l, not the file" "$(sed -n 2p "$TEST_TEMP_DIR/q4.txt" 2>/dev/null)"
(
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    _sc_one_reason $'VERDICT: partial\nREASON: it checks the exit code\n  of the wrong command' > "$TEST_TEMP_DIR/q4b.txt"
)
assert_eq "[Q4] the one-requirement answer keeps a wrapped REASON whole (review on #2461)" "it checks the exit code of the wrong command" \
    "$(cat "$TEST_TEMP_DIR/q4b.txt" 2>/dev/null)"

# ── Q5 ───────────────────────────────────────────────────────────────────────
(
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    _TA_ANSWERS=()
    _ta_collect_answers $'ANSWER test finding 2: done — rewrote the fixture so it\n  runs against the merge-base\nLOOP_COMPLETE'
    printf '%s' "${_TA_ANSWERS[0]:-}" > "$TEST_TEMP_DIR/q5.txt"
)
assert_eq "[Q5] a wrapped ANSWER is kept whole" "test finding 2: done — rewrote the fixture so it runs against the merge-base" \
    "$(cat "$TEST_TEMP_DIR/q5.txt" 2>/dev/null)"

# ── Q6 ───────────────────────────────────────────────────────────────────────
(
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    _build_test_wrong $'ANSWER test finding 1: nothing to do — the test is wrong:\n  tests/x-test.sh: asserts the old exit code' > "$TEST_TEMP_DIR/q6a.txt"
    _build_not_reproduced $'ANSWER test finding 2: nothing to do — not reproduced:\n  tests/y-test.sh' > "$TEST_TEMP_DIR/q6b.txt"
)
assert_eq "[Q6] a wrapped 'the test is wrong' answer is read" "test finding 1: tests/x-test.sh: asserts the old exit code" \
    "$(cat "$TEST_TEMP_DIR/q6a.txt" 2>/dev/null)"
assert_eq "[Q6] ...and a wrapped 'not reproduced'" "tests/y-test.sh" "$(cat "$TEST_TEMP_DIR/q6b.txt" 2>/dev/null)"

# ── Q7 ───────────────────────────────────────────────────────────────────────
(
    source "$REPO_ROOT/core/router/route.sh" >/dev/null 2>&1
    _route_parse_commit_summary_line $'done.\nCOMMIT_SUMMARY:\n  guard the resume read\nLOOP_COMPLETE' > "$TEST_TEMP_DIR/q7.txt"
)
assert_eq "[Q7] a COMMIT_SUMMARY whose text is on the next line is read" "guard the resume read" "$(cat "$TEST_TEMP_DIR/q7.txt" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
