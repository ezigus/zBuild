#!/usr/bin/env bash
# tests/unit/claim-takeover-real-test.sh — the cross-machine stale takeover end
# to end with the real claim and takeover code; only gh is a fake, first on PATH
# (ADR-005 §3, #2533 review).
#
# The lens reviews on #2533 found: every claim test stubbed the age reader; the
# takeover looked up the engine's own folder's repository (empty in CI); one
# failed read fell back to the label's time and took over a live run; an old
# takeover note won every later takeover; and a note was left when nothing was
# taken over.
#
#   TR1 [change] a claim whose holder's comment GitHub last edited under
#                ZBUILD_CLAIM_STALE_S ago refuses, naming the holder and its age
#   TR2 [change] a stale one is taken over: a note names both runs, the claim is
#                released and taken, and the run says so (pipeline.claim.taken_over)
#   TR3 [change] two runs, one stale claim: a note posted after the claim's time
#                by another run first wins — this run refuses, deletes its own
#                note and releases nothing; an older note, or an untrusted one,
#                does not count
#   TR4 [change] a release that fails after the note is said, with an event; the
#                note is deleted; the run refuses
#   TR5 [change] a takeover library that cannot be loaded is said as such
#   TR6 [change] a comments read that fails refuses — never the label's time alone
#   TR7 [change] the claim is aged from the later of its holder's comment and its
#                label: a new label on an old comment is not stale
#   TR8 [change] no repository → refused, saying so; nothing is asked of repos//
#   TR9 [change] a tunable that is not a number falls back to its default
#   TR10 [change] a run with no status comment says its claim has no heartbeat
#   TR11 [change] a takeover note that cannot be posted refuses, releasing nothing
# The design's ids: DSHBT-3 TR1, DSHBT-4 TR2, DSHBT-5 TR7, DSHBT-15 TR11, DSHBT-16 TR5.
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
export ZBUILD_RUN_ID="run-tr" ZBUILD_CLAIM_MACHINE_ID="box-tr" ZBUILD_CLAIM_STALE_S=1800 GITHUB_REPOSITORY="o/r"
THEIRS="https://github.com/o/r/actions/runs/41"
ME="run_id=run-tr machine=box-tr pid=$$"

# The fake gh, for repository o/r only: the holder's run-status comment (edited
# at $F/hb), the notes posted ($F/notes, a JSON object a line), the label's
# events ($F/label), a failing comments list ($F/fail-comments).
cat > "$F/bin/gh" <<'GH'
#!/usr/bin/env bash
F="${FAKE_DIR:?}"; args="$*"; printf '%s\n' "$args" >> "$F/gh.log"
[[ "$args" == *"repos/o/r/"* ]] || { echo "fake gh: not repository o/r: $args" >&2; exit 1; }
case "$args" in
    *"-X DELETE"*)
        id="${args##*/comments/}"; id="${id%% *}"; printf '%s\n' "$id" >> "$F/deleted"
        jq -c --argjson i "$id" 'select(.id != $i)' "$F/notes" > "$F/notes.n" 2>/dev/null; mv "$F/notes.n" "$F/notes"
        printf '{}\n' ;;
    *"-f body="*)
        [[ -e "$F/fail-post" ]] && { echo "fake gh: HTTP 403" >&2; exit 1; }
        body="${args#*-f body=}"; n=$(( $(wc -l < "$F/notes" 2>/dev/null || echo 0) + 100 ))
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq -cn --arg b "$body" --arg t "$now" --argjson i "$n" \
            '{id:$i, user:{login:"github-actions[bot]"}, author_association:"", body:$b, created_at:$t, updated_at:$t}' >> "$F/notes"
        printf '{"id":%s}\n' "$n" ;;
    *"/comments"*)
        [[ -e "$F/fail-comments" ]] && { echo "fake gh: HTTP 502" >&2; exit 1; }
        holder="$(cat "$F/holder")"; hb="$(cat "$F/hb")"
        body="$(printf '<!-- zbuild-run-status run_id=old -->\n<!-- zbuild-holder: %s -->\nstill running — %s — now: build\n### zbuild run `old` · issue #9 · **running**' "$holder" "$hb")"
        { jq -cn --arg b "$body" --arg t "$hb" '{id:1, user:{login:"github-actions[bot]"}, author_association:"", body:$b, created_at:$t, updated_at:$t}'
          cat "$F/notes" 2>/dev/null; } | jq -cs '.' ;;
    *"/events"*)
        if [[ -s "$F/label" ]]; then jq -cn --arg t "$(cat "$F/label")" '[{event:"labeled", label:{name:"zbuild:claimed"}, created_at:$t}]'
        else printf '[]\n'; fi ;;
    *) printf '{}\n' ;;
