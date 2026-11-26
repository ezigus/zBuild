#!/usr/bin/env bash
# tests/unit/claim-takeover-real-test.sh — the cross-machine stale takeover end
# to end with the real heartbeat reader and takeover code; only gh is a fake,
# first on PATH (ADR-005 §3, #2533 review).
#
# The lens review on #2533 run 45644128060 found every claim test stubbed
# rsc_heartbeat_find, so the heartbeat parsing never ran; and that a failed
# release after the note was posted left no trace. A second machine could also
# take over the same stale claim at the same moment.
#
#   TR1 [change] the heartbeat the status comment writes is the one the claim
#                reads: a fresh one refuses, naming the holder
#   TR2 [change] a stale one is taken over: the note names both runs, the
#                claim is released and taken
#   TR3 [change] two runs taking over the same stale claim: only the run whose
#                note came first goes on; the other refuses and releases nothing
#   TR4 [change] a release that fails after the note was posted is said, with
#                an event, and the run refuses
#   TR5 [change] a run-status library that cannot be loaded is said as such
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the stale takeover, end to end (#2533 review)"
setup_test_env "claim-takeover-real"
unset NO_GITHUB GITHUB_ACTIONS
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
_ZBUILD_ROOT="$REPO_ROOT"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/claim/claim.sh
source "$REPO_ROOT/core/claim/claim.sh"

STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE"
F="$TEST_TEMP_DIR/fake"; mkdir -p "$F/bin"
export ZBUILD_RUN_ID="run-tr" ZBUILD_CLAIM_MACHINE_ID="box-tr" ZBUILD_CLAIM_STALE_S=1800
THEIRS="https://github.com/o/r/actions/runs/41"

# The fake gh: the holder's run-status comment (its heartbeat $F/hb), the notes
# posted so far ($F/notes, one JSON object a line), and the label's events.
cat > "$F/bin/gh" <<'GH'
#!/usr/bin/env bash
F="${FAKE_DIR:?}"; args="$*"; printf '%s\n' "$args" >> "$F/gh.log"
case "$args" in
    *"-f body="*)
        body="${args#*-f body=}"
        jq -cn --arg b "$body" '{user:{login:"github-actions[bot]"}, author_association:"", body:$b}' >> "$F/notes"
        printf '{}\n' ;;
    *"/comments"*)
        hb="$(cat "$F/hb" 2>/dev/null)"
        holder="$(cat "$F/holder")"
        body="$(printf '<!-- zbuild-run-status run_id=old -->\n<!-- zbuild-holder: %s -->\nstill running — %s — now: build\n### zbuild run `old` · issue #9 · **running**' "$holder" "$hb")"
        { jq -cn --arg b "$body" '{user:{login:"github-actions[bot]"}, author_association:"", body:$b}'
          cat "$F/notes" 2>/dev/null; } | jq -cs '.' ;;
    *"/events"*) printf '[]\n' ;;
    *) printf '{}\n' ;;
esac
GH
chmod +x "$F/bin/gh"
export FAKE_DIR="$F" PATH="$F/bin:$PATH"
printf '%s' "$THEIRS" > "$F/holder"

# A claim coordinator: refuses with $THEIRS until released; release rc from $F/rel-rc.
CR="$TEST_TEMP_DIR/plugins"; D="$CR/claim-coordinator/stub"; mkdir -p "$D"
cat > "$D/manifest.yaml" <<'EOF'
id: claim-coordinator-stub
name: Stub claim coordinator
kind: claim-coordinator
version: 0.1.0
hooks:
  claim: stub_claim
  release: stub_release
  heartbeat: stub_heartbeat
  list_claims: stub_list
provides:
  role: claim-coordinator
  alias: stub
EOF
cat > "$D/plugin.sh" <<EOF
stub_claim() {
    printf 'claim\n' >> "$F/calls"
    if [[ -e "$F/free" ]]; then printf '{"acquired":true}\n'
    else printf '{"acquired":false,"holder":"%s"}\n' "\$(cat "$F/holder")"; fi
}
stub_release() { printf 'release\n' >> "$F/calls"; local rc; rc="\$(cat "$F/rel-rc" 2>/dev/null)"; [[ "\${rc:-0}" == 0 ]] && : > "$F/free"; return "\${rc:-0}"; }
stub_heartbeat() { return 0; }
stub_list() { printf '[]\n'; }
EOF
export ZBUILD_PLUGINS_ROOT="$CR"

