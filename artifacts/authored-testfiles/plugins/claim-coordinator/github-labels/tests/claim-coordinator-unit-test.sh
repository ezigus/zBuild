#!/usr/bin/env bash
# Tests: plugins/claim-coordinator/github-labels/plugin.sh — the claim and
# release hooks (ADR-005 §2, §4), on the local-fs store and on a mocked gh.
# The holder reader is in claim-holder-reader-unit-test.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../../../tests/lib/claim-gh-mock.sh
source "$REPO_ROOT/tests/lib/claim-gh-mock.sh"

print_test_header "plugin: claim-coordinator/github-labels — claim and release"
setup_test_env "claim-coordinator-unit"
unset NO_GITHUB

export ZBUILD_CLAIM_BACKEND="local-fs"
export ZBUILD_CLAIM_STORE="$TEST_TEMP_DIR/claim-store"
# shellcheck source=../plugin.sh
source "$REPO_ROOT/plugins/claim-coordinator/github-labels/plugin.sh"

# ── local-fs store: claim, release, list ─────────────────────────────────────
print_test_section "local-fs store"
labels_file="$ZBUILD_CLAIM_STORE/42/labels.txt"
set +e; reply="$(claim_coordinator_claim 42)"; rc=$?; set -e
assert_eq "claim → rc 0" "0" "$rc"
assert_eq "claim → acquired true" "true" "$(jq -r .acquired <<< "$reply")"
assert_eq "the label is exactly zbuild:claimed, with no machine name" "zbuild:claimed" "$(cat "$labels_file")"
set +e; reply="$(claim_coordinator_claim 42)"; rc=$?; set -e
assert_eq "a second claim on a claimed issue → acquired false" "false" "$(jq -r .acquired <<< "$reply")"
set +e; claim_coordinator_release 42; rc=$?; set -e
assert_eq "release → rc 0" "0" "$rc"
assert_eq "release removes zbuild:claimed" "" "$(cat "$labels_file")"
assert_eq "list_claims → [] after release" "[]" "$(claim_coordinator_list_claims)"
assert_eq "heartbeat → rc 0" "0" "$(claim_coordinator_heartbeat 42; echo $?)"

# ── gh backend ───────────────────────────────────────────────────────────────
export ZBUILD_CLAIM_BACKEND="gh"
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5 GITHUB_REPOSITORY="testowner/testrepo"
GHS="$TEST_TEMP_DIR/gh"
_gh_reset() { rm -rf "$GHS"; claim_gh_mock_install "$GHS"; }

print_test_section "gh: claim adds the shared label"
_gh_reset; : > "$GHS/repo-label"
set +e; reply="$(claim_coordinator_claim 7001)"; rc=$?; set -e
assert_eq "claim → rc 0" "0" "$rc"
assert_eq "claim → acquired true" "true" "$(jq -r .acquired <<< "$reply")"
assert_eq "the issue now carries exactly zbuild:claimed" "zbuild:claimed" "$(cat "$GHS/labels")"
assert_eq "every gh call names the repository" "$(wc -l < "$GHS/log" | tr -d ' ')" \
    "$(/usr/bin/grep -c -- '--repo testowner/testrepo' "$GHS/log" || true)"

print_test_section "gh: an add GitHub applied but whose answer was lost is a claim"
_gh_reset; : > "$GHS/repo-label"; : > "$GHS/add-then-fail"
set +e; reply="$(claim_coordinator_claim 7008 2>/dev/null)"; rc=$?; set -e
assert_eq "claim → rc 0" "0" "$rc"
assert_eq "…acquired true: the label this run added is this run's to release" "true" \
    "$(jq -r .acquired <<< "$reply" 2>/dev/null || echo unparsed)"

print_test_section "gh: a repository with no zbuild:claimed label gets one, once"
_gh_reset
set +e; reply="$(claim_coordinator_claim 7002 2>"$TEST_TEMP_DIR/err")"; rc=$?; set -e
assert_eq "claim → rc 0 once the label is created" "0" "$rc"
assert_eq "claim → acquired true" "true" "$(jq -r '.acquired' <<< "$reply" 2>/dev/null || echo unparsed)"
assert_eq "the label is created with --force (idempotent)" "1" \
    "$(/usr/bin/grep -c '^label create zbuild:claimed .*--force' "$GHS/log" || true)"
