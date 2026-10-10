#!/usr/bin/env bash
# Tests: the run-status comment sidecar as a PROCESS (#2131, ADR-064).
#
# Drives a live events.jsonl and watches the recording `gh`: no call before
# pipeline.start, the start row lands before any stage, bursts coalesce, a
# terminal event flushes at once but does not end the process (always-run
# stages emit after pipeline.end — the runner's trap reaps us), TERM and
# parent death both end with a final render.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-status-comment — sidecar loop (#2131)"
setup_test_env "rsc-loop"

LIB="$REPO_ROOT/scripts/lib/run-status-comment.sh"
GH_LOG="$TEST_TEMP_DIR/gh.log"; GH_BODIES="$TEST_TEMP_DIR/bodies"; mkdir -p "$GH_BODIES"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
args="\$*"
# Body first, log line second: a test that waits on the log must find the body already there.
case "\$args" in *body=@*) f="\${args##*body=@}"; f="\${f%% *}"; n="\$(ls "$GH_BODIES" | wc -l | tr -d ' ')"; cp "\$f" "$GH_BODIES/body-\$((n+1)).txt" ;; esac
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$args" in
  "auth status"*) exit 0 ;;
  *--paginate*) echo '[]'; exit 0 ;;
  *"-X PATCH"*) echo '{}'; exit 0 ;;
  *issues/*/comments*) echo 4242; exit 0 ;;
esac
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

export ZBUILD_STATUS_COMMENT_MIN_INTERVAL=2
export ZBUILD_STATUS_COMMENT_POLL=0.2
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5
unset NO_GITHUB

ev() {   # ev <events> <time> <type> [seq] [stage] [k=v...]
    local f="$1" t="$2" type="$3" seq="${4:-}" stage="${5:-}"; shift 5
    local data="{}" kv
    for kv in "$@"; do data="$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<< "$data")"; done
    jq -cn --arg ts "2026-09-17T${t}.000Z" --arg type "$type" --arg seq "$seq" --arg stage "$stage" --argjson data "$data" \
        '{ts:$ts, run_id:"r-loop", issue:90000042, type:$type, plugin:"", kind:"", data:$data, schema_version:1}
         + (if $stage != "" then {stage:$stage} else {} end) + (if $seq != "" then {seq:$seq} else {} end)' >> "$f"
}
posts() { grep -c -E '^api repos/testuser/testrepo/issues/90000042/comments' "$GH_LOG" 2>/dev/null || true; }
patches() { grep -c -- '-X PATCH' "$GH_LOG" 2>/dev/null || true; }
last_body() { ls "$GH_BODIES"/body-*.txt 2>/dev/null | sort -t- -k2 -n | tail -1 | xargs cat 2>/dev/null; }
# #2191-class flake: the gh stub logs the PATCH line and copies its body in two
# steps, so "a PATCH was logged" does not mean "the body we want is there" — an
# earlier interval PATCH can land first. Wait for the body that says <text>.
wait_for_body() {   # <text> <tries> <interval>
    local i
    for (( i = 0; i < ${2:-50}; i++ )); do
        grep -qF -- "$1" <<< "$(last_body)" && return 0
        sleep "${3:-0.1}"
    done
    return 1
}
alive() { kill -0 "$1" 2>/dev/null; }
wait_gone() { local i; for (( i=0; i<50; i++ )); do alive "$1" || return 0; sleep 0.1; done; return 1; }

start_sidecar() {   # start_sidecar <state_dir> <parent_pid> → pid (a child of THIS shell, so `wait` works)
    bash "$LIB" --events "$1/events.jsonl" --state-dir "$1" --parent-pid "$2" \
        --slug testuser/testrepo --issue 90000042 --run-id r-loop >>"$1/status-comment.log" 2>&1 &
    pid=$!
}

# ─── SPEC-1: nothing before pipeline.start; then the start row lands ───────
S1="$TEST_TEMP_DIR/s1"; mkdir -p "$S1"; : > "$S1/events.jsonl"; : > "$GH_LOG"
sleep 3600 & PARENT=$!
start_sidecar "$S1" "$PARENT"
sleep 1
assert_eq "[SPEC-1] no gh call while events.jsonl is empty" "0" "$(posts)"
ev "$S1/events.jsonl" 12:00:00 pipeline.start "" "" run_id=r-loop issue=90000042 engine_sha=abc1234 engine_branch=main
if wait_for_event "$GH_LOG" '^api repos/testuser/testrepo/issues/90000042/comments' 30 0.1; then
    assert_pass "[SPEC-1] pipeline.start → POST within 3s (the run is visible before any stage)"
else
    assert_fail "[SPEC-1] pipeline.start → POST within 3s" "log: $(cat "$GH_LOG" 2>/dev/null)"
fi
assert_contains "[SPEC-1] posted body carries the marker" "$(last_body)" 'zbuild-run-status run_id=r-loop'
assert_contains "[SPEC-1] posted body header says running" "$(last_body)" '**running**'

# ─── SPEC-2: a burst coalesces ──────────────────────────────────────────────
: > "$GH_LOG"
for i in 1 2 3; do
    ev "$S1/events.jsonl" "12:0$i:00" plugin.run.start "$i" "s$i" plugin="s$i" kind=tool
    ev "$S1/events.jsonl" "12:0$i:30" stage.complete "$i" "s$i" stage="s$i" verdict=pass
done
# Wait for the body that shows the newest row, not a fixed sleep: under coverage
# tracing the sidecar is several times slower (#2191-class flake, CI 2026-09-25).
wait_for_body '**3 s3**' 200 0.1 || true
n="$(patches)"
# Coalescing means fewer PATCHes than events — on a slow runner the burst can
# straddle an interval, so the bound is "not one per event", not "1–2".
if [[ "$n" -ge 1 && "$n" -lt 6 ]]; then
    assert_pass "[SPEC-2] 6 events in a burst → $n PATCH(es), not 6"
else
    assert_fail "[SPEC-2] 6 events in a burst coalesce" "got $n PATCHes"
fi
assert_contains "[SPEC-2] the latest PATCH has the newest row on top" "$(last_body | grep -E '^\*\*' | sed -n 1p)" '**3 s3**'

# ─── SPEC-3: an open row survives a KILL of the sidecar ─────────────────────
ev "$S1/events.jsonl" 12:10:00 plugin.run.start 4 build plugin=build kind=agent
wait_for_body '**4 build**' 200 0.1 || true   # posted, however slow the runner
kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
assert_contains "[SPEC-3] the body on GitHub already had the running row (start before end)" "$(last_body)" '**8:10 AM ET → running** · **4 build**'

# ─── SPEC-4: terminal flushes immediately and the process stays alive ──────
# This sidecar's gap between edits is an hour, so the only way an edit can
# follow pipeline.end is the flush-at-once rule — the wait can then be generous
# without weakening the check. (It used to sleep past a 2 s gap and demand an
# edit within 1.5 s: an ordinary timed edit passed it, and suite load failed it
# — #2258.)
S2="$TEST_TEMP_DIR/s2"; mkdir -p "$S2"; : > "$S2/events.jsonl"; : > "$GH_LOG"; rm -f "$GH_BODIES"/*
ev "$S2/events.jsonl" 13:00:00 pipeline.start "" "" run_id=r-loop issue=90000042 engine_sha=abc1234 engine_branch=main
ZBUILD_STATUS_COMMENT_MIN_INTERVAL=3600 start_sidecar "$S2" "$PARENT"
wait_for_event "$GH_LOG" '^api repos/testuser/testrepo/issues/90000042/comments' 30 0.1
ev "$S2/events.jsonl" 13:00:05 plugin.run.start 1 intake plugin=intake kind=agent
ev "$S2/events.jsonl" 13:00:06 stage.complete 1 intake stage=intake verdict=pass
: > "$GH_LOG"
ev "$S2/events.jsonl" 13:00:07 pipeline.end "" "" status=success run_id=r-loop issue=90000042
if wait_for_event "$GH_LOG" 'X PATCH' 200 0.1; then
    assert_pass "[SPEC-4] pipeline.end → PATCH without waiting out the gap between edits"
else
    assert_fail "[SPEC-4] pipeline.end → PATCH without waiting out the gap between edits" "no PATCH"
fi
wait_for_body '**success**' 100 0.1 || true
assert_contains "[SPEC-4] final header says success" "$(last_body)" '**success**'
if alive "$pid"; then
    assert_pass "[SPEC-4] the sidecar is still alive after the terminal event (always-run stages come later)"
else
    assert_fail "[SPEC-4] the sidecar is still alive after the terminal event" "exited"
fi
# An always-run stage after pipeline.end: the hour-long gap holds its timed
# edit back, so SPEC-5's final render is where it must land.
ev "$S2/events.jsonl" 13:00:08 plugin.run.start 9 persist plugin=persist kind=tool
ev "$S2/events.jsonl" 13:00:09 stage.complete 9 persist stage=persist verdict=pass

# ─── SPEC-5: TERM → final render, exit 0 ────────────────────────────────────
: > "$GH_LOG"
kill -TERM "$pid"
if wait_gone "$pid"; then
    wait "$pid" 2>/dev/null; rc=$?
    assert_pass "[SPEC-5] TERM ends the sidecar within 5s"
    assert_eq "[SPEC-5] exit status 0 on TERM" "0" "$rc"
else
    assert_fail "[SPEC-5] TERM ends the sidecar within 5s" "still alive"; kill -KILL "$pid" 2>/dev/null
fi
assert_eq "[SPEC-5] TERM produced one final PATCH" "1" "$(patches)"
assert_contains "[SPEC-5] final body keeps the terminal status from the events" "$(last_body)" '**success**'
assert_contains "[SPEC-5] a stage after pipeline.end lands in the final render" "$(last_body)" '**9 persist**'

# ─── SPEC-6: TERM before any terminal event → interrupted ───────────────────
S3="$TEST_TEMP_DIR/s3"; mkdir -p "$S3"; : > "$S3/events.jsonl"; : > "$GH_LOG"; rm -f "$GH_BODIES"/*
ev "$S3/events.jsonl" 14:00:00 pipeline.start "" "" run_id=r-loop issue=90000042 engine_sha=abc1234 engine_branch=main
ev "$S3/events.jsonl" 14:00:01 plugin.run.start 1 build plugin=build kind=agent
start_sidecar "$S3" "$PARENT"
wait_for_event "$GH_LOG" '^api repos/testuser/testrepo/issues/90000042/comments' 30 0.1
kill -TERM "$pid"; wait_gone "$pid"; wait "$pid" 2>/dev/null
assert_contains "[SPEC-6] no terminal event + TERM → interrupted" "$(last_body)" '**interrupted**'
assert_contains "[SPEC-6] the running row keeps its start" "$(last_body)" '**10:00 AM ET → running** · **1 build**'

# ─── SPEC-7: parent death → final render, exit 0 ────────────────────────────
S4="$TEST_TEMP_DIR/s4"; mkdir -p "$S4"; : > "$S4/events.jsonl"; : > "$GH_LOG"; rm -f "$GH_BODIES"/*
ev "$S4/events.jsonl" 15:00:00 pipeline.start "" "" run_id=r-loop issue=90000042 engine_sha=abc1234 engine_branch=main
sleep 2 & SHORT=$!
start_sidecar "$S4" "$SHORT"
wait_for_event "$GH_LOG" '^api repos/testuser/testrepo/issues/90000042/comments' 30 0.1
wait "$SHORT" 2>/dev/null
if wait_gone "$pid"; then
    wait "$pid" 2>/dev/null; rc=$?
    assert_pass "[SPEC-7] parent death ends the sidecar"
    assert_eq "[SPEC-7] exit status 0 on parent death" "0" "$rc"
else
    assert_fail "[SPEC-7] parent death ends the sidecar" "still alive"; kill -KILL "$pid" 2>/dev/null
fi
assert_contains "[SPEC-7] final body names the cause" "$(last_body)" 'interrupted (runner exited without a terminal event)'

# ─── SPEC-8: --once renders and exits ───────────────────────────────────────
: > "$GH_LOG"
bash "$LIB" --events "$S4/events.jsonl" --state-dir "$S4" --parent-pid $$ \
    --slug testuser/testrepo --issue 90000042 --run-id r-loop --once; rc=$?
assert_eq "[SPEC-8] --once exits 0" "0" "$rc"
assert_eq "[SPEC-8] --once made exactly one gh write" "1" "$(( $(posts) + $(patches) ))"

# ─── SPEC-3 [#1806/SPEC-3]: last_size cursor updated after flush ─────────────
# After rsc_flush returns, the poll loop must update last_size to the current
# byte count of events.jsonl so that events written inside rsc_flush (e.g.
# redaction.applied via apply_scope_redaction) do not set dirty=1 and trigger
# a spurious second render.
S_SC3="$TEST_TEMP_DIR/s_sc3"; mkdir -p "$S_SC3"; : > "$S_SC3/events.jsonl"
: > "$GH_LOG"; rm -f "$GH_BODIES"/*

# gh mock: during a PATCH call, inject a fake event so events.jsonl grows
# while last_size is still the pre-flush value (simulating redaction.applied).
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
args="\$*"
case "\$args" in *body=@*) f="\${args##*body=@}"; f="\${f%% *}"; n="\$(ls "$GH_BODIES" | wc -l | tr -d ' ')"; cp "\$f" "$GH_BODIES/body-\$((n+1)).txt" ;; esac
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$args" in
  "auth status"*) exit 0 ;;
  *--paginate*) echo '[]'; exit 0 ;;
  *"-X PATCH"*)
    printf '%s\n' '{"ts":"2026-10-10T00:00:00.000Z","type":"redaction.applied","run_id":"r-loop","issue":90000042,"data":{},"schema_version":1}' >> "$S_SC3/events.jsonl"
    echo '{}'
    exit 0
    ;;
  *issues/*/comments*) echo 4242; exit 0 ;;
