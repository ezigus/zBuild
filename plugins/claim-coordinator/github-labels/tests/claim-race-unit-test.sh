#!/usr/bin/env bash
# Tests: two runs claiming one issue on GitHub at once (ADR-005 §5, #2534).
# Each run's claim and release go through the engine (core/claim/claim.sh) and
# the real github-labels coordinator. GitHub is the fake in claim-gh-mock.sh: it
# keeps the labels and the comments our code posts, and gives them back when
# read, so no reply here holds a claim note the test wrote by hand.
#
# "At once": the fake answers each run's read of the labels as if made before
# the other run's label was visible (labels-unseen). Where both runs must read
# after both posted, the fake's list of comments waits for both notes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../../../tests/lib/claim-gh-mock.sh
source "$REPO_ROOT/tests/lib/claim-gh-mock.sh"

print_test_header "plugin: claim-coordinator/github-labels — two runs claiming at once (ADR-005 §5)"
setup_test_env "claim-race-unit"
unset NO_GITHUB ZBUILD_CLAIM_RACE_WINDOW_S
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
_ZBUILD_ROOT="$REPO_ROOT"
# shellcheck source=../../../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../../../core/claim/claim.sh
source "$REPO_ROOT/core/claim/claim.sh"

STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE"
PLUGINS="$TEST_TEMP_DIR/plugins"; mkdir -p "$PLUGINS/claim-coordinator"
cp -R "$REPO_ROOT/plugins/claim-coordinator/github-labels" "$PLUGINS/claim-coordinator/"
rm -rf "$PLUGINS/claim-coordinator/github-labels/tests"
export ZBUILD_PLUGINS_ROOT="$PLUGINS" ZBUILD_CLAIM_BACKEND=gh ZBUILD_CLAIM_MACHINE_ID=box-1
export GITHUB_ACTIONS=true GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=testowner/testrepo
# The old window was four of these (20 s); the window is its own setting now.
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5
GHS="$TEST_TEMP_DIR/gh" ISSUE=8100

_holder() { printf 'https://github.com/testowner/testrepo/actions/runs/%s' "$1"; }
_fresh() { rm -rf "$GHS"; claim_gh_mock_install "$GHS"; : > "$GHS/repo-label"; : > "$ZBUILD_EVENTS_JSONL"; }
_at() { printf '2026-01-01T%s' "$1" > "$GHS/now"; }
# _run <name> [release] — one run in its own shell: it claims the issue, then
# with `release` releases what it holds. <name> is its CI run id.
_run() {
    local name="$1"
    (
        export GITHUB_RUN_ID="$name"
        rc=0; zbuild_claim_acquire "$ISSUE" "$STATE" 2> "$TEST_TEMP_DIR/$name.err" || rc=$?
        printf '%s' "$rc" > "$TEST_TEMP_DIR/$name.rc"
        printf '%s' "${_ZBUILD_CLAIM_ACQUIRED:-}" > "$TEST_TEMP_DIR/$name.held"
        [[ "${2:-}" != release ]] || zbuild_claim_release 2>> "$TEST_TEMP_DIR/$name.err"
        return 0
    )
}
_rc() { cat "$TEST_TEMP_DIR/$1.rc"; }
_held() { cat "$TEST_TEMP_DIR/$1.held"; }          # the issue the run holds, or nothing
_err() { cat "$TEST_TEMP_DIR/$1.err"; }
_labels() { cat "$GHS/labels"; }
# _body_count <body> — how many comments on the issue say exactly <body>.
_body_count() { jq --arg b "$1" '[.[] | select(.body == $b)] | length' "$GHS/comments.json"; }
# shellcheck disable=SC2016  # the backticks are the note's own text
_note() { printf 'concurrent claim by `%s`' "$(_holder "$1")"; }
# shellcheck disable=SC2016
_not_started() { printf 'not started — concurrent claim: `%s` was first' "$(_holder "$1")"; }
# _kinds — every call GitHub got, in order: view, add, remove, post, list,
# patch, delete; anything else as written.
_kinds() {
    local line out=""
    while IFS= read -r line; do
        case "$line" in
            "issue view "*) out+="view " ;;
            "issue edit "*"--add-label"*) out+="add " ;;
            "issue edit "*"--remove-label"*) out+="remove " ;;
            "api -X PATCH "*) out+="patch " ;;
            "api -X DELETE "*) out+="delete " ;;
            "api "*" -f body="*) out+="post " ;;
            "api "*"issues/$ISSUE/comments"*) out+="list " ;;
            *) out+="[$line] " ;;
        esac
    done < "$GHS/log"
    printf '%s' "${out% }"
}
_holders() { local n=0 r; for r in "$@"; do [[ "$(_held "$r")" == "$ISSUE" ]] && n=$(( n + 1 )); done; printf '%s' "$n"; }
# _both_read_after_both_posted <first-time> <second-time> — `first` posts at
# <first-time>, then `second` at <second-time>; each reads the notes only once
# both are there.
_both_read_after_both_posted() {
    local pid
    _fresh; : > "$GHS/labels-unseen"; printf '2' > "$GHS/list-waits-for"
    _at "$1"; _run first & pid=$!
    wait_for_event "$GHS/comments.json" 'runs/first' 200 0.05 \
        || assert_fail "setup: the first run posted its note" "$(cat "$GHS/log")"
    _at "$2"; _run second
    wait_for_exit "$pid" 400 || assert_fail "setup: the first run finished" "$(_err first)"
}
# _left_note <time> — run `gone` claims at <time> and dies without releasing; the
# label is removed for it (as the CI clean-up does), its claim note is left.
_left_note() { _fresh; _at "$1"; _run gone; : > "$GHS/labels"; : > "$GHS/log"; }

