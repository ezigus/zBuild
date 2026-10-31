#!/usr/bin/env bash
# tests/unit/run-status-retry-row-test.sh — a stage that fails and then passes
# on a retry shows its last result in the run-status comment (ADR-064 §2).
#
# Why: in #1668's run (20261010132454-2484) plan's first try failed a schema
# check and the engine ran it again under the same row number. The retry passed
# and the run went on, but the comment still showed plan as "error": the row
# was closed by the first try, the retry's start was ignored because the row
# already existed, and the retry's pass found no open row to close.
#
# T1 [code] fail, then a retry that passes → the row shows pass
# T2 [code] the retry's start time is the row's start; one row, not two
# T3 [code] a repeated start for a row still running changes nothing
# T4 [change] #2439 (ADR-064, amended 2026-10-31): when the engine retries a
#             stage (stage.retry), the try's row closes on the outcome it ended
#             on, and the next try has its own row — one row per try
# T5 [change] each try's row says which try it is, of how many
# T6 [change] what closes the stage closes its latest try's row, not the first
# T7 [change] the rendered comment shows both tries
#
# T1 also covers the summary counts the first try's prompt carried (review of
# the fix): the retry's row shows its own, or none.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "run-status comment — a retried stage shows its last result (ADR-064 §2)"
setup_test_env "run-status-retry-row"
_test_cleanup_hook() { cleanup_test_env; }

# shellcheck source=../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"

