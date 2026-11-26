#!/usr/bin/env bash
# Tests: run-status comment heartbeat — DSHBT-1, DSHBT-2, DSHBT-13, DSHBT-17
# DSHBT-17 (#2533 review): the heartbeat the sidecar writes is the one the claim
# reads — rsc_heartbeat_at_v and rsc_heartbeat_find, run for real on a body the
# sidecar sent.
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
# DSHBT-13 (done): rsc_holder_find works when heartbeat line precedes ###
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-13 (done): rsc_holder_find with heartbeat line before ###"

# Given: a comment body with the layout marker → holder → heartbeat → ###
holder_body="<!-- zbuild-run-status run_id=test-13 -->
<!-- zbuild-holder: https://github.com/o/r/actions/runs/42 -->
still running — 2026-11-24T12:00:00Z — now: build
### zbuild run test-13 · issue #9999 · **running**
engine \`abc1234\` · started 8:00 AM ET · updated 12:00 PM ET
current: **1 build**"

# Mock rsc_gh to return a JSON array containing the comment body above;
# rsc_holder_find reads its response from $2 (the temp out-file).
# jq -rs slurps the array as [[item]], and .[][]? flattens it to items.
rsc_gh() {
    local _out="$2"
    jq -cn --arg body "$holder_body" \
        '[{"user":{"login":"github-actions[bot]"},"author_association":"","body":$body}]' \
        > "$_out"
    return 0
}

# When: rsc_holder_find is called
holder_found="$(rsc_holder_find "$TEST_TEMP_DIR" "o/r" 9999)"
# Then: the holder is returned from the holder comment, heartbeat line does not interfere
assert_eq "[DSHBT-13] rsc_holder_find returns holder despite heartbeat line before ###" \
    "https://github.com/o/r/actions/runs/42" "$holder_found"
# Then: rsc_holder_line_v itself returns the holder from the holder-comment line regardless
#       of the heartbeat line inserted after it
_rhlv_result=""
rsc_holder_line_v _rhlv_result "$holder_body"
assert_eq "[DSHBT-13] rsc_holder_line_v returns holder despite heartbeat line before ###" \
    "https://github.com/o/r/actions/runs/42" "$_rhlv_result"

# Cleanup: remove the rsc_gh override so the sidecar sections use the real binary path
unset -f rsc_gh

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-1, DSHBT-2: heartbeat timer in rsc_tail_loop
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-1/2: sidecar loop fires heartbeat PATCH with still-running line"

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
# grep -c exits 1 when count is 0, so capture in a variable and default to 0 on error.
posts() {
    local _c
    _c="$(grep -cF 'api repos/testuser/testrepo/issues/90000099/comments' "$GH_LOG" 2>/dev/null)" \
        || _c=0
    printf '%s' "$_c"
}
# Helper: count PATCHes (edits to existing comment)
patches() {
    local _c
    _c="$(grep -c 'PATCH' "$GH_LOG" 2>/dev/null)" || _c=0
    printf '%s' "$_c"
}
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
start_sidecar() {   # <state_dir> [<run_id>] → sets sidecar_pid
    bash "$LIB" \
        --events "$1/events.jsonl" \
        --state-dir "$1" \
        --parent-pid "$$" \
        --slug testuser/testrepo \
        --issue 90000099 \
        --run-id "${2:-r-hb}" \
        >> "$1/status-comment.log" 2>&1 &
    sidecar_pid=$!
}
# Helper: wait until a body has been sent (the fake gh copies it before it
# logs the call); a condition with a timeout, not a clock (ADR-012).
wait_body() {
    local i
    for (( i=0; i<${1:-60}; i++ )); do [[ -n "$(last_body)" ]] && return 0; sleep 0.1; done
    return 1
}
alive()     { kill -0 "$1" 2>/dev/null; }
wait_gone() {
    local i
    for (( i=0; i<80; i++ )); do alive "$1" || return 0; sleep 0.1; done
    return 1
}

# Given: a run is in progress (pipeline.start seen, plugin.run.start "build" fired, no terminal
#        event); ZBUILD_CLAIM_HEARTBEAT_S=1 so the heartbeat fires quickly in test
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

# Wait for the stage-start event to be processed and flushed (first PATCH after POST)
wait_for_event "$GH_LOG" 'PATCH' 60 0.1 || true
# Clear logs and bodies so only the heartbeat-triggered writes are captured below
: > "$GH_LOG"; rm -f "$GH_BODIES"/body-*.txt 2>/dev/null || true

# When: ZBUILD_CLAIM_HEARTBEAT_S seconds have elapsed since the last flush
#       (the heartbeat timer fires in rsc_tail_loop; no new stage events are written)
if wait_body 50 && wait_for_event "$GH_LOG" 'PATCH' 50 0.1; then
    heartbeat_body="$(last_body)"
    heartbeat_patch_count="$(patches)"
    heartbeat_post_count="$(posts)"
else
    heartbeat_body=""
    heartbeat_patch_count=0
    heartbeat_post_count=0
fi
kill "$sidecar_pid" 2>/dev/null; wait_gone "$sidecar_pid"; wait "$sidecar_pid" 2>/dev/null || true

# Then (DSHBT-1): the comment's first visible line is `still running — <ISO8601> — now: <stage>`
# And (DSHBT-1): a PATCH is sent even when no stage events changed since the last flush
fv="$(first_visible "$heartbeat_body")"
assert_contains_regex "[DSHBT-1] heartbeat body's first visible line starts with 'still running — '" \
    "$fv" "^still running — "
assert_contains_regex "[DSHBT-1] heartbeat line has ISO8601 timestamp (YYYY-MM-DDTHH:MM:SSZ format)" \
    "$fv" "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
assert_contains "[DSHBT-1] heartbeat line names the current stage (now: build)" \
    "$fv" "now: build"
if [[ "$heartbeat_patch_count" -ge 1 ]]; then
    assert_pass "[DSHBT-1] heartbeat triggers PATCH even when no stage events changed since last flush"
else
    assert_fail "[DSHBT-1] heartbeat triggers PATCH even when no stage events changed since last flush" \
        "no PATCH after heartbeat interval (got patches=$heartbeat_patch_count)"
fi

# Then (DSHBT-2): a PATCH is sent to the existing comment on GitHub with the updated body
# And (DSHBT-2): no new comment is POSTed to the issue
if [[ "$heartbeat_patch_count" -ge 1 ]]; then
    assert_pass "[DSHBT-2] heartbeat triggers a PATCH even when no stage events changed"
else
    assert_fail "[DSHBT-2] heartbeat triggers a PATCH even when no stage events changed" \
        "no PATCH after heartbeat interval (got patches=$heartbeat_patch_count)"
fi
assert_eq "[DSHBT-2] no new POST during heartbeat (existing comment is updated, not re-created)" \
    "0" "$heartbeat_post_count"

# Then (DSHBT-1): body contains exactly one line starting with `still running — `
# And (DSHBT-1): no prior heartbeat line from an earlier flush appears
hb_line_count=0
while IFS= read -r line; do
    case "$line" in
        "still running — "*) hb_line_count=$(( hb_line_count + 1 )) ;;
    esac
done <<< "$heartbeat_body"
assert_eq "[DSHBT-1] body contains exactly one 'still running — ' line" \
    "1" "$hb_line_count"

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-17 (#2533 review): the heartbeat written is the heartbeat read
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-17: the heartbeat the sidecar sent is the one the claim reads"
_hb17=""; rsc_heartbeat_at_v _hb17 "$heartbeat_body"
assert_contains_regex "[DSHBT-17] rsc_heartbeat_at_v reads the sent body's timestamp" \
    "$_hb17" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
assert_contains "[DSHBT-17] ...the one on its heartbeat line" "$fv" "still running — $_hb17"
rsc_gh() {   # the GitHub call's boundary: the comments list, holding the sent body
    jq -cn --arg body "$heartbeat_body" \
        '[{"user":{"login":"github-actions[bot]"},"author_association":"","body":$body}]' > "$2"
}
assert_eq "[DSHBT-17] rsc_heartbeat_find reads it back from the issue's comments" \
    "$_hb17" "$(rsc_heartbeat_find "$TEST_TEMP_DIR" testuser/testrepo 90000099)"
unset -f rsc_gh

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-1 (no-stage case): heartbeat writes `still running — <ISO8601>` without
# `— now: <stage>` when no stage event has fired
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-1 (no-stage): heartbeat line has no '— now:' when no stage is current"

# Given: run is in progress (pipeline.start seen, no terminal event, NO plugin.run.start)
SD2="$TEST_TEMP_DIR/sd2"; mkdir -p "$SD2"; : > "$SD2/events.jsonl"
: > "$GH_LOG"; rm -f "$GH_BODIES"/body-*.txt 2>/dev/null || true

ev "$SD2/events.jsonl" 12:00:00 pipeline.start "" "" \
    run_id=r-hb2 issue=90000099 engine_sha=abc1234 engine_branch=main
ev "$SD2/events.jsonl" 12:00:01 pipeline.claim.acquired "" "" \
    holder="run_id=r-hb2 machine=testbox2 pid=1"
# Note: no plugin.run.start event → current stage is empty

# When: the sidecar runs and the heartbeat timer fires (ZBUILD_CLAIM_HEARTBEAT_S=1)
start_sidecar "$SD2" "r-hb2"
if wait_for_event "$GH_LOG" 'issues/90000099/comments' 60 0.1; then
    assert_pass "[setup-ns] initial POST received for no-stage sidecar"
else
    assert_fail "[setup-ns] initial POST received for no-stage sidecar" "no POST within 6s"
    kill "$sidecar_pid" 2>/dev/null; wait "$sidecar_pid" 2>/dev/null
    cleanup_test_env; print_test_results; exit $((FAIL > 0))
fi
# No stage event means no event-triggered PATCH; clear log and wait only for heartbeat
: > "$GH_LOG"; rm -f "$GH_BODIES"/body-*.txt 2>/dev/null || true

ns_heartbeat_body=""
if wait_body 50 && wait_for_event "$GH_LOG" 'PATCH' 50 0.1; then
    ns_heartbeat_body="$(last_body)"
fi

kill "$sidecar_pid" 2>/dev/null; wait_gone "$sidecar_pid"; wait "$sidecar_pid" 2>/dev/null || true

# Then: first visible line starts with `still running — <ISO8601>` (no `— now:` suffix)
ns_fv="$(first_visible "$ns_heartbeat_body")"
assert_contains_regex "[DSHBT-1] no-stage: first visible line starts with 'still running — '" \
    "$ns_fv" "^still running — "
assert_contains_regex "[DSHBT-1] no-stage: first visible line has ISO8601 timestamp" \
    "$ns_fv" "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
# Assert the line does NOT contain `— now: <stage>` when no stage is current
if grep -qF "now:" <<< "$ns_fv"; then
    assert_fail "[DSHBT-1] no-stage: heartbeat line must NOT include '— now:' when no stage is current" \
        "found 'now:' in no-stage heartbeat line: $ns_fv"
else
    assert_pass "[DSHBT-1] no-stage: heartbeat line does not include '— now:' when no stage is current"
fi

# Cleanup
unset ZBUILD_CLAIM_HEARTBEAT_S ZBUILD_STATUS_COMMENT_POLL ZBUILD_STATUS_COMMENT_MIN_INTERVAL
cleanup_test_env
print_test_results
exit $((FAIL > 0))
