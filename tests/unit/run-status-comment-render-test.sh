#!/usr/bin/env bash
# Tests: the run-status comment renderer (#2131, ADR-064, keeper e-1).
#
# Pure part of the sidecar: events.jsonl + state dir → markdown body. No gh,
# no network. Row rules, newest-first order, the 60 KB bound, outbound
# redaction, and the "never writes events" property are all pinned here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-status-comment — render (#2131)"
setup_test_env "rsc-render"

LIB="$REPO_ROOT/scripts/lib/run-status-comment.sh"

# ─── SPEC-0: the library exists and is source-only ──────────────────────────
if [[ -f "$LIB" ]] && source "$LIB" 2>/dev/null && declare -F rsc_render_body >/dev/null 2>&1; then
    assert_pass "[SPEC-0] scripts/lib/run-status-comment.sh sources and defines rsc_render_body"
else
    assert_fail "[SPEC-0] scripts/lib/run-status-comment.sh sources and defines rsc_render_body" "missing"
    print_test_results; exit 1
fi

STATE="$TEST_TEMP_DIR/state"
EV="$STATE/events.jsonl"
mkdir -p "$STATE/artifacts" "$STATE/stage-inputs"
: > "$EV"

# ev <ts-time> <type> [seq] [stage] [k=v ...] — one envelope line, the shape
# core/event-bus/event-bus.sh writes (all data values are strings).
ev() {
    local t="$1" type="$2" seq="${3:-}" stage="${4:-}"; shift 4
    local data="{}" kv
    for kv in "$@"; do
        data="$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<< "$data")"
    done
    jq -cn --arg ts "2026-09-17T${t}.000Z" --arg type "$type" --arg seq "$seq" \
        --arg stage "$stage" --argjson data "$data" \
        '{ts:$ts, run_id:"r-2131", issue:90000042, type:$type, plugin:"", kind:"", data:$data, schema_version:1}
         + (if $stage != "" then {stage:$stage} else {} end)
         + (if $seq != "" then {seq:$seq} else {} end)' >> "$EV"
}

printf '## intake — pass\n\n- adopted branch zbuild/issue-42\n' > "$STATE/artifacts/intake-summary.md"
printf '## build — pass\n\n- 3 files changed, tests added\n\nlonger body\n' > "$STATE/artifacts/build-summary.md"
printf '%s\n' '{"schema_version":1,"stage":"deploy","inputs":{"plan":"/x/plan.json","design":"/x/design.md"}}' > "$STATE/stage-inputs/deploy.json"
printf '%s\n' '{"schema_version":1,"stage":"test","inputs":{"diff":"/x/diff.patch","plan":"/x/plan.json"}}' > "$STATE/stage-inputs/test.json"
printf '%s\n' '{"schema_version":1,"run_id":"r-2131","issue":90000042,"engine_sha":"abcdef1234567890","status":"running","stage_statuses":{}}' > "$STATE/pipeline-state.json"

ev 12:00:00 pipeline.start "" "" run_id=r-2131 issue=90000042 engine_sha=abcdef1234567890 engine_branch=main
ev 12:00:01 plugin.run.start 1 intake plugin=intake kind=agent
ev 12:00:01 plugin.run.complete 1 intake plugin=intake kind=agent
ev 12:00:01 stage.complete 1 intake stage=intake verdict=pass
ev 12:20:14 plugin.run.start 6.1.1 build plugin=build kind=agent
ev 12:20:20 plugin.run.start 6.1.1 build plugin=build-nested kind=tool    # nested hook: same seq
ev 12:20:30 prompt.summaries.injected 6.1.1 build stage=build stages=16 resolve=4 bytes=9000
ev 13:21:47 cycle.member.dispatch.complete 6.1.1 build cycle_id=build_test_cycle iter=1 position=1 member=build rc=0 verdict=pass status=complete disposition=
ev 13:22:00 plugin.run.start 6.1.2 test plugin=test kind=tool
ev 13:22:05 prompt.summaries.injected 6.1.2 test stage=test stages=3 resolve=0 bytes=100
ev 13:40:00 cycle.iteration.reused "" "" cycle_id=build_test_cycle iter=2 member=build from_iter=1 reason=empty_diff
ev 13:40:00 cycle.iteration.reused "" "" cycle_id=build_test_cycle iter=2 member=test from_iter=1 reason=empty_diff
ev 14:00:00 plugin.run.start 7 review plugin=review kind=agent
ev 14:00:45 stage.fail "" "" stage=review rc=1                              # no seq: emitted after the unset
ev 14:10:00 plugin.run.start 8 pr-open plugin=pr-open kind=tool
ev 14:10:30 plugin.result 8 pr-open plugin=pr-open pr_url=https://github.com/testuser/testrepo/pull/7 pr_number=7
ev 14:10:31 stage.complete 8 pr-open stage=pr-open verdict=pass
ev 14:11:00 plugin.run.start 9 deploy plugin=deploy kind=agent