print_test_section "two runs at once, in the same second: the first claim wins"
_fresh; : > "$GHS/labels-unseen"; _at 00:00:00Z
_run first; _run second
assert_eq "[#2534/SPEC-1] the first run holds the claim" "$ISSUE" "$(_held first)"
assert_eq "[#2534/SPEC-1] the second run is refused" "1" "$(_rc second)"
assert_eq "[#2534/SPEC-1] ...and holds nothing" "" "$(_held second)"
assert_contains "[#2534/SPEC-1] ...naming the run that claimed first" "$(_err second)" "$(_holder first)"
assert_eq "[#2534/SPEC-1] the label stays on the issue: the second run does not remove it" \
    "zbuild:claimed" "$(_labels)"
assert_eq "[#2534/SPEC-1] the second run's note says it did not start, and who was first" \
    "1" "$(_body_count "$(_not_started first)")"
assert_eq "[#2534/SPEC-1] the first run's note stands as its holder record" "1" "$(_body_count "$(_note first)")"
assert_eq "[#2534/SPEC-6] [#2534/SPEC-7] each run reads the labels once and the notes once; the loser rewrites its note and takes nothing over" \
    "view add post list view add post list patch" "$(_kinds)"

print_test_section "both runs read after both posted: exactly one proceeds"
_both_read_after_both_posted 00:00:00Z 00:00:00Z
assert_eq "[#2534/SPEC-1] exactly one run holds the claim" "1" "$(_holders first second)"
assert_eq "[#2534/SPEC-3] ...the first: same second, the lower id" "$ISSUE" "$(_held first)"
assert_eq "[#2534/SPEC-1] ...and the other is refused" "1" "$(_rc second)"
_both_read_after_both_posted 00:00:05Z 00:00:00Z
assert_eq "[#2534/SPEC-3] GitHub's time comes before the id: the earlier note wins, though its id is higher" \
    "$ISSUE" "$(_held second)"
assert_eq "[#2534/SPEC-1] ...and only it" "1" "$(_holders first second)"

print_test_section "the order GitHub lists the notes in does not decide"
_fresh; : > "$GHS/labels-unseen"; : > "$GHS/newest-first"; _at 00:00:00Z
_run first; _run second
assert_eq "[#2534/SPEC-3] listed newest first, the same-second note with the lower id still wins" "1" "$(_rc second)"
assert_eq "[#2534/SPEC-3] ...and the first holds the claim" "$ISSUE" "$(_held first)"

print_test_section "the earlier note is on a later page"
_fresh; : > "$GHS/labels-unseen"; _at 00:00:00Z; printf '1' > "$GHS/per-page"
jq -n '[{id: 7, body: "a person'"'"'s comment", created_at: "2025-12-31T23:00:00Z",
         user: {login: "maintainer"}, author_association: "OWNER"}]' > "$GHS/page-1.json"
_run first; _run second
assert_eq "[#2534/SPEC-7] every page is read: the second run is refused" "1" "$(_rc second)"
assert_eq "[#2534/SPEC-7] ...and the first holds the claim" "$ISSUE" "$(_held first)"

print_test_section "two local runs at once, posting as the repository's owner"
_fresh; : > "$GHS/labels-unseen"; _at 00:00:00Z
printf 'maintainer' > "$GHS/login"; printf 'OWNER' > "$GHS/association"
( unset GITHUB_ACTIONS; ZBUILD_RUN_ID=local-1 _run local-1; ZBUILD_RUN_ID=local-2 _run local-2 )
assert_eq "a local run's note, by an owner, counts: the first local run holds the claim" "$ISSUE" "$(_held local-1)"
assert_eq "...and the second is refused" "1" "$(_rc local-2)"

print_test_section "GitHub's reply gives no time: the claim fails closed"
_fresh; : > "$GHS/no-created-at"; _at 00:00:00Z
_run first
assert_eq "[#2534/SPEC-4] no claim is held" "" "$(_held first)"
assert_eq "[#2534/SPEC-4] the label is removed" "" "$(_labels)"
assert_eq "[#2534/SPEC-4] the run's note is removed" "0" "$(jq 'length' "$GHS/comments.json")"
assert_contains "[#2534/SPEC-4] the coordinator's failure is said, as any is (ADR-005 §3)" \
    "$(jq -c 'select(.type == "pipeline.claim.skipped") | .data' "$ZBUILD_EVENTS_JSONL")" "the claim coordinator failed"