assert_eq "the add is tried twice: before and after the label exists" "2" \
    "$(/usr/bin/grep -c -- '--add-label zbuild:claimed' "$GHS/log" || true)"
assert_eq "the issue carries zbuild:claimed" "zbuild:claimed" "$(cat "$GHS/labels")"
assert_eq "…label create names the repository too" "1" \
    "$(/usr/bin/grep -c '^label create .*--repo testowner/testrepo' "$GHS/log" || true)"

print_test_section "gh: a claimed issue — the reply is valid JSON whatever the holder holds"
_gh_reset; : > "$GHS/repo-label"; printf 'zbuild:claimed\n' > "$GHS/labels"
_ccgl_read_holder() { printf 'run "x" \\ tab\there\x01bell'; }
set +e; reply="$(claim_coordinator_claim 7003)"; rc=$?; set -e
unset -f _ccgl_read_holder
# shellcheck source=../plugin.sh
_ZBUILD_CLAIM_GH_LABELS_LOADED="" source "$REPO_ROOT/plugins/claim-coordinator/github-labels/plugin.sh"
assert_eq "claim → rc 0" "0" "$rc"
assert_eq "the reply parses as JSON" "0" "$(jq -e . >/dev/null 2>&1 <<< "$reply"; echo $?)"
assert_eq "…acquired false" "false" "$(jq -r .acquired <<< "$reply" 2>/dev/null || echo unparsed)"
assert_eq "…and the holder comes through as written" "$(printf 'run "x" \\ tab\there\x01bell')" \
    "$(jq -r .holder <<< "$reply" 2>/dev/null || echo unparsed)"
assert_eq "no label is added to a claimed issue" "0" "$(/usr/bin/grep -c -- '--add-label' "$GHS/log" || true)"
assert_contains "the refusal says how to clear a claim whose run is gone" \
    "$(claim_coordinator_claim 7003 2>&1 >/dev/null)" "gh issue edit 7003 --remove-label zbuild:claimed"

print_test_section "gh: NO_GITHUB=true — no claim, no gh call"
_gh_reset; : > "$GHS/repo-label"
set +e; reply="$(NO_GITHUB=true claim_coordinator_claim 7004)"; rc=$?; set -e
assert_eq "claim → rc 0" "0" "$rc"
assert_eq "…the reply says the claim was skipped" "NO_GITHUB=true" "$(jq -r '.skipped // empty' <<< "$reply" 2>/dev/null)"
assert_eq "…and gh was never called" "0" "$(wc -l < "$GHS/log" | tr -d ' ')"

print_test_section "gh: release"
_gh_reset; printf 'zbuild:claimed\nbug\n' > "$GHS/labels"
set +e; claim_coordinator_release 7005; rc=$?; set -e
assert_eq "release → rc 0" "0" "$rc"
assert_eq "release removes only zbuild:claimed" "bug" "$(cat "$GHS/labels")"
assert_contains "…naming the repository" "$(cat "$GHS/log")" "--remove-label zbuild:claimed --repo testowner/testrepo"
_gh_reset; printf 'zbuild:claimed\n' > "$GHS/labels"; : > "$GHS/fail-remove"
set +e; claim_coordinator_release 7006 2>"$TEST_TEMP_DIR/err"; rc=$?; set -e
assert_eq "a failed removal → non-zero rc" "1" "$(( rc != 0 ))"
assert_contains "…and says to remove the label by hand" "$(cat "$TEST_TEMP_DIR/err")" "remove the zbuild:claimed label"

print_test_section "gh: a gh that hangs is stopped by the watchdog"
_gh_reset; : > "$GHS/repo-label"; : > "$GHS/hang"
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=1
set +e; reply="$(claim_coordinator_claim 7007 2>/dev/null)"; rc=$?; set -e
: > "$GHS/go"
assert_eq "a hung gh → backend error rc 1" "1" "$rc"
assert_eq "…and nothing was claimed" "" "$(cat "$GHS/labels")"