body="$(rsc_render_body "$EV" "$STATE")"

# ─── SPEC-1: marker + header ────────────────────────────────────────────────
assert_eq "[SPEC-1] first line is the hidden run marker" \
    '<!-- zbuild-run-status run_id=r-2131 -->' "$(sed -n 1p <<< "$body")"
assert_contains "[SPEC-1] header names the run id" "$body" 'run `r-2131`'
assert_contains "[SPEC-1] header names the issue" "$body" 'issue #90000042'
assert_contains "[SPEC-1] header names the engine sha (short)" "$body" 'engine `abcdef1`'
assert_contains "[SPEC-1] header shows started (Eastern, #2145)" "$body" 'started 8:00 AM ET'
assert_contains "[SPEC-1] header status is running without a terminal event" "$body" '**running**'
assert_contains "[SPEC-1] header carries the PR link" "$body" 'https://github.com/testuser/testrepo/pull/7'
assert_contains "[SPEC-1] header names the current stage" "$body" 'current: **9 deploy**'

# ─── SPEC-2: rows, newest first ─────────────────────────────────────────────
row_line() { grep -n -F -- "$1" <<< "$body" | grep -v 'current:' | cut -d: -f1 | sed -n 1p; }
row_of() { grep -F -- "$1" <<< "$body" | grep -v 'current:' | sed -n 1p; }
l_deploy="$(row_line '**9 deploy**')"; l_pr="$(row_line '**8 pr-open**')"
l_reused="$(row_line '**6.2 reused**')"; l_review="$(row_line '**7 review**')"
l_test="$(row_line '**6.1.2 test**')"; l_build="$(row_line '**6.1.1 build**')"; l_intake="$(row_line '**1 intake**')"
if [[ -n "$l_deploy" && -n "$l_pr" && -n "$l_reused" && -n "$l_review" && -n "$l_test" && -n "$l_build" && -n "$l_intake" \
      && "$l_deploy" -lt "$l_pr" && "$l_pr" -lt "$l_review" && "$l_review" -lt "$l_reused" \
      && "$l_reused" -lt "$l_test" && "$l_test" -lt "$l_build" && "$l_build" -lt "$l_intake" ]]; then
    assert_pass "[SPEC-2] rows render newest-first (deploy > pr-open > review > reused > test > build > intake)"
else
    assert_fail "[SPEC-2] rows render newest-first" "lines: deploy=$l_deploy pr=$l_pr reused=$l_reused review=$l_review test=$l_test build=$l_build intake=$l_intake"
fi
assert_eq "[SPEC-2] a nested plugin.run.start for the same seq opens no second row" \
    "1" "$(grep -c -F -- '**6.1.1 build**' <<< "$body")"

# ─── SPEC-3: row cells ──────────────────────────────────────────────────────
build_row="$(row_of '**6.1.1 build**')"
assert_eq "[SPEC-3] closed cycle-member row: start → end (duration) first, then seq, iter, verdict, summary first line (#2145)" \
    '**8:20 AM ET → 9:21 AM ET (61m33s)** · **6.1.1 build** · iter 1 · **pass** — 3 files changed, tests added' \
    "$build_row"
