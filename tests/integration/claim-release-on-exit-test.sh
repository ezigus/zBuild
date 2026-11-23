#!/usr/bin/env bash
# Integration: the real runner claims the issue before the first stage and
# releases it on every way out (ADR-005 §1, issue #1764 R1/R3/R4/R6).
#
# C1 the claim is on the issue when the first stage runs; gone after a pass
# C2 …gone after a stage failure
# C3 …gone after a TERM mid-stage
# C4 the coordinator's claim hook runs before the first stage, its release hook on exit
# C5 a run with no issue calls no coordinator hook
# C6 a run that fails before its stages (its recorded tree is gone) releases the claim
# C9 [change] a marker left by an earlier run (a resume) is cleared at start: a
#    later TERM is a TERM, not a rejected login (review of #2589)
# C8 [change] GitHub rejects the run's login (#2589): the run stops, names that
#    as its reason, and still releases the claim
# C7 a TERM that lands while the claim is being taken: the claim is released,
#    no stage runs
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../lib/claim-runner-fixture.sh
source "$REPO_ROOT/tests/lib/claim-runner-fixture.sh"

print_test_header "the runner claims before the first stage and releases on exit (ADR-005 §1)"
setup_test_env "claim-release-on-exit"
claim_fixture_setup

_labels() { cat "$ZBUILD_CLAIM_STORE/$1/labels.txt" 2>/dev/null || true; }

# ── C1–C3: the github-labels coordinator on the local-fs store ──────────────
claim_fixture_real_coordinator
SEEN="$TEST_TEMP_DIR/seen"
_seen_stage() {   # <issue> [then]
    claim_fixture_stage "cat \"$ZBUILD_CLAIM_STORE/$1/labels.txt\" > \"$SEEN\" 2>/dev/null; ${2:-:}"
}

print_test_section "C1 pass"
rm -f "$SEEN"; _seen_stage 90001801
claim_fixture_run c1 --issue 90001801
assert_eq "[C1] the run passes" "0" "$CLAIM_RC"
assert_eq "[C1] zbuild:claimed is on the issue when the first stage runs" "zbuild:claimed" "$(cat "$SEEN" 2>/dev/null)"
assert_eq "[C1] …and gone after the run" "" "$(_labels 90001801)"

print_test_section "C2 stage failure"
rm -f "$SEEN"
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() {
    cat "$ZBUILD_CLAIM_STORE/90001802/labels.txt" > "$SEEN" 2>/dev/null
    local _art; _art="\${ZBUILD_ARTIFACT_DIR:-\$(dirname "\$2")/artifacts}"; mkdir -p "\$_art"
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    stage_result_write "\$_art/outcome-result.json" "broken" "deliberate failure"
    return 1
}
PLUG
claim_fixture_run c2 --issue 90001802
assert_eq "[C2] the run fails" "1" "$(( CLAIM_RC != 0 ))"
assert_eq "[C2] zbuild:claimed was on the issue during the run" "zbuild:claimed" "$(cat "$SEEN" 2>/dev/null)"
assert_eq "[C2] …and gone after the failure" "" "$(_labels 90001802)"

print_test_section "C3 TERM mid-stage"
rm -f "$SEEN"; STARTED="$TEST_TEMP_DIR/c3-started"
_seen_stage 90001803 ": > \"$STARTED\"; sleep 60"
claim_fixture_start c3 --issue 90001803
claim_fixture_wait_for "$STARTED" || assert_fail "[C3] setup: the stage started" "$(tail -5 "$TEST_TEMP_DIR/c3.out")"
kill -TERM "$CLAIM_PID" 2>/dev/null || true
claim_fixture_wait_gone "$CLAIM_PID"
assert_eq "[C3] zbuild:claimed was on the issue when the stage ran" "zbuild:claimed" "$(cat "$SEEN" 2>/dev/null)"
assert_eq "[C3] …and gone after the TERM" "" "$(_labels 90001803)"

# ── C4–C7: a stub coordinator; its hook calls are the evidence ──────────────
print_test_section "C4 the hooks, through the registry"
claim_fixture_stub_coordinator '{"acquired": true}'
claim_fixture_stage "cp \"$CLAIM_CALLS\" \"$SEEN\""
claim_fixture_run c4 --issue 90001804
assert_eq "[C4] the claim hook had run when the first stage started" "claim 90001804" "$(cat "$SEEN" 2>/dev/null)"
assert_eq "[C4] …and the release hook ran on exit" "$(printf 'claim 90001804\nrelease 90001804')" "$(cat "$CLAIM_CALLS")"

