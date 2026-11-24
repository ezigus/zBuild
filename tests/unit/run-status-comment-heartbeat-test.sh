#!/usr/bin/env bash
# Tests: run-status comment heartbeat — DSHBT-1, DSHBT-2, DSHBT-13, DSHBT-14
# Heartbeat line in render, heartbeat timer in the sidecar loop, and
# rsc_holder_line_v compatibility with the new body layout (ADR-064, #2533).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "run-status comment heartbeat (#2533, ADR-064)"
setup_test_env "rsc-heartbeat"

LIB="$REPO_ROOT/scripts/lib/run-status-comment.sh"

# Source the library in-process for the render/holder tests
# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$LIB" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-13 (done): rsc_holder_line_v works when heartbeat line precedes ###
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-13 (done): rsc_holder_line_v with heartbeat line before ###"

# Given: a comment body with the layout marker → holder → heartbeat → ###
holder_body="<!-- zbuild-run-status run_id=test-13 -->
<!-- zbuild-holder: https://github.com/o/r/actions/runs/42 -->
still running — 2026-11-24T12:00:00Z — now: build
### zbuild run test-13 · issue #9999 · **running**
engine \`abc1234\` · started 8:00 AM ET · updated 12:00 PM ET
current: **1 build**"

# When: rsc_holder_line_v is called
holder_found=""
rsc_holder_line_v holder_found "$holder_body"
# Then: the holder is returned from the holder comment, heartbeat line does not interfere
assert_eq "[DSHBT-13] rsc_holder_line_v returns holder despite heartbeat line before ###" \
    "https://github.com/o/r/actions/runs/42" "$holder_found"

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-1, DSHBT-2, DSHBT-14: heartbeat timer in rsc_tail_loop
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-1/2/14: sidecar loop fires heartbeat PATCH with still-running line"

GH_LOG="$TEST_TEMP_DIR/gh.log"
GH_BODIES="$TEST_TEMP_DIR/bodies"
mkdir -p "$GH_BODIES"

# Mock gh: records every call, copies request body, returns minimal valid JSON.
# Paths are baked in at write time (double-quoted heredoc).
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
args="\$*"
case "\$args" in
    *body=@*)
        f="\${args##*body=@}"; f="\${f%% *}"
        n="\$(ls "$GH_BODIES" | wc -l | tr -d ' ')"
        cp "\$f" "$GH_BODIES/body-\$((n+1)).txt" 2>/dev/null || true
        ;;
esac
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$args" in
    "auth status"*)       exit 0 ;;
    *--paginate*)         printf '[]\n'; exit 0 ;;
    *"-X PATCH"*)         printf '{}\n'; exit 0 ;;
    *issues/*/comments*)  printf '7777\n'; exit 0 ;;
esac
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

# Fast settings: 1-second heartbeat, 0.1-second poll, no coalescing delay
export ZBUILD_CLAIM_HEARTBEAT_S=1
export ZBUILD_STATUS_COMMENT_POLL=0.1
export ZBUILD_STATUS_COMMENT_MIN_INTERVAL=0
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=10
unset NO_GITHUB

# Helper: event writer (matches the shape core/event-bus/event-bus.sh writes)
ev() {   # ev <events-file> <HH:MM:SS> <type> [seq] [stage] [k=v...]
    local f="$1" t="$2" type="$3" seq="${4:-}" stage="${5:-}"; shift 5
    local data="{}" kv
    for kv in "$@"; do
        data="$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<< "$data")"
    done
    jq -cn \
        --arg ts "2026-11-24T${t}.000Z" \
        --arg type "$type" \
        --arg seq "$seq" \
        --arg stage "$stage" \
        --argjson data "$data" \
        '{ts:$ts, run_id:"r-hb", issue:90000099, type:$type,
          plugin:"", kind:"", data:$data, schema_version:1}
         + (if $stage != "" then {stage:$stage} else {} end)
         + (if $seq != "" then {seq:$seq} else {} end)' >> "$f"
}

# Helper: count POSTs (new comments) to the issue
posts()   {
    grep -cF 'api repos/testuser/testrepo/issues/90000099/comments' "$GH_LOG" 2>/dev/null \
        || printf '0'
}
# Helper: count PATCHes (edits to existing comment)
patches() { grep -c 'PATCH' "$GH_LOG" 2>/dev/null || printf '0'; }
# Helper: get last body written
last_body() {
    local last
    last="$(ls "$GH_BODIES"/body-*.txt 2>/dev/null | sort -t- -k2 -n | tail -1)"
    [[ -n "$last" ]] && cat "$last" 2>/dev/null || printf ''
}
# Helper: first visible (non-comment, non-empty) line in a body
first_visible() {
    local line
    while IFS= read -r line; do
        [[ "$line" == "<!--"* ]] && continue
        [[ -z "$line" ]] && continue
        printf '%s' "$line"
        return
    done <<< "$1"
}
# Helper: start the sidecar as a child of THIS shell
start_sidecar() {   # <state_dir> → sets sidecar_pid
    bash "$LIB" \
        --events "$1/events.jsonl" \
        --state-dir "$1" \
        --parent-pid "$$" \
        --slug testuser/testrepo \
        --issue 90000099 \
        --run-id r-hb \
        >> "$1/status-comment.log" 2>&1 &
    sidecar_pid=$!
}
alive()     { kill -0 "$1" 2>/dev/null; }
wait_gone() {
    local i
    for (( i=0; i<80; i++ )); do alive "$1" || return 0; sleep 0.1; done
    return 1
}

# ─── Setup: state dir with pipeline events ─────────────────────────────────
SD="$TEST_TEMP_DIR/sd1"; mkdir -p "$SD"; : > "$SD/events.jsonl"; : > "$GH_LOG"
rm -f "$GH_BODIES"/body-*.txt 2>/dev/null || true

ev "$SD/events.jsonl" 12:00:00 pipeline.start "" "" \
    run_id=r-hb issue=90000099 engine_sha=abc1234 engine_branch=main
ev "$SD/events.jsonl" 12:00:01 pipeline.claim.acquired "" "" \
    holder="run_id=r-hb machine=testbox pid=1"
ev "$SD/events.jsonl" 12:00:02 plugin.run.start "1" "build" plugin=build kind=agent

# Start sidecar and wait for initial POST (pipeline.start triggers first flush)
start_sidecar "$SD"
if wait_for_event "$GH_LOG" 'issues/90000099/comments' 60 0.1; then
    assert_pass "[setup] pipeline.start triggers initial comment POST"
else
    assert_fail "[setup] pipeline.start triggers initial comment POST" "no POST within 6s"
    kill "$sidecar_pid" 2>/dev/null; wait "$sidecar_pid" 2>/dev/null
    cleanup_test_env; print_test_results; exit $((FAIL > 0))
fi

# Wait for all events (the stage start) to be processed and flushed
if wait_for_event "$GH_LOG" 'PATCH' 60 0.1; then
    sleep 0.3  # let body copy complete
fi

# Record state before heartbeat window; clear log and bodies
: > "$GH_LOG"; rm -f "$GH_BODIES"/body-*.txt 2>/dev/null || true
# Wait briefly for sidecar to finish any in-flight flush
sleep 0.5
# Clear again so only heartbeat-triggered writes are captured
: > "$GH_LOG"; rm -f "$GH_BODIES"/body-*.txt 2>/dev/null || true

# Wait up to 5 seconds for a heartbeat-triggered PATCH (no new events written)
# ZBUILD_CLAIM_HEARTBEAT_S=1, so the heartbeat should fire within ~1–2 seconds
if wait_for_event "$GH_LOG" 'PATCH' 50 0.1; then
    sleep 0.2   # let body copy complete
    heartbeat_body="$(last_body)"
    heartbeat_patch_count="$(patches)"
    heartbeat_post_count="$(posts)"
else
    heartbeat_body=""
    heartbeat_patch_count=0
    heartbeat_post_count=0
fi

# Kill sidecar before assertions to avoid racing writes
kill "$sidecar_pid" 2>/dev/null; wait_gone "$sidecar_pid"; wait "$sidecar_pid" 2>/dev/null || true

# ─── DSHBT-1: first visible line is `still running — ` ─────────────────────
# Given: run is in progress (pipeline.start seen, no terminal event, stage running)
# When: heartbeat timer fires in rsc_tail_loop
# Then: first visible line (after HTML comments) starts with `still running — `
# And:  it includes `— now: build` (the current stage)
fv="$(first_visible "$heartbeat_body")"
assert_contains_regex "[DSHBT-1] heartbeat body's first visible line starts with 'still running — '" \
    "$fv" "^still running — "
assert_contains "[DSHBT-1] heartbeat line includes ISO8601 timestamp (contains T...Z)" \
    "$fv" "T"
assert_contains "[DSHBT-1] heartbeat line names the current stage (now: build)" \
    "$fv" "now: build"

# ─── DSHBT-2: PATCH, not a new POST ─────────────────────────────────────────
# Given: heartbeat timer fires (ZBUILD_CLAIM_HEARTBEAT_S elapsed, dirty==0, seen_start==1)
# When: rsc_tail_loop forces a flush on the heartbeat timer
# Then: a PATCH is sent to the existing comment (rsc_upsert issues PATCH)
# And:  no new POST is made (the existing comment is updated in place)
if [[ "$heartbeat_patch_count" -ge 1 ]]; then
    assert_pass "[DSHBT-2] heartbeat triggers a PATCH even when no stage events changed"
else
    assert_fail "[DSHBT-2] heartbeat triggers a PATCH even when no stage events changed" \
        "no PATCH after heartbeat interval (got patches=$heartbeat_patch_count)"
fi
assert_eq "[DSHBT-2] no new POST during heartbeat (existing comment is updated, not re-created)" \
    "0" "$heartbeat_post_count"

# ─── DSHBT-14: exactly one `still running — ` line in the heartbeat body ─────
# Given: run is in progress; ZBUILD_CLAIM_HEARTBEAT_S has elapsed since last flush
# When: rsc_tail_loop calls rsc_flush → rsc_outbound_pages → rsc_render_header → rsc_upsert
# Then: body contains exactly one line starting with `still running — `
# And:  no prior heartbeat line from an earlier flush appears (body is built fresh each time)
hb_line_count=0
while IFS= read -r line; do
    case "$line" in
        "still running — "*) hb_line_count=$(( hb_line_count + 1 )) ;;
    esac
done <<< "$heartbeat_body"
assert_eq "[DSHBT-14] body contains exactly one 'still running — ' line" \
    "1" "$hb_line_count"

# Cleanup
unset ZBUILD_CLAIM_HEARTBEAT_S ZBUILD_STATUS_COMMENT_POLL ZBUILD_STATUS_COMMENT_MIN_INTERVAL
cleanup_test_env
print_test_results
exit $((FAIL > 0))