intake_row="$(row_of '**1 intake**')"
assert_eq "[SPEC-3] linear row: no iter, <1s for equal timestamps" \
    '**8:00 AM ET → 8:00 AM ET (<1s)** · **1 intake** · **pass** — adopted branch zbuild/issue-42' \
    "$intake_row"
test_row="$(row_of '**6.1.2 test**')"
assert_eq "[SPEC-3] open row: start, running, inputs, injected summaries count" \
    '**9:22 AM ET → running** · **6.1.2 test** · iter 1 · inputs: diff, plan · 3 stage summaries (0 RESOLVE)' \
    "$test_row"
deploy_row="$(row_of '**9 deploy**')"
assert_eq "[SPEC-3] open row without an injection: inputs only" \
    '**10:11 AM ET → running** · **9 deploy** · inputs: plan, design' \
    "$deploy_row"
review_row="$(row_of '**7 review**')"
assert_eq "[SPEC-3] a seq-less stage.fail closes the open row for that stage" \
    '**10:00 AM ET → 10:00 AM ET (45s)** · **7 review** · **fail rc=1**' \
    "$review_row"
reused_row="$(row_of '**6.2 reused**')"
assert_eq "[SPEC-3] reused members collapse to one row per iteration" \
    '**9:40 AM ET** · **6.2 reused** · iter 2 · build, test from iter 1 (empty_diff)' \
    "$reused_row"

# ─── SPEC-4: summary line is cut at 200 chars and `|` is escaped ────────────
long="$(printf 'x%.0s' $(seq 1 260))"
printf '## pr-open — pass\n\n- a|b %s\n' "$long" > "$STATE/artifacts/pr-open-summary.md"
body="$(rsc_render_body "$EV" "$STATE")"
pr_row="$(row_of '**8 pr-open**')"
summary_part="${pr_row#*— }"
assert_eq "[SPEC-4] summary cut at 200 chars (+ ellipsis)" "201" "${#summary_part}"
assert_contains "[SPEC-4] pipe escaped" "$pr_row" 'a\|b'

# ─── SPEC-5: terminal events drive the header ───────────────────────────────
ev 14:12:00 pipeline.aborted 9 deploy run_id=r-2131 issue=90000042 reason=llm_rate_limited "detail=LLM rate-limited — resets 12pm (UTC)" status=aborted stage=deploy
ev 14:12:00 pipeline.end "" "" status=aborted run_id=r-2131 issue=90000042
body="$(rsc_render_body "$EV" "$STATE")"
assert_contains "[SPEC-5] header status from pipeline.end" "$body" '**aborted**'
assert_contains "[SPEC-5] header carries the abort reason and detail" "$body" 'llm_rate_limited — LLM rate-limited — resets 12pm (UTC)'
assert_eq "[SPEC-5] no current stage once terminal" "0" "$(grep -c -F 'current: **' <<< "$body")"
assert_contains "[SPEC-5] the row killed mid-way keeps its start and inputs" "$body" \
    '**10:11 AM ET → running** · **9 deploy** · inputs: plan, design'

# ─── SPEC-6: the 60 KB bound ────────────────────────────────────────────────
BSTATE="$TEST_TEMP_DIR/bound"; BEV="$BSTATE/events.jsonl"
mkdir -p "$BSTATE/artifacts"; : > "$BEV"
long300="$(printf 'y%.0s' $(seq 1 300))"
EV="$BEV"
ev 10:00:00 pipeline.start "" "" run_id=r-big issue=1 engine_sha=0000000 engine_branch=main
for i in $(seq 1 400); do
    printf '## s%s — pass\n\n- %s\n' "$i" "$long300" > "$BSTATE/artifacts/s${i}-summary.md"
    ev 10:00:01 plugin.run.start "$i" "s$i" plugin="s$i" kind=tool
    ev 10:00:02 stage.complete "$i" "s$i" stage="s$i" verdict=pass
done
body="$(rsc_render_body "$BEV" "$BSTATE")"
bytes="$(LC_ALL=C; printf '%s' "$body" | wc -c | tr -d ' ')"
if [[ "$bytes" -lt 60000 ]]; then
    assert_pass "[SPEC-6] 400-row feed renders under 60,000 bytes ($bytes)"