# ── Concurrent claim race detection (DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-7) ──
# These tests require the gh backend and a custom gh mock that tracks the
# sequence of API calls so the test can verify order and content.
#
# Mock protocol: each call appends to $GHS/log. $GHS/call-sequence records one
# token per call so the test can assert ordering. The mock handles:
#   POST to …/comments              → returns $GHS/post-reply.json
#   GET  --paginate …/comments      → returns all files in $GHS/notes-pages/
#   issue view                      → returns current labels ($GHS/labels)
#   issue edit --add-label          → adds label
#   issue edit --remove-label       → removes label
#   api -X PATCH …/comments/<id>    → records the PATCH body in $GHS/patched-<id>
#   api -X DELETE …/comments/<id>   → records the DELETE
#
# Holder is made predictable by setting GITHUB_ACTIONS=true with known CI vars
# so _ccgl_self_holder_v returns a fixed URL instead of a PID-dependent string.

export ZBUILD_CLAIM_BACKEND="gh"
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5 GITHUB_REPOSITORY="testowner/testrepo"
# Fixed holder for all DSRACE tests: a predictable CI URL.
export GITHUB_ACTIONS=true GITHUB_SERVER_URL=https://github.com
export GITHUB_RUN_ID=dsrace-test-run
_RACE_HOLDER="https://github.com/testowner/testrepo/actions/runs/dsrace-test-run"

_race_gh_reset() {
    rm -rf "$GHS"
    mkdir -p "$GHS/notes-pages"
    : > "$GHS/labels"
    : > "$GHS/log"
    : > "$GHS/call-sequence"
    : > "$GHS/repo-label"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'RACEMOCK'
#!/usr/bin/env bash
s="__GHS__"
printf '%s\n' "$*" >> "$s/log"
# Determine call type and record it for sequence assertions
_meth=""; _prev=""
for a in "$@"; do
    [[ "$_prev" == "-X" ]] && _meth="$a"
    _prev="$a"
done
case "$1:$2:${_meth}" in
    issue:view:)       printf 'ISSUE_VIEW\n'  >> "$s/call-sequence" ;;
    issue:edit:)
        case "$4" in
            --add-label)    printf 'ADD_LABEL\n'    >> "$s/call-sequence" ;;
            --remove-label) printf 'REMOVE_LABEL\n' >> "$s/call-sequence" ;;
            *)              printf 'ISSUE_EDIT\n'   >> "$s/call-sequence" ;;
        esac ;;
    label:create:)     printf 'LABEL_CREATE\n' >> "$s/call-sequence" ;;
    api:--paginate:)   printf 'GET_NOTES\n'    >> "$s/call-sequence" ;;
    api:*:PATCH|api:--repo:PATCH) printf 'PATCH\n'  >> "$s/call-sequence" ;;
    api:*:DELETE|api:--repo:DELETE) printf 'DELETE\n' >> "$s/call-sequence" ;;
    api:--repo:)
        # Detect POST to …/comments vs other api calls
        _url=""
        for a in "$@"; do _url="$a"; done
        # POST to .../issues/<n>/comments ends with "/comments" or has -f body=
        _is_post=0
        for a in "$@"; do [[ "$a" == -f ]] && _is_post=1; done
        [[ "$_is_post" -eq 1 ]] && printf 'POST_NOTE\n' >> "$s/call-sequence" \
                                 || printf 'API_OTHER\n' >> "$s/call-sequence" ;;
    *) printf 'OTHER\n' >> "$s/call-sequence" ;;
esac

