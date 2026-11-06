#!/usr/bin/env bash
# tests/unit/status-row-text-test.sh — the run-status comment shows what each
# stage said, as text, and where each row sits (#2480, ADR-064 §4).
#
# Why: on #1805 run 42229975998 design's SPECs said `--from-stage <s>`, and
# GitHub took `<s>` for the strike-through tag — nothing closed it, so the rest
# of the comment was struck through; `runs/<run_id>/` and `<state_dir>` in the
# lenses' findings vanished as unknown tags. Design in round 2 of delivery_loop
# read "iter 1": build_test_cycle's round, the outer one only in the position
# number. A lens still running read "review_lenses", not which lens.
#
# X1 [change] `<` and `>` a stage wrote are escaped outside code spans; inside
#             one they stay; the renderer's own <details> stays a tag
# X2 [change] …in a finding a row shows
# X3 [change] …and in the open items the header lists
# R1 [change] a row names the round of every loop it is inside, by the loop's
#             name: delivery_loop round 2 · build_test_cycle round 1
# R2 [change] …and never "iter 1" for it
# L1 [change] a running member of a group shows its own name
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the run-status comment shows what each stage said, as text (#2480)"
setup_test_env "status-row-text"

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
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"; else assert_pass "$1"; fi
}

# ── X1 ───────────────────────────────────────────────────────────────────────
print_test_section "X1–X3: a stage's text is text"
stage_summary_write "$A/design-summary.md" design pass "14 SPEC(s): FSTG-1, FSTG-2" \
    "- FSTG-1 (covers FROM-1): --from-stage <s> rehydrates all stages before <s>
- the flag is written \`--from-stage <s>\`"
x1="$(rsc_render_row "$S" "$(_row 3.1.1.1.1 design pass)")"
assert_contains "[X1] <s> a stage wrote is escaped" "$x1" "--from-stage &lt;s&gt; rehydrates all stages before &lt;s&gt;"
assert_contains "[X1] …but not inside a code span" "$x1" "\`--from-stage <s>\`"
assert_contains "[X1] …and the renderer's own fold stays a tag" "$x1" "<details><summary>the rest of what it reported</summary>"
# A backtick with no partner opens no code span on GitHub (review on #2481):
# what follows it is text, and is escaped like any other.
stage_summary_write "$A/design-summary.md" design pass "1 SPEC(s): FSTG-1" \
    "- use \`--from-stage <s> to skip"
x1b="$(rsc_render_row "$S" "$(_row 3.1.1.1.1 design pass)")"
assert_contains "[X1] <s> after an unpaired backtick is escaped" "$x1b" "\`--from-stage &lt;s&gt; to skip"
x1c="$( source "$REPO_ROOT/scripts/lib/run-open-items.sh"
    jq -rn --arg t 'a `b <s>` then `c <d>' "$_RSC_JQ_ESC"'$t | esc' )"
assert_eq "[X1] …in an open item too, the code span kept as it is" \
    'a `b <s>` then `c &lt;d&gt;' "$x1c"

# ── X2 ───────────────────────────────────────────────────────────────────────
printf '%s\n' '{"lens":"scope","findings":[{"file":"a.sh","severity":"medium","message":"auto-resume reads state before the run switches to runs/<run_id>/"}]}' > "$A/lens-scope.json"
stage_result_add "$A/lens-scope.json" fail "the scope lens found a medium problem"
x2="$(rsc_render_row "$S" "$(_row 3.1.2.5 review_lenses.scope fail "{\"member\":true,\"result_path\":\"$A/lens-scope.json\"}")")"
assert_contains "[X2] a finding's <run_id> is escaped" "$x2" "runs/&lt;run_id&gt;/"

# ── X3 ───────────────────────────────────────────────────────────────────────
x3="$(open_items_render '[{"ref":"lens-scope-code finding 1","opener":"lens-scope-code","text":"reads <state_dir> first"}]')"
assert_contains "[X3] an open item's <state_dir> is escaped" "$x3" "reads &lt;state_dir&gt; first"

