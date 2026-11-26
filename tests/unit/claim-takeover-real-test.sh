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
#   TR12 [change] (PR review) a note posted with no id in the reply refuses: it
#                could not be deleted, so the run does not go on with it
#   (#2616, ADR-005 §3 amended 2026-11-26: the coordinator owns the age and the
#   takeover; the age is on GitHub's clock; a takeover marks the old comment)
#   TR13 [change] "now" is GitHub's, from its reply: a claim stale by this
#                machine's clock but fresh by GitHub's is refused, and the reverse
#                is taken over
#   TR14 [change] after a takeover the old holder's run-status comment no longer
#                says "still running": it says the claim was taken over, and by
#                which run
#   TR15 [change] the engine holds no GitHub claim code: the coordinator declares
#                the takeover hook and holds its library
#   (review of #2616)
#   TR16 [change] GitHub's Date is read in any locale, and the mark's time is UTC
#                in any time zone
#   TR17 [change] the claim is this run's again before the old comment is marked
#                or the takeover said: one taken by another run in between is
#                refused, unmarked
#   TR18 [change] a coordinator with no takeover hook refuses, saying so
#   TR19 [change] a mark that cannot be made is said, and the takeover stands
# The design's ids: DSHBT-3 TR1, DSHBT-4 TR2, DSHBT-5 TR7, DSHBT-15 TR11, DSHBT-16 TR5.
# Since #2616 the coordinator is the real github-labels plugin, its labels in the
# local store (ZBUILD_CLAIM_BACKEND=local-fs) and every GitHub read and write of
# the takeover through the fake gh.
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
[[ "$args" == *"repos/o/r/"* || "$args" == *"repos/o/r" ]] || { echo "fake gh: not repository o/r: $args" >&2; exit 1; }
case "$args" in
    *"api -i repos/o/r "*|*"api -i repos/o/r")
        printf 'HTTP/2.0 200 OK\r\nDate: %s\r\nContent-Type: application/json\r\n\r\n{}\n' \
            "$(cat "$F/gh-now" 2>/dev/null || LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')" ;;  # determinism-ok: the fake's clock, a timestamp
    *"-X PATCH"*)
        [[ -e "$F/fail-patch" ]] && { echo "fake gh: HTTP 500" >&2; exit 1; }
        f="${args##*--input }"; f="${f%% *}"; cp "$f" "$F/patched"
        id="${args##*/comments/}"; printf '%s\n' "${id%% *}" > "$F/patched-id"; printf '{}\n' ;;
    *"-X DELETE"*)
        id="${args##*/comments/}"; id="${id%% *}"; printf '%s\n' "$id" >> "$F/deleted"
        jq -c --argjson i "$id" 'select(.id != $i)' "$F/notes" > "$F/notes.n" 2>/dev/null; mv "$F/notes.n" "$F/notes"
        printf '{}\n' ;;
    *"-f body="*)
        [[ -e "$F/fail-post" ]] && { echo "fake gh: HTTP 403" >&2; exit 1; }
        body="${args#*-f body=}"; n=$(( $(wc -l < "$F/notes" 2>/dev/null || echo 0) + 100 ))
        # GitHub stamps a note on its own clock: the fake's, when it has one.
        now="$(jq -rn --arg d "$(cat "$F/gh-now" 2>/dev/null)" '$d | strptime("%a, %d %b %Y %H:%M:%S GMT") | mktime | todate' 2>/dev/null)" \
            || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"  # determinism-ok: the fake's clock, a timestamp
        jq -cn --arg b "$body" --arg t "$now" --argjson i "$n" \
            '{id:$i, user:{login:"github-actions[bot]"}, author_association:"", body:$b, created_at:$t, updated_at:$t}' >> "$F/notes"
        if [[ -e "$F/no-id" ]]; then printf '{}\n'; else printf '{"id":%s}\n' "$n"; fi ;;
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