# Route by operation
case "${_meth}" in
    DELETE)
        # Extract id from the URL path: …/comments/<id>
        _id=""; _prev2=""
        for a in "$@"; do
            [[ "$a" == */comments/* ]] && { _id="${a##*/comments/}"; _id="${_id%%/*}"; }
            _prev2="$a"
        done
        : > "$s/deleted-${_id:-0}"; exit 0 ;;
    PATCH)
        # Extract id from URL path and --input file
        _id=""; _inf=""; _prev2=""
        for a in "$@"; do
            [[ "$a" == */comments/* ]] && { _id="${a##*/comments/}"; _id="${_id%%/*}"; }
            [[ "$_prev2" == "--input" ]] && _inf="$a"
            _prev2="$a"
        done
        [[ -n "$_inf" && -f "$_inf" ]] && cp "$_inf" "$s/patched-${_id:-0}"
        exit 0 ;;
esac

case "$1:$2" in
    api:--paginate)
        for f in "$s"/notes-pages/*.json; do [[ -e "$f" ]] && cat "$f"; done; exit 0 ;;
    api:--repo)
        # POST to .../comments (has -f body=)
        for a in "$@"; do
            if [[ "$a" == -f ]]; then
                cat "$s/post-reply.json" 2>/dev/null \
                    || printf '{"id":99001,"created_at":"2026-01-01T00:00:00Z","body":"","user":{"login":"github-actions[bot]"}}\n'
                exit 0
            fi
        done
        # Fallback api call
        exit 0 ;;
    issue:view) cat "$s/labels"; exit 0 ;;
    issue:edit)
        label="${5:-}"
        if [[ "$4" == "--add-label" ]]; then
            [[ ! -e "$s/repo-label" ]] \
                && { printf "could not add label: '%s' not found\n" "$label" >&2; exit 1; }
            /usr/bin/grep -Fxq "$label" "$s/labels" || printf '%s\n' "$label" >> "$s/labels"
            exit 0
        fi
        if [[ "$4" == "--remove-label" ]]; then
            /usr/bin/grep -Fxv "$label" "$s/labels" > "$s/labels.new" || true
            mv "$s/labels.new" "$s/labels"; exit 0
        fi
        exit 1 ;;
    label:create) : > "$s/repo-label"; exit 0 ;;
esac
exit 0
RACEMOCK
    sed -i "s|__GHS__|$GHS|g" "$TEST_TEMP_DIR/bin/gh"
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    # Reset the plugin's cached slug so the new GITHUB_REPOSITORY takes effect
    _CCGL_SLUG="" _ZBUILD_CLAIM_GH_LABELS_LOADED="" \
        source "$REPO_ROOT/plugins/claim-coordinator/github-labels/plugin.sh"
}

# ─── DSRACE-1: post note then read notes — note is posted BEFORE read-back ───
print_test_section "gh race: concurrent claim note is posted before read-back [DSRACE-1]"
# Given
_race_gh_reset
printf '{"id":99001,"created_at":"2026-01-01T00:00:00Z","body":"concurrent claim by `%s`","user":{"login":"github-actions[bot]"}}\n' \
    "$_RACE_HOLDER" > "$GHS/post-reply.json"
printf '[{"id":99001,"created_at":"2026-01-01T00:00:00Z","body":"concurrent claim by `%s`","user":{"login":"github-actions[bot]"},"author_association":"OWNER"}]\n' \
    "$_RACE_HOLDER" > "$GHS/notes-pages/page-1.json"
# When
set +e; reply="$(claim_coordinator_claim 8001 2>/dev/null)"; set -e
# Then: note is posted synchronously before the read-back
_post_line="$(/usr/bin/grep -n "^POST_NOTE$" "$GHS/call-sequence" | /usr/bin/head -1 | cut -d: -f1)"
_get_line="$(/usr/bin/grep -n "^GET_NOTES$" "$GHS/call-sequence" | /usr/bin/head -1 | cut -d: -f1)"
assert_eq "[DSRACE-1] a POST_NOTE call was made (synchronous holder record)" "1" \
    "$( [[ -n "$_post_line" ]] && echo 1 || echo 0 )" # [DSRACE-1]
assert_eq "[DSRACE-1] a GET_NOTES call was made (read-back of concurrent notes)" "1" \
    "$( [[ -n "$_get_line" ]] && echo 1 || echo 0 )" # [DSRACE-1]
assert_eq "[DSRACE-1] POST_NOTE appears before GET_NOTES in call sequence" "1" \
    "$( [[ -n "$_post_line" && -n "$_get_line" && "$_post_line" -lt "$_get_line" ]] && echo 1 || echo 0 )" # [DSRACE-1]
assert_contains "[DSRACE-1] the POST body includes the concurrent-claim prefix" \
    "$(cat "$GHS/log")" "concurrent claim by" # [DSRACE-1]

# ─── DSRACE-7: issue is re-read AFTER the note is posted, BEFORE arbitration ─
print_test_section "gh race: issue re-read after note post, before arbitration [DSRACE-7]"
# Given: the concurrent claim note was posted synchronously in the When above
#        (claim_coordinator_claim 8001); the same call-sequence is reused here
# When: the claim read the GitHub issue's current state — recorded as ISSUE_VIEW
#       in the call-sequence during the same invocation as the note post above
# Then: fresh issue data is obtained from GitHub after the synchronous holder record was written
_post_line="$(/usr/bin/grep -n "^POST_NOTE$" "$GHS/call-sequence" | /usr/bin/head -1 | cut -d: -f1)"
# Look for the LAST ISSUE_VIEW (the re-read that follows the POST, not the initial label check)
_view_line="$(/usr/bin/grep -n "^ISSUE_VIEW$" "$GHS/call-sequence" | /usr/bin/tail -1 | cut -d: -f1)"
_get_line="$(/usr/bin/grep -n "^GET_NOTES$" "$GHS/call-sequence" | /usr/bin/head -1 | cut -d: -f1)"
assert_eq "[DSRACE-7] an ISSUE_VIEW (re-read) call was made" "1" \
    "$( [[ -n "$_view_line" ]] && echo 1 || echo 0 )" # [DSRACE-7]
assert_eq "[DSRACE-7] the ISSUE_VIEW comes after POST_NOTE" "1" \
    "$( [[ -n "$_post_line" && -n "$_view_line" && "$_view_line" -gt "$_post_line" ]] && echo 1 || echo 0 )" # [DSRACE-7]
assert_eq "[DSRACE-7] the ISSUE_VIEW comes before GET_NOTES (re-read before arbitration)" "1" \
    "$( [[ -n "$_view_line" && -n "$_get_line" && "$_view_line" -lt "$_get_line" ]] && echo 1 || echo 0 )" # [DSRACE-7]

# ─── DSRACE-1 (And): all epoch notes across pages are considered ──────────────
# Given: two pages of notes — the earlier note is on page 2 (a later-arriving run
#        sees its own note on page 1, but the first claimant's note is on page 2)
_race_gh_reset
printf '{"id":99201,"created_at":"2026-01-01T00:00:01Z","body":"","user":{"login":"github-actions[bot]"}}\n' \
    > "$GHS/post-reply.json"
printf '[{"id":99201,"created_at":"2026-01-01T00:00:01Z","body":"concurrent claim by `%s`","user":{"login":"github-actions[bot]"},"author_association":"OWNER"}]\n' \
    "$_RACE_HOLDER" > "$GHS/notes-pages/page-1.json"
printf '[{"id":88001,"created_at":"2026-01-01T00:00:00Z","body":"concurrent claim by `page2-winner`","user":{"login":"github-actions[bot]"},"author_association":"OWNER"}]\n' \
    > "$GHS/notes-pages/page-2.json"
# When
set +e; _r1b="$(claim_coordinator_claim 8001b 2>/dev/null)"; set -e
# Then: all pages were read — the earlier note on page 2 is identified as winner
assert_eq "[DSRACE-1] all concurrent claim notes from the current label epoch are returned (loser when earlier note is on page 2)" "false" \
    "$(jq -r '.acquired' <<< "$_r1b" 2>/dev/null || echo unparsed)" # [DSRACE-1]

# ─── DSRACE-2: loser returns race_lost: true; winner returns acquired: true ──
print_test_section "gh race: winner gets acquired:true, loser gets race_lost:true [DSRACE-2]"
# Given: two concurrent notes exist — winner's note (id 99001) has the earliest created_at
_race_gh_reset
printf '{"id":99002,"created_at":"2026-01-01T00:00:01Z","body":"","user":{"login":"github-actions[bot]"}}\n' \
    > "$GHS/post-reply.json"
printf '[{"id":99001,"created_at":"2026-01-01T00:00:00Z","body":"concurrent claim by `winner-run`","user":{"login":"github-actions[bot]"},"author_association":"OWNER"},{"id":99002,"created_at":"2026-01-01T00:00:01Z","body":"concurrent claim by `%s`","user":{"login":"github-actions[bot]"},"author_association":"OWNER"}]\n' \
    "$_RACE_HOLDER" > "$GHS/notes-pages/page-1.json"
# When: the loser compares notes and finds it was not first
set +e; reply="$(claim_coordinator_claim 8002 2>/dev/null)"; set -e
# Then: the first note by created_at wins
assert_eq "[DSRACE-2] loser reply: acquired is false" "false" \
    "$(jq -r .acquired <<< "$reply" 2>/dev/null || echo unparsed)" # [DSRACE-2]
assert_eq "[DSRACE-2] loser reply: race_lost is true" "true" \
    "$(jq -r '.race_lost // empty' <<< "$reply" 2>/dev/null || echo missing)" # [DSRACE-2]
assert_eq "[DSRACE-2] loser reply: holder names the concurrent winner" "winner-run" \
    "$(jq -r '.holder // empty' <<< "$reply" 2>/dev/null || echo missing)" # [DSRACE-2]

# Given: only this run's note is present — it came first (sole claimant)
_race_gh_reset
printf '{"id":99003,"created_at":"2026-01-01T00:00:00Z","body":"","user":{"login":"github-actions[bot]"}}\n' \
    > "$GHS/post-reply.json"
printf '[{"id":99003,"created_at":"2026-01-01T00:00:00Z","body":"concurrent claim by `%s`","user":{"login":"github-actions[bot]"},"author_association":"OWNER"}]\n' \
    "$_RACE_HOLDER" > "$GHS/notes-pages/page-1.json"
# When: the winner compares notes and finds it was first
set +e; reply="$(claim_coordinator_claim 8003 2>/dev/null)"; set -e
# Then: the run whose note is first returns acquired: true
assert_eq "[DSRACE-2] winner (sole claimant) reply: acquired is true" "true" \
    "$(jq -r .acquired <<< "$reply" 2>/dev/null || echo unparsed)" # [DSRACE-2]

# ─── DSRACE-3: losing run PATCHes its note to "not started" ──────────────────
print_test_section "gh race: loser PATCHes note body to 'not started' [DSRACE-3]"
# Given: this run's note (id 99004) has a later created_at than winner's note (id 99001)
_race_gh_reset
printf '{"id":99004,"created_at":"2026-01-01T00:00:01Z","body":"","user":{"login":"github-actions[bot]"}}\n' \
    > "$GHS/post-reply.json"
printf '[{"id":99001,"created_at":"2026-01-01T00:00:00Z","body":"concurrent claim by `winner-run`","user":{"login":"github-actions[bot]"},"author_association":"OWNER"},{"id":99004,"created_at":"2026-01-01T00:00:01Z","body":"concurrent claim by `%s`","user":{"login":"github-actions[bot]"},"author_association":"OWNER"}]\n' \
    "$_RACE_HOLDER" > "$GHS/notes-pages/page-1.json"
# When: the run determines it has lost the race
set +e; claim_coordinator_claim 8004 2>/dev/null; set -e
# Then: the run PATCHes its note body to "not started — concurrent claim: `<winner>` was first"
assert_eq "[DSRACE-3] the losing run made a PATCH call on its own note (id 99004)" "1" \
    "$( [[ -f "$GHS/patched-99004" ]] && echo 1 || echo 0 )" # [DSRACE-3]
_patch_body="$(jq -r .body "$GHS/patched-99004" 2>/dev/null || echo "")"
assert_contains "[DSRACE-3] the PATCH body says 'not started'" \
    "$_patch_body" "not started" # [DSRACE-3]
assert_contains "[DSRACE-3] the PATCH body says 'concurrent claim'" \
    "$_patch_body" "concurrent claim" # [DSRACE-3]
assert_contains "[DSRACE-3] the PATCH body names the winner" \
    "$_patch_body" "winner-run" # [DSRACE-3]
assert_contains "[DSRACE-3] the PATCH body says 'was first'" \
    "$_patch_body" "was first" # [DSRACE-3]

cleanup_test_env
print_test_results
exit $((FAIL > 0))