print_test_section "a released claim leaves no note to count"
_fresh; _at 00:00:00Z
_run first release
assert_eq "[#2534/SPEC-2] setup: the first run held the claim" "$ISSUE" "$(_held first)"
assert_eq "[#2534/SPEC-2] release removes the label" "" "$(_labels)"
assert_eq "[#2534/SPEC-2] ...and the run's note" "0" "$(_body_count "$(_note first)")"
_at 00:00:10Z; _run next
assert_eq "[#2534/SPEC-2] a run that claims 10 s later, inside the window, holds the claim" "$ISSUE" "$(_held next)"
_left_note 00:00:00Z; _at 00:03:00Z; _run first release
assert_eq "[#2534/SPEC-2] a release removes only its own run's note" "1" "$(_body_count "$(_note gone)")"

print_test_section "a note left behind counts only inside the window"
_left_note 00:00:00Z; _at 00:02:00Z; _run later
assert_eq "[#2534/SPEC-5] a note 120 s old is inside the default 120 s window: refused" "1" "$(_rc later)"
_left_note 00:00:00Z; _at 00:02:01Z; _run later
assert_eq "[#2534/SPEC-5] a note 121 s old is outside it: claimed" "$ISSUE" "$(_held later)"
_left_note 00:00:00Z; _at 00:00:30Z; ZBUILD_CLAIM_RACE_WINDOW_S=30 _run later
assert_eq "[#2534/SPEC-5] ZBUILD_CLAIM_RACE_WINDOW_S=30: a note 30 s old is inside it" "1" "$(_rc later)"
_left_note 00:00:00Z; _at 00:00:31Z; ZBUILD_CLAIM_RACE_WINDOW_S=30 _run later
assert_eq "[#2534/SPEC-5] ...and one 31 s old is outside it" "$ISSUE" "$(_held later)"
_left_note 00:00:00Z; _at 00:02:00Z; ZBUILD_CLAIM_RACE_WINDOW_S=abc _run later
assert_eq "[#2534/SPEC-5] a window that is not a number of seconds is the default: 120 s old, refused" "1" "$(_rc later)"
_left_note 00:00:00Z; _at 00:02:01Z; ZBUILD_CLAIM_RACE_WINDOW_S=abc _run later
assert_eq "[#2534/SPEC-5] ...121 s old, claimed" "$ISSUE" "$(_held later)"
_left_note 00:00:00Z; _at 00:02:01Z; ZBUILD_CLAIM_RACE_WINDOW_S=08 _run later
assert_eq "[#2534/SPEC-5] a window with a leading zero does not break the claim" "$ISSUE" "$(_held later)"

print_test_section "GitHub's reply to the note gives no id"
_fresh; : > "$GHS/labels-unseen"; _at 00:00:00Z
_run first; : > "$GHS/no-id"; _run second
assert_eq "[#2534/SPEC-7] the second run is refused" "1" "$(_rc second)"
assert_eq "[#2534/SPEC-7] ...and finds its own note in the one read, to say it did not start" \
    "1" "$(_body_count "$(_not_started first)")"
assert_eq "[#2534/SPEC-7] ...with no second read" "view add post list view add post list patch" "$(_kinds)"

print_test_section "a note by someone else does not count"
_fresh; _at 00:00:00Z
jq -n --arg b "concurrent claim by \`someone\`" '[{id: 7, body: $b, created_at: "2025-12-31T23:59:59Z",
    updated_at: "2025-12-31T23:59:59Z", user: {login: "stranger"}, author_association: "NONE"}]' > "$GHS/page-1.json"
_run first
assert_eq "a note from an account that is not trusted is passed over: claimed" "$ISSUE" "$(_held first)"

print_test_section "a note that cannot be changed or removed"
_fresh; : > "$GHS/labels-unseen"; _at 00:00:00Z
_run first; : > "$GHS/fail-patch"; _run second
assert_eq "the loser's note that cannot say 'not started' is removed instead" "0" "$(_body_count "$(_note second)")"
assert_eq "...and the loser is still refused" "1" "$(_rc second)"
_fresh; : > "$GHS/labels-unseen"; _at 00:00:00Z
_run first; : > "$GHS/fail-patch"; : > "$GHS/fail-delete"; _run second
assert_eq "a note that can be neither changed nor removed: still refused" "1" "$(_rc second)"
assert_contains "...and it is said, with what it can do" "$(_err second)" "may be refused"
_fresh; _at 00:00:00Z; : > "$GHS/fail-delete"
_run first release
assert_eq "a release whose note cannot be removed still removes the label" "" "$(_labels)"
assert_contains "...says the note is left" "$(_err first)" "could not remove"
assert_eq "...and the release itself stands (no release_failed)" "" \
    "$(jq -c 'select(.type == "pipeline.claim.release_failed")' "$ZBUILD_EVENTS_JSONL")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