# The real coordinator (#2616): its labels in the local store, the label on
# issue 9 and the holder's comment there until released; a release fails when
# the store cannot be written ($F/rel-rc).
CR="$TEST_TEMP_DIR/plugins"; mkdir -p "$CR/claim-coordinator"
cp -R "$REPO_ROOT/plugins/claim-coordinator/github-labels" "$CR/claim-coordinator/"
rm -rf "$CR/claim-coordinator/github-labels/tests"
export ZBUILD_CLAIM_BACKEND=local-fs ZBUILD_CLAIM_STORE="$TEST_TEMP_DIR/store"
export ZBUILD_PLUGINS_ROOT="$CR"

_iso_ago() { local e=$(( $(date +%s) - $1 )); date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ; }  # determinism-ok: builds a test timestamp relative to now, measures nothing
_note() {   # <created seconds ago> <by> [login] — another run's takeover note
    jq -cn --arg b "took over a stale claim from \`$THEIRS\` — by \`$2\`" --arg t "$(_iso_ago "$1")" --arg l "${3:-github-actions[bot]}" \
        '{id:50, user:{login:$l}, author_association:(if $l == "github-actions[bot]" then "" else "NONE" end), body:$b, created_at:$t, updated_at:$t}' >> "$F/notes"
}
_fresh() { rm -f "$F/notes" "$F/rel-rc" "$F/gh.log" "$F/deleted" "$F/label" "$F/fail-comments" "$F/fail-post" "$F/no-id" "$F/gh-now" "$F/patched" "$F/patched-id" "$F/fail-patch"; : > "$F/notes"
           chmod -R u+w "$ZBUILD_CLAIM_STORE" 2>/dev/null; rm -rf "$ZBUILD_CLAIM_STORE"; mkdir -p "$ZBUILD_CLAIM_STORE/9"
           printf 'zbuild:claimed\n' > "$ZBUILD_CLAIM_STORE/9/labels.txt"
           printf '<!-- zbuild-run-status run_id=old -->\n<!-- zbuild-holder: %s -->\n' "$THEIRS" > "$ZBUILD_CLAIM_STORE/9/run-status-comment.txt"
           : > "$ZBUILD_EVENTS_JSONL"; _ZBUILD_CLAIM_ACQUIRED=""; unset _ZBUILD_CLAIM_RETRIED; }
# A release that fails: the store cannot be written.
_release_fails() { chmod a-w "$ZBUILD_CLAIM_STORE/9"; }
_acq() { _RC=0; zbuild_claim_acquire 9 "$STATE" > "$F/out" 2>&1 || _RC=$?; _OUT="$(cat "$F/out")"; chmod -R u+w "$ZBUILD_CLAIM_STORE" 2>/dev/null; }
# The old claim was released: the label went from the store (and, taken over, came back as this run's).
_released() { if [[ "$_RC" == 0 ]] || ! grep -qx 'zbuild:claimed' "$ZBUILD_CLAIM_STORE/9/labels.txt" 2>/dev/null; then echo 1; else echo 0; fi; }
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
_fresh; _iso_ago 4000 > "$F/hb"; _note 600 "https://github.com/o/r/actions/runs/77"
_acq
assert_eq "[TR3] a note older than the takeover's window (a run killed before it deleted it) does not count" "0" "$_RC"
_fresh; _iso_ago 4000 > "$F/hb"; _note 100 "https://github.com/o/r/actions/runs/77" someone
_acq
assert_eq "[TR3] a note from an untrusted author does not count" "0" "$_RC"

print_test_section "TR4: a release that fails after the note is said"
_fresh; _iso_ago 4000 > "$F/hb"; _release_fails
_acq
assert_eq "[TR4] refused" "1" "$_RC"
assert_contains "[TR4] ...saying the release failed" "$_OUT" "releasing $THEIRS's claim failed"
assert_contains "[TR4] ...with an event" "$(cat "$ZBUILD_EVENTS_JSONL")" "pipeline.claim.takeover_failed"
assert_eq "[TR4] ...and the note is deleted" "0" "$(_notes_left)"

print_test_section "TR5: a takeover library that cannot be loaded is said"
_fresh; _iso_ago 4000 > "$F/hb"
_t5="$CR/claim-coordinator/github-labels/lib/takeover.sh"; cp "$_t5" "$F/takeover.keep"; printf 'if then\n' > "$_t5"
_out5="$( unset -f claim_age_v 2>/dev/null; unset _ZBUILD_CLAIM_TAKEOVER_LOADED
          zbuild_claim_acquire 9 "$STATE" 2>&1 )"; _rc5=$?