esac
GH
chmod +x "$F/bin/gh"
export FAKE_DIR="$F" PATH="$F/bin:$PATH"
printf '%s' "$THEIRS" > "$F/holder"

# A claim coordinator: refuses with the holder until released; release rc from $F/rel-rc.
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
_note() {   # <created seconds ago> <by> [login] — another run's takeover note
    jq -cn --arg b "took over a stale claim from \`$THEIRS\` — by \`$2\`" --arg t "$(_iso_ago "$1")" --arg l "${3:-github-actions[bot]}" \
        '{id:50, user:{login:$l}, author_association:(if $l == "github-actions[bot]" then "" else "NONE" end), body:$b, created_at:$t, updated_at:$t}' >> "$F/notes"
}
_fresh() { rm -f "$F/free" "$F/notes" "$F/calls" "$F/rel-rc" "$F/gh.log" "$F/deleted" "$F/label" "$F/fail-comments" "$F/fail-post"; : > "$F/notes"
           : > "$ZBUILD_EVENTS_JSONL"; _ZBUILD_CLAIM_ACQUIRED=""; unset _ZBUILD_CLAIM_RETRIED; }
_acq() { _RC=0; zbuild_claim_acquire 9 "$STATE" > "$F/out" 2>&1 || _RC=$?; _OUT="$(cat "$F/out")"; }
_released() { grep -c '^release' "$F/calls" 2>/dev/null || true; }
_notes_left() { grep -c 'took over' "$F/notes" 2>/dev/null || true; }

print_test_section "TR1: a holder edited recently is not stale"
_fresh; _iso_ago 60 > "$F/hb"
_acq
assert_eq "[TR1][DSHBT-3] refused" "1" "$_RC"
assert_contains "[TR1] ...naming the holder, not stale yet" "$_OUT" "is held by $THEIRS (not stale yet"
assert_eq "[TR1] ...nothing posted, nothing released" "0 0" "$(_notes_left) $(_released)"

print_test_section "TR2: a stale claim is taken over"
_fresh; _iso_ago 4000 > "$F/hb"
_acq
assert_eq "[TR2][DSHBT-4] taken over" "0" "$_RC"
assert_contains "[TR2] the note names the stale holder and this run" "$(cat "$F/notes")" \
    "took over a stale claim from \`$THEIRS\` — by \`$ME\`"
assert_eq "[TR2] released once" "1" "$(_released)"
assert_contains "[TR2] the run says so" "$(cat "$ZBUILD_EVENTS_JSONL")" "pipeline.claim.taken_over"
assert_contains "[TR2] ...on stderr too" "$_OUT" "took over a stale claim from $THEIRS"

print_test_section "TR3: two runs, one stale claim"
_fresh; _iso_ago 4000 > "$F/hb"; _note 100 "https://github.com/o/r/actions/runs/77"
_acq
assert_eq "[TR3] another run's note, after the claim's time, came first → refused" "1" "$_RC"
assert_contains "[TR3] ...naming it" "$_OUT" "another run took over first: https://github.com/o/r/actions/runs/77"
assert_eq "[TR3] ...nothing released" "0" "$(_released)"
assert_eq "[TR3] ...and this run's note is deleted" "1" "$(_notes_left)"
_fresh; _iso_ago 4000 > "$F/hb"; _note 5000 "https://github.com/o/r/actions/runs/77"
_acq
assert_eq "[TR3] a note from before the claim's time does not count" "0" "$_RC"
_fresh; _iso_ago 4000 > "$F/hb"; _note 100 "https://github.com/o/r/actions/runs/77" someone
_acq
assert_eq "[TR3] a note from an untrusted author does not count" "0" "$_RC"

print_test_section "TR4: a release that fails after the note is said"
_fresh; _iso_ago 4000 > "$F/hb"; printf '1' > "$F/rel-rc"
_acq
assert_eq "[TR4] refused" "1" "$_RC"
assert_contains "[TR4] ...saying the release failed" "$_OUT" "releasing $THEIRS's claim failed"
assert_contains "[TR4] ...with an event" "$(cat "$ZBUILD_EVENTS_JSONL")" "pipeline.claim.takeover_failed"
assert_eq "[TR4] ...and the note is deleted" "0" "$(_notes_left)"

