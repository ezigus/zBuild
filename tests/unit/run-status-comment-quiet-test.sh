#!/usr/bin/env bash
# Tests: the run-status comment does not wake itself (#1806, ADR-064 §2).
#
# The sidecar re-renders when events.jsonl grows. Each render passes the body
# through apply_scope_redaction, and that used to append redaction.applied to
# the same events.jsonl (the sidecar reached the event bus through
# input-resolve.sh → verdict.sh), so every render scheduled the next one: about
# 1,500 events and 1,476 PATCHes in the #1802 run, for a comment that had not
# changed. These tests drive the real sidecar process with the real redactor
# and the run's event-bus environment exported, as the runner leaves it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-status-comment — the sidecar does not wake itself (#1806)"
setup_test_env "rsc-quiet"

LIB="$REPO_ROOT/scripts/lib/run-status-comment.sh"
GH_LOG="$TEST_TEMP_DIR/gh.log"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$*" in
  "auth status"*) exit 0 ;;
  *--paginate*) echo '[]'; exit 0 ;;
  *"-X PATCH"*) echo '{}'; exit 0 ;;
  *issues/*/comments*) echo 4242; exit 0 ;;
esac
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"
writes() { grep -c -E -e '-X PATCH' -e '^api repos/testuser/testrepo/issues/90000042/comments' "$GH_LOG" 2>/dev/null || true; }
patches() { grep -c -- '-X PATCH' "$GH_LOG" 2>/dev/null || true; }
size() { wc -c < "$1" | tr -d ' '; }

export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5
unset NO_GITHUB

# A state dir as the runner leaves it: the run's events, a scope manifest (so
# the real redactor runs), and the event bus pointed at this run's events.
new_state() {
    local s="$1"; mkdir -p "$s"
    printf '+ src/\n' > "$s/scope-manifest.md"
    jq -cn '{ts:"2026-10-10T12:00:00.000Z", run_id:"r-quiet", issue:90000042, type:"pipeline.start", plugin:"", kind:"", data:{run_id:"r-quiet", issue:"90000042", engine_sha:"abc1234", engine_branch:"main"}, schema_version:1}' > "$s/events.jsonl"
}
sidecar_env() {
    ZBUILD_EVENTS_DIR="$1" ZBUILD_EVENTS_JSONL="$1/events.jsonl" ZBUILD_EVENTS_DB=/dev/null \
    ZBUILD_RUN_ID=r-quiet ZBUILD_ISSUE=90000042 "${@:2}"
}

# ─── Q1: a render writes nothing to the run's events ─────────────────────────
print_test_section "Q1: rendering and redacting the comment adds no event"
S1="$TEST_TEMP_DIR/s1"; new_state "$S1"; : > "$GH_LOG"
_before="$(size "$S1/events.jsonl")"
sidecar_env "$S1" bash "$LIB" --events "$S1/events.jsonl" --state-dir "$S1" --parent-pid $$ \
    --slug testuser/testrepo --issue 90000042 --run-id r-quiet --once >/dev/null 2>&1
assert_eq "[#1806/Q1] the comment was posted (the render ran)" "1" "$(writes)"
assert_eq "[#1806/Q1] events.jsonl is byte-for-byte what it was" "$_before" "$(size "$S1/events.jsonl")"
assert_eq "[#1806/Q1] no redaction.applied from the sidecar" "0" \
    "$(grep -c '"redaction.applied"' "$S1/events.jsonl" || true)"

# ─── Q2: a render that changes nothing is not sent ──────────────────────────
print_test_section "Q2: an unchanged render is not sent again; a failed send is retried"
S2="$TEST_TEMP_DIR/s2"; new_state "$S2"; : > "$GH_LOG"
(
    # shellcheck source=../../scripts/lib/run-status-comment.sh
    source "$LIB"
    _rsc_no_events
    f() { rsc_flush "$S2/events.jsonl" "$S2" testuser/testrepo 90000042 r-quiet; }
    f; f                                   # POST, then the same render again
    jq -cn '{ts:"2026-10-10T12:00:05.000Z", run_id:"r-quiet", issue:90000042, type:"plugin.run.start", plugin:"intake", kind:"agent", data:{plugin:"intake", kind:"agent"}, schema_version:1, stage:"intake", seq:"1"}' >> "$S2/events.jsonl"
    f; f                                   # one PATCH for the new row, then nothing
)
assert_eq "[#1806/Q2] one POST, then one PATCH for the one real change" "2" "$(writes)"
assert_eq "[#1806/Q2] exactly one PATCH" "1" "$(patches)"
# A send that failed is not remembered: the same render goes out next time.
S2b="$TEST_TEMP_DIR/s2b"; new_state "$S2b"; : > "$GH_LOG"
FAILING="$TEST_TEMP_DIR/patch-fails"
(
    source "$LIB"
    _rsc_no_events
    eval "_real_$(declare -f rsc_comment_patch)"
    rsc_comment_patch() { [[ -f "$FAILING" ]] && return 1; _real_rsc_comment_patch "$@"; }
    f() { rsc_flush "$S2b/events.jsonl" "$S2b" testuser/testrepo 90000042 r-quiet; }
    f                                      # POST
    jq -cn '{ts:"2026-10-10T12:00:06.000Z", run_id:"r-quiet", issue:90000042, type:"plugin.run.start", plugin:"plan", kind:"agent", data:{plugin:"plan", kind:"agent"}, schema_version:1, stage:"plan", seq:"2"}' >> "$S2b/events.jsonl"
    : > "$FAILING"; f                      # the PATCH fails
    rm -f "$FAILING"; f                    # same render: must be sent now
) >/dev/null 2>&1
assert_eq "[#1806/Q2] a failed send is retried with the same body" "1" "$(patches)"

# ─── Q3: a running sidecar with nothing new to say stays quiet ──────────────
# The first render posts. Nothing else is appended by anyone. Three intervals
# later there must have been no second render's PATCH.
print_test_section "Q3: the live sidecar is not re-woken by its own render"
S3="$TEST_TEMP_DIR/s3"; new_state "$S3"; : > "$GH_LOG"
sleep 3600 & PARENT=$!
sidecar_env "$S3" env ZBUILD_STATUS_COMMENT_MIN_INTERVAL=1 ZBUILD_STATUS_COMMENT_POLL=0.2 \
    bash "$LIB" --events "$S3/events.jsonl" --state-dir "$S3" --parent-pid "$PARENT" \
    --slug testuser/testrepo --issue 90000042 --run-id r-quiet >>"$S3/status-comment.log" 2>&1 &
SIDECAR=$!
wait_for_event "$GH_LOG" '^api repos/testuser/testrepo/issues/90000042/comments' 50 0.1 || true
_after_first="$(size "$S3/events.jsonl")"
sleep 4
assert_eq "[#1806/Q3] the first render posted" "1" "$(grep -c -E '^api repos/testuser/testrepo/issues/90000042/comments' "$GH_LOG" || true)"
assert_eq "[#1806/Q3] no PATCH while nothing happened" "0" "$(patches)"
assert_eq "[#1806/Q3] events.jsonl did not grow" "$_after_first" "$(size "$S3/events.jsonl")"
# A real change still gets through.
jq -cn '{ts:"2026-10-10T12:00:05.000Z", run_id:"r-quiet", issue:90000042, type:"plugin.run.start", plugin:"intake", kind:"agent", data:{plugin:"intake", kind:"agent"}, schema_version:1, stage:"intake", seq:"1"}' >> "$S3/events.jsonl"
if wait_for_event "$GH_LOG" '[-]X PATCH' 50 0.1; then
    assert_pass "[#1806/Q3] a real event still updates the comment"
else
    assert_fail "[#1806/Q3] a real event still updates the comment" "no PATCH"
fi
kill -TERM "$SIDECAR" 2>/dev/null; wait "$SIDECAR" 2>/dev/null
kill "$PARENT" 2>/dev/null; wait "$PARENT" 2>/dev/null

cleanup_test_env
print_test_results
exit $((FAIL > 0))
