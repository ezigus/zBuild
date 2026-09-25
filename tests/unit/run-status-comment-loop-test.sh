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
S2="$TEST_TEMP_DIR/s2"; mkdir -p "$S2"; : > "$S2/events.jsonl"; : > "$GH_LOG"; rm -f "$GH_BODIES"/*
ev "$S2/events.jsonl" 13:00:00 pipeline.start "" "" run_id=r-loop issue=90000042 engine_sha=abc1234 engine_branch=main
start_sidecar "$S2" "$PARENT"
wait_for_event "$GH_LOG" '^api repos/testuser/testrepo/issues/90000042/comments' 30 0.1
ev "$S2/events.jsonl" 13:00:05 plugin.run.start 1 intake plugin=intake kind=agent
ev "$S2/events.jsonl" 13:00:06 stage.complete 1 intake stage=intake verdict=pass
sleep 2.5                                             # let the interval elapse
: > "$GH_LOG"
ev "$S2/events.jsonl" 13:00:07 pipeline.end "" "" status=success run_id=r-loop issue=90000042
if wait_for_event "$GH_LOG" 'X PATCH' 15 0.1; then
    assert_pass "[SPEC-4] pipeline.end → PATCH within 1.5s"
else
    assert_fail "[SPEC-4] pipeline.end → PATCH within 1.5s" "no PATCH"
fi
wait_for_body '**success**' 100 0.1 || true
assert_contains "[SPEC-4] final header says success" "$(last_body)" '**success**'
if alive "$pid"; then
    assert_pass "[SPEC-4] the sidecar is still alive after the terminal event (always-run stages come later)"
else
    assert_fail "[SPEC-4] the sidecar is still alive after the terminal event" "exited"
fi
# An always-run stage after pipeline.end is still rendered.
: > "$GH_LOG"
ev "$S2/events.jsonl" 13:00:08 plugin.run.start 9 persist plugin=persist kind=tool
ev "$S2/events.jsonl" 13:00:09 stage.complete 9 persist stage=persist verdict=pass
wait_for_event "$GH_LOG" 'X PATCH' 40 0.1
wait_for_body '**9 persist**' 100 0.1 || true
assert_contains "[SPEC-4] a stage after pipeline.end still lands" "$(last_body)" '**9 persist**'

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

kill "$PARENT" 2>/dev/null; wait "$PARENT" 2>/dev/null
cleanup_test_env
print_test_results
exit $((FAIL > 0))