print_test_section "TR5: a takeover library that cannot be loaded is said"
_fresh; _iso_ago 4000 > "$F/hb"
BAD="$TEST_TEMP_DIR/badroot"; mkdir -p "$BAD/scripts/lib"; printf 'if then\n' > "$BAD/scripts/lib/claim-takeover.sh"
_out5="$( unset -f claim_age_v 2>/dev/null; unset _ZBUILD_CLAIM_TAKEOVER_LOADED
          _ZBUILD_ROOT="$BAD" zbuild_claim_acquire 9 "$STATE" 2>&1 )"; _rc5=$?
assert_eq "[TR5][DSHBT-16] refused" "1" "$_rc5"
assert_contains "[TR5] ...saying it could not be loaded" "$_out5" "claim-takeover.sh could not be loaded"

print_test_section "TR6: a comments read that fails refuses"
_fresh; _iso_ago 60 > "$F/hb"; _iso_ago 90000 > "$F/label"; : > "$F/fail-comments"
_acq
assert_eq "[TR6] refused" "1" "$_RC"
assert_contains "[TR6] ...saying GitHub could not be read" "$_OUT" "could not read the claim's age from GitHub"
assert_eq "[TR6] ...nothing posted, nothing released" "0 0" "$(_notes_left) $(_released)"

print_test_section "TR7: aged from the later of the comment and the label"
_fresh; _iso_ago 90000 > "$F/hb"; _iso_ago 120 > "$F/label"
_acq
assert_eq "[TR7][DSHBT-5] an old comment, a new label: not stale" "1" "$_RC"
assert_contains "[TR7] ...refused as not stale yet" "$_OUT" "not stale yet"

print_test_section "TR8: no repository"
_fresh; _iso_ago 4000 > "$F/hb"; NOREPO="$TEST_TEMP_DIR/norepo"; mkdir -p "$NOREPO"
_out8="$( cd "$NOREPO" && unset GITHUB_REPOSITORY && zbuild_claim_acquire 9 "$STATE" 2>&1 )"; _rc8=$?
assert_eq "[TR8] refused" "1" "$_rc8"
assert_contains "[TR8] ...saying which repository is unknown" "$_out8" "no repository to read the claim from"
_n8=0; [[ -f "$F/gh.log" ]] && _n8="$(grep -c 'repos//' "$F/gh.log" || true)"
assert_eq "[TR8] ...nothing asked of repos//" "0" "$_n8"

print_test_section "TR9: a tunable that is not a number"
_fresh; _iso_ago 60 > "$F/hb"
ZBUILD_CLAIM_STALE_S=30m _acq
assert_eq "[TR9] STALE_S=30m is the default, 1800: a 60 s old claim is not stale" "1" "$_RC"

print_test_section "TR11: a note that cannot be posted refuses"
_fresh; _iso_ago 4000 > "$F/hb"; : > "$F/fail-post"
_acq
assert_eq "[TR11][DSHBT-15] refused" "1" "$_RC"
assert_contains "[TR11] ...saying the note could not be posted" "$_OUT" "the takeover note could not be posted"
assert_eq "[TR11] ...nothing released" "0" "$(_released)"

print_test_section "TR10: a run with no status comment says its claim has no heartbeat"
assert_contains "[TR10] said" "$(_ZBUILD_CLAIM_ACQUIRED=9 zbuild_claim_heartbeat_say "" 2>&1)" "its claim has no heartbeat"
assert_eq "[TR10] ...not when it has one" "" "$(_ZBUILD_CLAIM_ACQUIRED=9 zbuild_claim_heartbeat_say 1234 2>&1)"
assert_eq "[TR10] ...nor when it holds no claim" "" "$(_ZBUILD_CLAIM_ACQUIRED="" zbuild_claim_heartbeat_say "" 2>&1)"
_rn="$(awk '/zbuild_claim_acquire "\$\{_runner_issue:-\}"/{p=1} p{print} p&&/zbuild_claim_heartbeat_say/{exit}' "$REPO_ROOT/core/pipeline/runner.sh")"
assert_contains "[TR10] the runner says it after the claim" "$_rn" 'zbuild_claim_heartbeat_say "$_RUNNER_STATUS_COMMENT_PID"'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