esac
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

ev "$S_SC3/events.jsonl" 23:00:00 pipeline.start "" "" run_id=r-loop issue=90000042 engine_sha=abc engine_branch=main
ZBUILD_STATUS_COMMENT_MIN_INTERVAL=2 start_sidecar "$S_SC3" "$PARENT"
wait_for_event "$GH_LOG" '^api repos/testuser/testrepo/issues/90000042/comments' 30 0.1 || true
ev "$S_SC3/events.jsonl" 23:00:01 stage.complete 1 build stage=build verdict=pass

# Wait for the first PATCH; the mock injects a byte into events.jsonl during it.
# Use a generous timeout: MIN_INTERVAL=2 means the PATCH fires ~2s after the POST;
# 120*0.1=12s leaves 10s of margin on a loaded CI runner.
if wait_for_event "$GH_LOG" 'X PATCH' 120 0.1; then
    assert_pass "[#1806/SPEC-3] first PATCH fired"
else
    assert_fail "[#1806/SPEC-3] first PATCH fired (setup)" "no PATCH in GH_LOG"
fi

# Reset: only count PATCHes that appear AFTER this point.
: > "$GH_LOG"

# Old code: last_size was set before the flush, file grew during it → dirty=1
# next interval → second PATCH.  New code: cursor updated after flush → dirty=0
# → no second PATCH within MIN_INTERVAL * 1.5.
sleep 3