else
    assert_fail "[SPEC-6] 400-row feed renders under 60,000 bytes" "got $bytes"
fi
assert_contains "[SPEC-6] newest row present" "$body" '**400 s400**'
assert_eq "[SPEC-6] oldest row omitted" "0" "$(grep -c -F -- '**1 s1**' <<< "$body")"
omit_line="$(grep -F 'earlier rows omitted' <<< "$body")"
assert_contains "[SPEC-6] omission line is the last line" "$(tail -1 <<< "$body")" 'earlier rows omitted — see run log'
rendered="$(grep -c -E '· \*\*[0-9]+ s[0-9]+\*\*' <<< "$body")"
omitted="$(sed -E 's/.*… ([0-9]+) earlier rows omitted.*/\1/' <<< "$omit_line")"
assert_eq "[SPEC-6] omitted count + rendered rows == 400" "400" "$(( rendered + omitted ))"

# rsc_byte_len counts BYTES under any locale (the GitHub limit is bytes).
assert_eq "[SPEC-6] rsc_byte_len counts bytes, not characters" "14" "$(rsc_byte_len 'héllo — ✓')"

# ─── SPEC-7: outbound redaction through the scope manifest ──────────────────
apply_scope_redaction() { printf 'REDACTED-BODY' > "$2"; return 0; }
printf 'scope\n' > "$STATE/scope-manifest.md"
red="$(rsc_outbound_body "$EV" "$STATE")"; rc=$?
assert_eq "[SPEC-7] body passes apply_scope_redaction when a scope manifest exists" "REDACTED-BODY" "$red"
apply_scope_redaction() { return 1; }
red="$(rsc_outbound_body "$EV" "$STATE")"; rc=$?
assert_eq "[SPEC-7] redactor failure → non-zero, nothing rendered" "1" "$rc"
assert_eq "[SPEC-7] redactor failure → empty output" "" "$red"
rm -f "$STATE/scope-manifest.md"
unset -f apply_scope_redaction

# ─── SPEC-9 (#2154): a closed row's summary is a snapshot, not a live re-read ─
# On #1840 run 5 iteration 2 overwrote spec-correspondence-summary.md and
# build-summary.md, and the iteration-1 rows silently changed. The comment is
# the run's record: what a stage reported when it closed stays.
print_test_section "SPEC-9: a closed row keeps the summary it closed with"
EV="$STATE/events.jsonl"   # SPEC-6 pointed EV at the bound fixture
printf '## build — pass\n\n- OVERWRITTEN by iteration 2\n' > "$STATE/artifacts/build-summary.md"
body="$(rsc_render_body "$EV" "$STATE")"
assert_eq "[SPEC-9] the build row still says what it said when it closed" \
    '**8:20 AM ET → 9:21 AM ET (61m33s)** · **6.1.1 build** · iter 1 · **pass** — 3 files changed, tests added' \
    "$(row_of '**6.1.1 build**')"
_fresh="$(bash -c 'source "$1"; rsc_render_body "$2" "$3"' _ "$LIB" "$EV" "$STATE" 2>/dev/null | grep -F -- '**6.1.1 build**' | sed -n 1p)"
assert_contains "[SPEC-9] …and a fresh process (the post-run finalize) renders the same snapshot" "$_fresh" "3 files changed, tests added"
assert_file_exists "[SPEC-9] the snapshot lives with the run's state" "$STATE/status-comment-rows.json"
assert_eq "[SPEC-9] …keyed by the run id" "r-2131" "$(jq -r '.run_id // ""' "$STATE/status-comment-rows.json" 2>/dev/null)"
# A row that closed with NO summary on disk (the file came later) still reads live.
_probe_row="$(row_of '**7 review**')"
assert_eq "[SPEC-9] a row that closed without a summary is not frozen empty" \
    '**10:00 AM ET → 10:00 AM ET (45s)** · **7 review** · **fail rc=1**' "$_probe_row"