_iso_ago() { local e=$(( $(date +%s) - $1 )); date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ; }  # determinism-ok: builds a test timestamp relative to now, measures nothing
_fresh() { rm -f "$F/free" "$F/notes" "$F/calls" "$F/rel-rc" "$F/gh.log"; : > "$ZBUILD_EVENTS_JSONL"; _ZBUILD_CLAIM_ACQUIRED=""; unset _ZBUILD_CLAIM_RETRIED; }
_acq() { _RC=0; zbuild_claim_acquire 9 "$STATE" > "$F/out" 2>&1 || _RC=$?; _OUT="$(cat "$F/out")"; }
_released() { grep -c '^release' "$F/calls" 2>/dev/null || true; }

print_test_section "TR1: the heartbeat written is the one read"
_fresh; _iso_ago 60 > "$F/hb"
_acq
assert_eq "[TR1] a fresh heartbeat refuses" "1" "$_RC"
assert_contains "[TR1] ...naming the holder, not stale yet" "$_OUT" "is held by $THEIRS (not stale yet)"
assert_eq "[TR1] ...nothing released" "0" "$(_released)"

print_test_section "TR2: a stale claim is taken over"
_fresh; _iso_ago 4000 > "$F/hb"
_acq
assert_eq "[TR2] taken over" "0" "$_RC"
assert_contains "[TR2] the note names the stale holder and this run" "$(cat "$F/notes" 2>/dev/null)" \
    "took over a stale claim from $THEIRS — by run_id=run-tr machine=box-tr"
assert_eq "[TR2] released once" "1" "$(_released)"

print_test_section "TR3: two runs, one stale claim — the first note wins"
_fresh; _iso_ago 4000 > "$F/hb"
jq -cn --arg b "took over a stale claim from $THEIRS — by https://github.com/o/r/actions/runs/77" \
    '{user:{login:"github-actions[bot]"}, author_association:"", body:$b}' > "$F/notes"
_acq
assert_eq "[TR3] another run's note came first → refused" "1" "$_RC"
assert_contains "[TR3] ...naming it" "$_OUT" "another run took over first: https://github.com/o/r/actions/runs/77"
assert_eq "[TR3] ...and nothing released" "0" "$(_released)"
_fresh; _iso_ago 4000 > "$F/hb"
jq -cn --arg b "took over a stale claim from $THEIRS — by https://github.com/o/r/actions/runs/77" \
    '{user:{login:"someone"}, author_association:"NONE", body:$b}' > "$F/notes"
_acq
assert_eq "[TR3] a note from an untrusted author does not count" "0" "$_RC"

print_test_section "TR4: a release that fails after the note is said"
_fresh; _iso_ago 4000 > "$F/hb"; printf '1' > "$F/rel-rc"
_acq
assert_eq "[TR4] refused" "1" "$_RC"
assert_contains "[TR4] ...saying the note was posted and the release failed" "$_OUT" \
    "posted the takeover note, but releasing $THEIRS's claim failed"
assert_contains "[TR4] ...with an event" "$(cat "$ZBUILD_EVENTS_JSONL")" "pipeline.claim.takeover_failed"

print_test_section "TR5: a library that cannot be loaded is said as such"
_fresh; _iso_ago 4000 > "$F/hb"
BAD="$TEST_TEMP_DIR/badroot"; mkdir -p "$BAD/scripts/lib"; printf 'if then\n' > "$BAD/scripts/lib/run-status-comment.sh"
_out5="$( unset _ZBUILD_RUN_STATUS_COMMENT_LOADED; unset -f rsc_takeover_note_post 2>/dev/null
          _ZBUILD_ROOT="$BAD" zbuild_claim_acquire 9 "$STATE" 2>&1 )"; _rc5=$?
assert_eq "[TR5] refused" "1" "$_rc5"
assert_contains "[TR5] ...saying the library could not be loaded" "$_out5" "run-status-comment.sh could not be loaded"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