cp "$F/takeover.keep" "$_t5"
assert_eq "[TR5][DSHBT-16] refused" "1" "$_rc5"
assert_contains "[TR5] ...saying it could not be loaded" "$_out5" "takeover.sh could not be loaded"

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

print_test_section "TR9b: a stale time too short for the heartbeat"
_fresh; _iso_ago 900 > "$F/hb"
ZBUILD_CLAIM_STALE_S=0 _acq
assert_eq "[TR9b] STALE_S=0 is raised to twice the heartbeat (1200 s): 900 s old is not stale" "1" "$_RC"
_fresh; _iso_ago 900 > "$F/hb"
ZBUILD_CLAIM_STALE_S=300 _acq
assert_eq "[TR9b] ...so is 300 against the 600 s heartbeat" "1" "$_RC"

print_test_section "TR12: a note posted with no id in the reply"
_fresh; _iso_ago 4000 > "$F/hb"; : > "$F/no-id"
_acq
assert_eq "[TR12] refused" "1" "$_RC"
assert_contains "[TR12] ...saying the note has no id" "$_OUT" "the takeover note was posted without an id"
assert_eq "[TR12] ...nothing released" "0" "$(_released)"

print_test_section "TR10: a run with no status comment says its claim has no heartbeat"
assert_contains "[TR10] said" "$(_ZBUILD_CLAIM_ACQUIRED=9 zbuild_claim_heartbeat_say "" 2>&1)" "its claim has no heartbeat"
assert_eq "[TR10] ...not when it has one" "" "$(_ZBUILD_CLAIM_ACQUIRED=9 zbuild_claim_heartbeat_say 1234 2>&1)"
assert_eq "[TR10] ...nor when it holds no claim" "" "$(_ZBUILD_CLAIM_ACQUIRED="" zbuild_claim_heartbeat_say "" 2>&1)"
_rn="$(awk '/zbuild_claim_acquire "\$\{_runner_issue:-\}"/{p=1} p{print} p&&/zbuild_claim_heartbeat_say/{exit}' "$REPO_ROOT/core/pipeline/runner.sh")"
assert_contains "[TR10] the runner says it after the claim" "$_rn" 'zbuild_claim_heartbeat_say "$_RUNNER_STATUS_COMMENT_PID"'

print_test_section "TR13: now is GitHub's"
_gh_now() { local e=$(( $(date +%s) - $1 )); LC_ALL=C date -u -d "@$e" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null || LC_ALL=C date -u -r "$e" '+%a, %d %b %Y %H:%M:%S GMT'; }  # determinism-ok: the fake's clock, a timestamp
_fresh; _iso_ago 4000 > "$F/hb"; _gh_now 3940 > "$F/gh-now"
_acq
assert_eq "[TR13] stale by this machine's clock, 60 s old by GitHub's → refused" "1" "$_RC"
assert_contains "[TR13] ...not stale yet" "$_OUT" "not stale yet: last seen 60s ago"
_fresh; _iso_ago 60 > "$F/hb"; _gh_now -4000 > "$F/gh-now"
_acq
assert_eq "[TR13] fresh by this machine's clock, stale by GitHub's → taken over" "0" "$_RC"
_fresh; _iso_ago 4000 > "$F/hb"; printf 'not a date\n' > "$F/gh-now"
_acq
assert_eq "[TR13] GitHub's time cannot be read → refused" "1" "$_RC"
assert_contains "[TR13] ...saying so" "$_OUT" "could not read GitHub's time"