_sc3_patches="$(patches)"
if [[ "$_sc3_patches" -eq 0 ]]; then
    assert_pass "[#1806/SPEC-3] no spurious PATCH after event injected during flush"
else
    assert_fail "[#1806/SPEC-3] no spurious PATCH after event injected during flush" \
        "got $_sc3_patches PATCH(es) — last_size cursor not updated after flush"
fi
# Sidecar must still be running — proves the loop has run at least one more poll
# cycle since the first PATCH, so the zero count above is not vacuously true.
if alive "$pid"; then
    assert_pass "[#1806/SPEC-3] sidecar still alive after no-spurious-PATCH window"
else
    assert_fail "[#1806/SPEC-3] sidecar still alive after no-spurious-PATCH window" \
        "sidecar exited — loop did not poll again"
fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

# ─── SPEC-4 [#1806/SPEC-4]: no PATCH when rendered body is byte-for-byte identical ──
S_SC4="$TEST_TEMP_DIR/s_sc4"; mkdir -p "$S_SC4"; : > "$S_SC4/events.jsonl"
: > "$GH_LOG"; rm -f "$GH_BODIES"/*

# Restore default gh mock (no injection).
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
args="\$*"
case "\$args" in *body=@*) f="\${args##*body=@}"; f="\${f%% *}"; n="\$(ls "$GH_BODIES" | wc -l | tr -d ' ')"; cp "\$f" "$GH_BODIES/body-\$((n+1)).txt" ;; esac
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$args" in
  "auth status"*) exit 0 ;;
  *--paginate*) echo '[]'; exit 0 ;;
  *"-X PATCH"*) echo '{}'; exit 0 ;;
  *issues/*/comments*) echo 4242; exit 0 ;;