EV="$TEST_TEMP_DIR/events.jsonl"
# The envelopes core/event-bus/event-bus.sh wrote in #1668's run, in order,
# trimmed to the fields the renderer reads.
cat > "$EV" <<'EOF'
{"ts":"2026-10-10T13:25:07.346Z","run_id":"r","issue":1668,"type":"stage.start","plugin":"","kind":"","data":{"stage":"plan"},"schema_version":1}
{"ts":"2026-10-10T13:25:07.946Z","run_id":"r","issue":1668,"type":"plugin.run.start","plugin":"plan","kind":"agent","data":{"plugin":"plan","kind":"agent"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:25:08.743Z","run_id":"r","issue":1668,"type":"stage.previous_work.written","plugin":"","kind":"","data":{"stage":"plan","stages":"4","failing":"2"},"schema_version":1,"stage":"plan"}
{"ts":"2026-10-10T13:27:42.095Z","run_id":"r","issue":1668,"type":"plugin.result","plugin":"plan","kind":"agent","data":{"verdict":"error","plugin":"plan","reason":"schema_violation"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:27:42.113Z","run_id":"r","issue":1668,"type":"plugin.run.error","plugin":"plan","kind":"agent","data":{"plugin":"plan","kind":"agent","rc":"1"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:27:42.857Z","run_id":"r","issue":1668,"type":"plugin.run.start","plugin":"plan","kind":"agent","data":{"plugin":"plan","kind":"agent"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:29:01.177Z","run_id":"r","issue":1668,"type":"plugin.result","plugin":"plan","kind":"agent","data":{"stage":"plan","plugin":"plan","artifact":"plan.json"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:29:02.442Z","run_id":"r","issue":1668,"type":"plugin.run.complete","plugin":"plan","kind":"agent","data":{"plugin":"plan","kind":"agent"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:29:02.813Z","run_id":"r","issue":1668,"type":"stage.complete","plugin":"","kind":"","data":{"stage":"plan","verdict":"pass"},"schema_version":1}
EOF
_rows="$(rsc_rows_json "$EV")"
assert_eq "[T1] the retried stage's row shows pass" "pass" "$(jq -r '.rows["3"].verdict // "none"' <<< "$_rows")"
assert_eq "[T1] ...with no leftover error code" "null" "$(jq -r '.rows["3"].rc' <<< "$_rows")"
assert_eq "[T1] ...and none of the first try's summary counts" "null null" \
    "$(jq -r '"\(.rows["3"].summaries) \(.rows["3"].resolve)"' <<< "$_rows")"
assert_eq "[T2] one row for the stage" "1" "$(jq -r '.order | length' <<< "$_rows")"
assert_eq "[T2] the row starts at the retry" "2026-10-10T13:27:42.857Z" "$(jq -r '.rows["3"].started_ts' <<< "$_rows")"
assert_eq "[T2] the row ends at the retry's end" "2026-10-10T13:29:02.813Z" "$(jq -r '.rows["3"].ended_ts' <<< "$_rows")"

EV3="$TEST_TEMP_DIR/events3.jsonl"
head -n 2 "$EV" > "$EV3"
sed -n 2p "$EV" | sed 's/13:25:07.946Z/13:26:00.000Z/' >> "$EV3"
_r3="$(rsc_rows_json "$EV3")"
assert_eq "[T3] a repeated start while running keeps the first start" "2026-10-10T13:25:07.946Z" \
    "$(jq -r '.rows["3"].started_ts' <<< "$_r3")"
assert_eq "[T3] ...and the row is still running" "null" "$(jq -r '.rows["3"].verdict' <<< "$_r3")"

# ── T4–T7: one row per try (#2439) ──────────────────────────────────────────
EV4="$TEST_TEMP_DIR/events4.jsonl"
cat > "$EV4" <<'EOF4'
{"ts":"2026-10-31T15:12:13.000Z","run_id":"r","issue":1754,"type":"pipeline.start","data":{"run_id":"r","issue":"1754"},"schema_version":1}
{"ts":"2026-10-31T15:12:13.100Z","run_id":"r","issue":1754,"type":"plugin.run.start","plugin":"build","kind":"agent","data":{"plugin":"build","kind":"agent"},"schema_version":1,"stage":"build","seq":"4.1.1.1.3"}
{"ts":"2026-10-31T15:27:15.000Z","run_id":"r","issue":1754,"type":"plugin.run.error","plugin":"build","kind":"agent","data":{"plugin":"build","kind":"agent","rc":"1"},"schema_version":1,"stage":"build","seq":"4.1.1.1.3"}
{"ts":"2026-10-31T15:27:15.500Z","run_id":"r","issue":1754,"type":"stage.retry","data":{"stage":"build","outcome":"timed_out","try":"2","of":"3","wait_s":"0","rc":"1"},"schema_version":1,"stage":"build","seq":"4.1.1.1.3"}
{"ts":"2026-10-31T15:27:16.000Z","run_id":"r","issue":1754,"type":"plugin.run.start","plugin":"build","kind":"agent","data":{"plugin":"build","kind":"agent"},"schema_version":1,"stage":"build","seq":"4.1.1.1.3"}
{"ts":"2026-10-31T15:35:00.000Z","run_id":"r","issue":1754,"type":"plugin.run.complete","plugin":"build","kind":"agent","data":{"plugin":"build","kind":"agent"},"schema_version":1,"stage":"build","seq":"4.1.1.1.3"}
{"ts":"2026-10-31T15:35:01.000Z","run_id":"r","issue":1754,"type":"cycle.member.dispatch.complete","data":{"member":"build","verdict":"pass","rc":"0"},"schema_version":1,"stage":"build","seq":"4.1.1.1.3"}
EOF4
_r4="$(rsc_rows_json "$EV4")"
assert_eq "[T4] two rows: one per try" "2" "$(jq -r '.order | length' <<< "$_r4")"
_k1="$(jq -r '.order[0]' <<< "$_r4")"; _k2="$(jq -r '.order[1]' <<< "$_r4")"
assert_eq "[T4] the first try's row closed on timed_out" "timed_out" "$(jq -r --arg k "$_k1" '.rows[$k].verdict' <<< "$_r4")"
assert_eq "[T4] ...when the retry was decided" "2026-10-31T15:27:15.500Z" "$(jq -r --arg k "$_k1" '.rows[$k].ended_ts' <<< "$_r4")"
assert_eq "[T4] the second try's row starts at its own start" "2026-10-31T15:27:16.000Z" "$(jq -r --arg k "$_k2" '.rows[$k].started_ts' <<< "$_r4")"
assert_eq "[T5] the first row is try 1 of 3" "1 3" "$(jq -r --arg k "$_k1" '"\(.rows[$k].try) \(.rows[$k].of)"' <<< "$_r4")"
assert_eq "[T5] the second row is try 2 of 3" "2 3" "$(jq -r --arg k "$_k2" '"\(.rows[$k].try) \(.rows[$k].of)"' <<< "$_r4")"
assert_eq "[T6] the stage's close lands on the latest try" "pass" "$(jq -r --arg k "$_k2" '.rows[$k].verdict' <<< "$_r4")"
assert_eq "[T6] ...and leaves the first try as it ended" "timed_out" "$(jq -r --arg k "$_k1" '.rows[$k].verdict' <<< "$_r4")"
_body="$(ZBUILD_STATUS_TZ=UTC rsc_render_body "$EV4" "$TEST_TEMP_DIR" 2>/dev/null)"
assert_contains "[T7] the comment shows try 1 timed out" "$_body" "try 1 of 3 · **timed_out**"
assert_contains "[T7] ...and try 2 passing" "$_body" "try 2 of 3 · **pass**"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