# ── R1 / R2 / L1 ─────────────────────────────────────────────────────────────
# The envelopes core/event-bus/event-bus.sh wrote in run 42229975998, in
# order, trimmed to the events these rows are made from.
EV="$TEST_TEMP_DIR/events.jsonl"
cat > "$EV" <<'EOF'
{"ts":"2026-11-06T13:59:58.717Z","run_id":"20261106135957-2420","issue":1805,"type":"pipeline.start","plugin":"","kind":"","data":{"run_id":"20261106135957-2420","issue":"1805","engine_sha":"55f0cbe44c6f3f1ea89dc900d229b008a9f4126e","engine_branch":"main"},"schema_version":1}
{"ts":"2026-11-06T14:02:40.803Z","run_id":"20261106135957-2420","issue":1805,"type":"cycle.start","plugin":"","kind":"","data":{"cycle_id":"delivery_loop","iter":"1","max":"2","stages":"build_test_cycle review_lenses"},"schema_version":1}
{"ts":"2026-11-06T14:02:40.884Z","run_id":"20261106135957-2420","issue":1805,"type":"cycle.start","plugin":"","kind":"","data":{"cycle_id":"build_test_cycle","iter":"1","max":"3","stages":"design test-author build test issue-acceptance"},"schema_version":1,"stage":"build_test_cycle","seq":"3.1.1"}
{"ts":"2026-11-06T14:02:41.280Z","run_id":"20261106135957-2420","issue":1805,"type":"plugin.run.start","plugin":"design","kind":"agent","data":{"plugin":"design","kind":"agent"},"schema_version":1,"stage":"design","seq":"3.1.1.1.1"}
{"ts":"2026-11-06T14:38:39.446Z","run_id":"20261106135957-2420","issue":1805,"type":"parallel.group.start","plugin":"","kind":"","data":{"group":"review_lenses"},"schema_version":1,"stage":"review_lenses","seq":"3.1.2"}
{"ts":"2026-11-06T14:55:11.311Z","run_id":"20261106135957-2420","issue":1805,"type":"cycle.start","plugin":"","kind":"","data":{"cycle_id":"build_test_cycle","iter":"1","max":"3","stages":"design test-author build test issue-acceptance"},"schema_version":1,"stage":"build_test_cycle","seq":"3.2.1"}
{"ts":"2026-11-06T14:55:11.859Z","run_id":"20261106135957-2420","issue":1805,"type":"plugin.run.start","plugin":"design","kind":"agent","data":{"plugin":"design","kind":"agent"},"schema_version":1,"stage":"design","seq":"3.2.1.1.1"}
{"ts":"2026-11-06T16:34:30.566Z","run_id":"20261106135957-2420","issue":1805,"type":"parallel.group.start","plugin":"","kind":"","data":{"group":"review_lenses"},"schema_version":1,"stage":"review_lenses","seq":"3.2.2"}
{"ts":"2026-11-06T16:34:32.689Z","run_id":"20261106135957-2420","issue":1805,"type":"plugin.run.start","plugin":"review-lens","kind":"agent","data":{"plugin":"review-lens","kind":"agent"},"schema_version":1,"stage":"review_lenses","seq":"3.2.2.4","unit":"review_lenses.correctness"}
EOF
_m="$(rsc_rows_json "$EV")"
_r() { rsc_render_row "$S" "$(jq -c --arg k "$1" '.rows[$k]' <<< "$_m")"; }
print_test_section "R1/R2: every loop's round, by name"
r2="$(_r 3.2.1.1.1)"
assert_contains "[R1] design in delivery round 2 names both rounds" "$r2" "**3.2.1.1.1 design** · delivery_loop round 2 · build_test_cycle round 1"
assert_contains "[R1] …and in round 1, round 1 of each" "$(_r 3.1.1.1.1)" "· delivery_loop round 1 · build_test_cycle round 1"
assert_not_contains "[R2] …never \"iter 1\"" "$r2" "iter 1"
print_test_section "L1: a running member's own name"
assert_contains "[L1] a lens still running is named" "$(_r 3.2.2.4)" "**3.2.2.4 review_lenses.correctness**"
assert_contains "[L1] …in the round its group is in" "$(_r 3.2.2.4)" "· delivery_loop round 2"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