printf '## review — fail\n\n- late\tsummary\n' > "$STATE/artifacts/review-summary.md"
body="$(rsc_render_body "$EV" "$STATE")"
assert_contains "[SPEC-9] …and picks the summary up once it exists" "$(row_of '**7 review**')" $'late\tsummary'
# review on #2156: a tab inside a frozen line must survive the save + load
# round trip byte for byte (a fresh process reads the file).
_fresh_tab="$(bash -c 'source "$1"; rsc_render_body "$2" "$3"' _ "$LIB" "$EV" "$STATE" 2>/dev/null | grep -F -- '**7 review**' | sed -n 1p)"
assert_contains "[SPEC-9] a tab in a frozen summary round-trips through the snapshot file intact" "$_fresh_tab" $'late\tsummary'
# A snapshot from another run is ignored (a resumed run has its own comment).
jq -c '.run_id = "r-other" | .rows["6.1.1"] = "stale from another run"' "$STATE/status-comment-rows.json" > "$STATE/status-comment-rows.json.tmp" && mv "$STATE/status-comment-rows.json.tmp" "$STATE/status-comment-rows.json"
body="$(rsc_render_body "$EV" "$STATE")"
assert_contains "[SPEC-9] a snapshot for a different run id is not served" "$(row_of '**6.1.1 build**')" "OVERWRITTEN by iteration 2"
printf '## build — pass\n\n- 3 files changed, tests added\n' > "$STATE/artifacts/build-summary.md"

# ─── SPEC-10 (#2166): a row that closes AGAIN (a retry) re-freezes ──────────
# #1841: test-author timed out (error, 10m), the router retried, the retry
# succeeded — and the row read "complete — the model call failed": the first
# close froze the failure text and the second close could not replace it. A
# retry is a new close (new ended_ts); the snapshot follows the LAST close.
print_test_section "SPEC-10: a retried row keeps the summary of its LAST close"
jq -c '.run_id = "r-2131"' "$STATE/status-comment-rows.json" > "$STATE/status-comment-rows.json.tmp" && mv "$STATE/status-comment-rows.json.tmp" "$STATE/status-comment-rows.json"
body="$(rsc_render_body "$EV" "$STATE")"   # freeze the first close: "3 files changed, tests added"
ev 13:22:05 plugin.run.start 6.1.1 build plugin=build kind=agent          # the retry re-enters the same seq
printf '## build — pass\n\n- retried after the first attempt timed out\n' > "$STATE/artifacts/build-summary.md"
ev 13:40:00 stage.complete 6.1.1 build stage=build verdict=pass          # …and closes again, later
body="$(rsc_render_body "$EV" "$STATE")"
assert_contains "[SPEC-10] the row shows the summary of the retry, not the frozen first attempt" \
    "$(row_of '**6.1.1 build**')" "retried after the first attempt timed out"
assert_contains "[SPEC-10] …and the retry's end time" "$(row_of '**6.1.1 build**')" "→ 9:40 AM ET"
_fresh_retry="$(bash -c 'source "$1"; rsc_render_body "$2" "$3"' _ "$LIB" "$EV" "$STATE" 2>/dev/null | grep -F -- '**6.1.1 build**' | sed -n 1p)"
assert_contains "[SPEC-10] a fresh process serves the re-frozen line" "$_fresh_retry" "retried after the first attempt timed out"
printf '## build — pass\n\n- OVERWRITTEN again\n' > "$STATE/artifacts/build-summary.md"
body="$(rsc_render_body "$EV" "$STATE")"
assert_contains "[SPEC-10] the re-frozen line is a snapshot too (a later overwrite does not leak in)" \
    "$(row_of '**6.1.1 build**')" "retried after the first attempt timed out"

# ─── SPEC-8: the sidecar is a reader of events.jsonl, never a writer ────────
assert_eq "[SPEC-8] no eb_emit_event in the sidecar" "0" "$(grep -c 'eb_emit_event' "$LIB")"
assert_eq "[SPEC-8] the sidecar never sources the event bus" "0" "$(grep -c 'event-bus' "$LIB")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