print_test_section "C5 no issue, no claim"
claim_fixture_stub_coordinator '{"acquired": true}'
claim_fixture_stage ":"
claim_fixture_run c5 --goal "a run with no issue"
assert_eq "[C5] the run passes" "0" "$CLAIM_RC"
assert_eq "[C5] no coordinator hook was called" "" "$(cat "$CLAIM_CALLS")"

print_test_section "C6 a failure before the stages"
claim_fixture_stub_coordinator '{"acquired": true}'
STARTED="$TEST_TEMP_DIR/c6-started"; claim_fixture_stage ": > \"$STARTED\""
_claim_fixture_prep c6
# A recorded tree that is gone: _runner_enter_worktree refuses before the exit trap is set.
printf '%s\n' "/nonexistent/worktree/c6" > "$ZBUILD_STATE_DIR/run-worktree.txt"
CLAIM_RC=0
( cd "$CLAIM_REPO" && exec bash "$RUNNER" --no-resume --template claim-test --issue 90001806 ) \
    > "$TEST_TEMP_DIR/c6.out" 2>&1 || CLAIM_RC=$?
assert_eq "[C6] the run fails" "1" "$(( CLAIM_RC != 0 ))"
assert_file_not_exists "[C6] no stage ran" "$STARTED"
assert_eq "[C6] the claim taken before the failure is released" \
    "$(printf 'claim 90001806\nrelease 90001806')" "$(cat "$CLAIM_CALLS")"

print_test_section "C7 a TERM while the claim is taken"
# The claim hook answers "claimed" and signals the run it serves ($$ is the
# runner in the hook's subshell): the signal lands inside the claim.
claim_fixture_stub_coordinator '{"acquired": true}' 'kill -TERM $$'
STARTED="$TEST_TEMP_DIR/c7-started"; claim_fixture_stage ": > \"$STARTED\""
claim_fixture_run c7 --issue 90001807
assert_eq "[C7] the run ends non-zero" "1" "$(( CLAIM_RC != 0 ))"
assert_file_not_exists "[C7] no stage ran" "$STARTED"
_c7_want="$(printf 'claim 90001807\nrelease 90001807')"
assert_eq "[C7] the claim is released" "$_c7_want" "$(cat "$CLAIM_CALLS")"
# #2586: a failure here has been seen only in CI; it shows the run it saw.
[[ "$(cat "$CLAIM_CALLS")" == "$_c7_want" ]] || claim_fixture_show c7

print_test_section "C8 GitHub rejects the run's login"
# The sidecar marks a rejected login and stops the run (rsc_gh, rsc_tail_loop);
# here the stage plays that part: the marker, then the signal.
claim_fixture_stub_coordinator '{"acquired": true}'
claim_fixture_stage 'mkdir -p "$ZBUILD_STATE_DIR/runtime"; printf "HTTP 401: Bad credentials\n" > "$ZBUILD_STATE_DIR/runtime/github-login-rejected"; kill -TERM $$'
claim_fixture_run c8 --issue 90001808
assert_eq "[C8] the run ends non-zero" "1" "$(( CLAIM_RC != 0 ))"
assert_contains "[C8] it names the rejected login as its reason" \
    "$(jq -c 'select(.type == "pipeline.aborted") | .data' "$(claim_fixture_events c8)" 2>/dev/null)" "github_login_rejected"
assert_eq "[C8] the claim is still released" "$(printf 'claim 90001808\nrelease 90001808')" "$(cat "$CLAIM_CALLS")"
[[ "$(cat "$CLAIM_CALLS")" == "$(printf 'claim 90001808\nrelease 90001808')" ]] || claim_fixture_show c8

print_test_section "C9 an old rejected-login marker does not outlive its run"
claim_fixture_stub_coordinator '{"acquired": true}'
claim_fixture_stage 'kill -TERM $$'
_claim_fixture_prep c9
mkdir -p "$ZBUILD_STATE_DIR/runtime"; printf 'HTTP 401: Bad credentials\n' > "$ZBUILD_STATE_DIR/runtime/github-login-rejected"
CLAIM_RC=0
( cd "$CLAIM_REPO" && exec bash "$RUNNER" --no-resume --template claim-test --issue 90001809 ) > "$TEST_TEMP_DIR/c9.out" 2>&1 || CLAIM_RC=$?
_c9="$(jq -c 'select(.type == "pipeline.aborted") | .data.reason' "$(claim_fixture_events c9)" 2>/dev/null)"
assert_contains "[C9] a TERM after a resume is a TERM" "$_c9" "sigterm"
if [[ "$_c9" == *github_login_rejected* ]]; then assert_fail "[C9] ...not a rejected login" "$_c9"; else assert_pass "[C9] ...not a rejected login"; fi

print_test_results
exit $((FAIL > 0))
