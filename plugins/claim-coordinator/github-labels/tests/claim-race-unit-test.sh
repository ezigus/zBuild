#!/usr/bin/env bash
# Tests: two runs claiming one issue on GitHub at once (ADR-005 §5, #2534).
# Each run's claim and release go through the engine (core/claim/claim.sh) and
# the real github-labels coordinator. GitHub is the fake in claim-gh-mock.sh: it
# keeps the labels and the comments our code posts, and gives them back when
# read, so no reply here holds a claim note the test wrote by hand.
#
# "At once": the fake answers each run's read of the labels as if made before
# the other run's label was visible (labels-unseen).
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
export ZBUILD_PLUGINS_ROOT="$PLUGINS" ZBUILD_CLAIM_BACKEND=gh
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
_calls() { /usr/bin/grep -c -- "$1" "$GHS/log" || true; }
# _left_note <time> — run `gone` claims at <time> and dies without releasing; the
# label is removed for it (as the CI clean-up does), its claim note is left.
_left_note() { _fresh; _at "$1"; _run gone; : > "$GHS/labels"; }

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
assert_eq "[#2534/SPEC-3] the two notes have the same time (GitHub's, to the second)" "1" \
    "$(jq '[.[].created_at] | unique | length' "$GHS/comments.json")"
assert_eq "[#2534/SPEC-6] each run reads the issue's labels once, and not again after posting its note" \
    "2" "$(_calls '^issue view ')"
assert_eq "[#2534/SPEC-7] each run reads the claim notes once" "2" "$(_calls "^api --paginate .*issues/$ISSUE/comments")"

print_test_section "the earlier note is on a later page"
_fresh; : > "$GHS/labels-unseen"; _at 00:00:00Z; printf '1' > "$GHS/per-page"
jq -n '[{id: 7, body: "a person'"'"'s comment", created_at: "2025-12-31T23:00:00Z",
         user: {login: "maintainer"}, author_association: "OWNER"}]' > "$GHS/page-1.json"
_run first; _run second
assert_eq "[#2534/SPEC-7] every page is read: the second run is refused" "1" "$(_rc second)"
assert_eq "[#2534/SPEC-7] ...and the first holds the claim" "$ISSUE" "$(_held first)"

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

print_test_section "a note left behind counts only inside the window"
_left_note 00:00:00Z; _at 00:01:00Z; _run later
assert_eq "[#2534/SPEC-5] a note 60 s old is inside the default 120 s window: refused" "1" "$(_rc later)"
_left_note 00:00:00Z; _at 00:02:01Z; _run later
assert_eq "[#2534/SPEC-5] a note 121 s old is outside it: claimed" "$ISSUE" "$(_held later)"
_left_note 00:00:00Z; _at 00:00:25Z; ZBUILD_CLAIM_RACE_WINDOW_S=30 _run later
assert_eq "[#2534/SPEC-5] ZBUILD_CLAIM_RACE_WINDOW_S=30: a note 25 s old is inside it" "1" "$(_rc later)"
_left_note 00:00:00Z; _at 00:00:31Z; ZBUILD_CLAIM_RACE_WINDOW_S=30 _run later
assert_eq "[#2534/SPEC-5] ...and one 31 s old is outside it" "$ISSUE" "$(_held later)"
_left_note 00:00:00Z; _at 00:01:00Z; ZBUILD_CLAIM_RACE_WINDOW_S=2m _run later
assert_eq "[#2534/SPEC-5] a window that is not a number of seconds is the default" "1" "$(_rc later)"

print_test_section "GitHub's reply to the note gives no id"
_fresh; : > "$GHS/labels-unseen"; _at 00:00:00Z
_run first; : > "$GHS/no-id"; _run second
assert_eq "[#2534/SPEC-7] the second run is refused" "1" "$(_rc second)"
assert_eq "[#2534/SPEC-7] ...and finds its own note in the one read, to say it did not start" \
    "1" "$(_body_count "$(_not_started first)")"

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