esac
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

ev "$S_SC4/events.jsonl" 23:30:00 pipeline.start "" "" run_id=r-loop issue=90000042 engine_sha=abc engine_branch=main
ev "$S_SC4/events.jsonl" 23:30:01 stage.complete 1 build stage=build verdict=pass
ZBUILD_STATUS_COMMENT_MIN_INTERVAL=2 start_sidecar "$S_SC4" "$PARENT"
wait_for_event "$GH_LOG" '^api repos/testuser/testrepo/issues/90000042/comments' 30 0.1 || true

# Wait for the first PATCH (MIN_INTERVAL=2 after pipeline.start POST).
# 120*0.1=12s: generous enough for a loaded CI runner.
if wait_for_event "$GH_LOG" 'X PATCH' 120 0.1; then
    assert_pass "[#1806/SPEC-4] first PATCH fired"
else
    assert_fail "[#1806/SPEC-4] first PATCH fired (setup)" "no PATCH in GH_LOG"
fi

# Append an event that rsc_rows_json does not render — the body is unchanged.
: > "$GH_LOG"
printf '%s\n' '{"ts":"2026-10-10T00:00:01.000Z","type":"redaction.applied","run_id":"r-loop","issue":90000042,"data":{},"schema_version":1}' \
    >> "$S_SC4/events.jsonl"