print_test_section "TR14: the old holder's comment is marked"
_fresh; _iso_ago 4000 > "$F/hb"
_acq
assert_eq "[TR14] taken over" "0" "$_RC"
_p14="$(jq -r '.body' "$F/patched" 2>/dev/null)"
assert_eq "[TR14] the old holder's comment is the one edited" "1" "$(cat "$F/patched-id" 2>/dev/null)"
assert_contains "[TR14] ...the rest of it kept" "$_p14" "### zbuild run \`old\` · issue #9"
_lacks14p() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_lacks14p "[TR14] ...its holder line gone: a refusal never names a run that lost the claim" "$_p14" "<!-- zbuild-holder: $THEIRS -->"
_lacks14() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_lacks14 "[TR14] ...it no longer says still running" "$_p14" "still running —"
assert_contains "[TR14] ...it says the claim was taken over, by this run" "$_p14" "taken over — "
assert_contains "[TR14] ...naming this run" "$_p14" "by $ME"

print_test_section "TR15: the coordinator owns the takeover"
assert_contains "[TR15] the coordinator declares the takeover hook" \
    "$(cat "$REPO_ROOT/plugins/claim-coordinator/github-labels/manifest.yaml")" "takeover: claim_coordinator_takeover"
assert_file_exists "[TR15] ...and holds its library" "$REPO_ROOT/plugins/claim-coordinator/github-labels/lib/takeover.sh"
assert_file_not_exists "[TR15] the engine's library is gone" "$REPO_ROOT/scripts/lib/claim-takeover.sh"
_eng="$(grep -nE 'repos/|rsc_gh|gh api|claim_age_v|takeover_note' "$REPO_ROOT/core/claim/claim.sh" || true)"
assert_eq "[TR15] core/claim/claim.sh holds no GitHub claim code" "" "$_eng"

print_test_section "TR16: any locale, any time zone"
_fresh; _iso_ago 4000 > "$F/hb"
_RC=0; LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 TZ=America/Los_Angeles zbuild_claim_acquire 9 "$STATE" > "$F/out" 2>&1 || _RC=$?
assert_eq "[TR16] taken over under a German locale and a Pacific time zone" "0" "$_RC"
_w16="$(jq -r '.body' "$F/patched" 2>/dev/null | grep -o 'taken over — [0-9T:-]*Z' || true)"
_d16="$(date -u +%Y-%m-%dT%H)"  # determinism-ok: the hour now, to compare a timestamp with
assert_contains "[TR16] ...the mark's time is UTC" "$_w16" "taken over — $_d16"

print_test_section "TR17: the claim is this run's before the mark"
_fresh; _iso_ago 4000 > "$F/hb"
# Another run takes the label the moment the old claim is released.
_d17="$CR/claim-coordinator/github-labels/plugin.sh"; cp "$_d17" "$F/plugin.keep"
printf '%s\n' 'claim_coordinator_release() { printf "zbuild:claimed\n" > "$ZBUILD_CLAIM_STORE/9/labels.txt"; return 0; }' >> "$_d17"
_acq
cp "$F/plugin.keep" "$_d17"
assert_eq "[TR17] another run took the claim in between → refused" "1" "$_RC"
assert_file_not_exists "[TR17] ...the old comment is not marked" "$F/patched"
_lacks17() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_lacks17 "[TR17] ...and no takeover is said" "$(cat "$ZBUILD_EVENTS_JSONL")" "pipeline.claim.taken_over"

print_test_section "TR18: a coordinator with no takeover hook"
_fresh; _iso_ago 4000 > "$F/hb"
_CR18="$TEST_TEMP_DIR/plugins-nohook"; mkdir -p "$_CR18/claim-coordinator"
cp -R "$CR/claim-coordinator/github-labels" "$_CR18/claim-coordinator/"
grep -v 'takeover: claim_coordinator_takeover' "$CR/claim-coordinator/github-labels/manifest.yaml" > "$_CR18/claim-coordinator/github-labels/manifest.yaml"
ZBUILD_PLUGINS_ROOT="$_CR18" _acq
assert_eq "[TR18] refused" "1" "$_RC"
assert_contains "[TR18] ...saying the coordinator cannot judge a stale claim" "$_OUT" "cannot judge a stale claim"

print_test_section "TR19: a mark that cannot be made"
_fresh; _iso_ago 4000 > "$F/hb"; : > "$F/fail-patch"
_acq
assert_eq "[TR19] the takeover stands" "0" "$_RC"
assert_contains "[TR19] ...and the failed mark is said" "$_OUT" "could not be marked as taken over"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
