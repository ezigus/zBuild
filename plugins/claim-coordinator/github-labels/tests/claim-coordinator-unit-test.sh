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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