# Wait long enough for dirty=1 to be processed (file grew) and a second flush
# to fire if rsc_upsert is not guarded by a body comparison.
sleep 4

_sc4_patches="$(patches)"
# Sidecar must still be alive: proves the loop polled at least once during the
# window, so the zero-PATCH result is not vacuously true (sidecar did not exit).
if alive "$pid"; then
    assert_pass "[#1806/SPEC-4] sidecar still alive after identical-body window (loop ran)"
else
    assert_fail "[#1806/SPEC-4] sidecar still alive after identical-body window" \
        "sidecar exited — cannot prove body-unchanged flush was attempted"
fi
if [[ "$_sc4_patches" -eq 0 ]]; then
    assert_pass "[#1806/SPEC-4] no PATCH when rendered body is identical to previous flush"
else
    assert_fail "[#1806/SPEC-4] no PATCH when body is identical" \
        "got $_sc4_patches PATCH(es) — rsc_upsert was called with an unchanged body"
fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

# ─── SPEC-5 [#1806/SPEC-5]: sidecar events carry stage=run-status-comment ────
# Every emit_event call from the sidecar process must include stage=run-status-comment
# in the envelope.  In the old code emit_event is a no-op stub; in the new code
# the sidecar sources event-bus and exports ZBUILD_CURRENT_STAGE=run-status-comment.
S_SC5="$TEST_TEMP_DIR/s_sc5"; mkdir -p "$S_SC5"; : > "$S_SC5/events.jsonl"
SC5_EVENTS="$TEST_TEMP_DIR/sc5-events.jsonl"; : > "$SC5_EVENTS"
: > "$GH_LOG"; rm -f "$GH_BODIES"/*

# scope-manifest.md triggers apply_scope_redaction during rsc_outbound_body;
# apply_scope_redaction calls emit_event("redaction.applied"), which (new code)
# writes to SC5_EVENTS.  "` + ./`" allows every path so redaction succeeds.
printf '+ ./\n' > "$S_SC5/scope-manifest.md"

ev "$S_SC5/events.jsonl" 23:45:00 pipeline.start "" "" run_id=r-loop issue=90000042 engine_sha=abc engine_branch=main

# Start sidecar with its own ZBUILD_EVENTS_JSONL so its emits go to SC5_EVENTS
# and do not mix with the events.jsonl the sidecar reads.
ZBUILD_EVENTS_JSONL="$SC5_EVENTS" ZBUILD_EVENTS_DB="/dev/null" ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR" \
ZBUILD_STATUS_COMMENT_MIN_INTERVAL=2 \
    bash "$LIB" --events "$S_SC5/events.jsonl" --state-dir "$S_SC5" --parent-pid "$PARENT" \
    --slug testuser/testrepo --issue 90000042 --run-id r-loop >>"$S_SC5/status-comment.log" 2>&1 &
pid=$!

# The first flush fires immediately (flushed_once=0); apply_scope_redaction runs
# and calls emit_event — must be in SC5_EVENTS before the POST is logged.
if wait_for_event "$GH_LOG" '^api repos/testuser/testrepo/issues/90000042/comments' 30 0.1; then
    assert_pass "[#1806/SPEC-5] initial POST fired (apply_scope_redaction ran)"
else
    assert_fail "[#1806/SPEC-5] initial POST fired" "no POST — apply_scope_redaction may have failed"
fi

# Old code: emit_event is a stub → SC5_EVENTS stays empty → count == 0.
# New code: event-bus sourced + ZBUILD_CURRENT_STAGE=run-status-comment →
#           SC5_EVENTS has at least one event.
_sc5_event_count=0
if [[ -f "$SC5_EVENTS" ]]; then
    _sc5_event_count="$(grep -c '' "$SC5_EVENTS" 2>/dev/null || true)"
fi
if [[ "$_sc5_event_count" -gt 0 ]]; then
    assert_pass "[#1806/SPEC-5] sidecar emitted at least one event to its events file"
else
    assert_fail "[#1806/SPEC-5] sidecar emitted at least one event" \
        "SC5_EVENTS is empty — emit_event is still a stub"
fi

# Every emitted event must carry stage="run-status-comment".
if [[ "$_sc5_event_count" -gt 0 ]]; then
    _sc5_bad="$(jq -c 'select(.stage != "run-status-comment")' "$SC5_EVENTS" 2>/dev/null | grep -c '' || true)"
    if [[ "$_sc5_bad" -eq 0 ]]; then
        assert_pass "[#1806/SPEC-5] all sidecar events carry stage=run-status-comment"
    else
        assert_fail "[#1806/SPEC-5] all sidecar events carry stage=run-status-comment" \
            "$_sc5_bad event(s) missing the field"
    fi
fi

# The SPEC calls out "including redaction.applied" explicitly: verify at least one
# redaction.applied event was emitted to SC5_EVENTS (not left in a different file).
# Old code (stub emit_event) never writes to SC5_EVENTS → this fails on old code.
if grep -qF '"redaction.applied"' "$SC5_EVENTS" 2>/dev/null; then
    assert_pass "[#1806/SPEC-5] sidecar emitted at least one redaction.applied event"
else
    assert_fail "[#1806/SPEC-5] sidecar emitted at least one redaction.applied event" \
        "no redaction.applied found in SC5_EVENTS — the '(including redaction.applied)' condition not met"
fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

kill "$PARENT" 2>/dev/null; wait "$PARENT" 2>/dev/null
cleanup_test_env
print_test_results
exit $((FAIL > 0))
