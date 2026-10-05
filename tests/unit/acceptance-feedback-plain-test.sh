#!/usr/bin/env bash
# tests/unit/acceptance-feedback-plain-test.sh — the acceptance check's feedback
# is a plain sentence: what was tried, what happened, what to change (#2269).
#
# Why: the reason the acceptance check writes reaches every later stage in its
# summary. It used to read "WIRING X inert — reverting it breaks no TESTFILE" or
# "SPEC-2 tautological — passes at the baseline": the names of the checks, not
# what to do. #2032 run 37066151065's test-author answered the first with a test
# that greps the file — satisfying the measure instead of the intent.
#
# F1 [change] no failure class is described with engine jargon (tautolog, inert,
#             merge-base, baseline, HEAD, TESTFILE, NEGCTL, infra:)
# F2 [change] the inert-wiring finding says what was tried and what to name instead
# F3 [change] the already-passing finding says the old code passes and what to check
# F4 [guard]  every finding still names its SPEC or file
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the acceptance check's feedback is plain (#2269)"
setup_test_env "acceptance-feedback-plain"
# shellcheck source=../../plugins/agent/spec-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" >/dev/null 2>&1

_all="$(_ag_build_reason tautology:SPEC-1 not_passing_at_head:SPEC-2 untagged_spec:SPEC-3 \
    no_testfile:SPEC-4 no_testfiles:lib/a.sh inert_wiring:config/x.json wiring_not_on_path:lib/b.sh \
    unclaimed_code:scripts/x.sh unreached_at_base:SPEC-7 unreached_at_head:SPEC-8 \
    killed_by_signal:SPEC-11 \
    malformed_acceptance_block negctl_error:SPEC-12 reachability_error:lib/c.sh 2>/dev/null)"

# TESTFILE as a word is jargon; the key `TESTFILES:` the model writes is not.
for _w in tautolog inert merge-base baseline HEAD 'TESTFILE([^S]|S[^:]|$)' NEGCTL "infra:" REACHABILITY; do
    if grep -qE -- "$_w" <<< "$_all"; then
        assert_fail "[F1] the feedback does not say '$_w'" "in: ${_all:0:300}"
    else
        assert_pass "[F1] the feedback does not say '$_w'"
    fi
done

_inert="$(_ag_build_reason inert_wiring:config/x.json 2>/dev/null)"
assert_contains "[F2] says the file was put back and every test still passed" "$_inert" "every test still passed"
assert_contains "[F2] says what to name instead" "$_inert" "name the file whose code calls"

_taut="$(_ag_build_reason tautology:SPEC-1 2>/dev/null)"
assert_contains "[F3] says the test already passes on the old code" "$_taut" "already passes on the code from before this change"
assert_contains "[F3] says what to check instead" "$_taut" "something the old code gets wrong"

for _id in SPEC-1 SPEC-2 SPEC-3 SPEC-4 lib/a.sh config/x.json lib/b.sh scripts/x.sh SPEC-7 SPEC-8 SPEC-11 SPEC-12 lib/c.sh; do
    assert_contains "[F4] the feedback names $_id" "$_all" "$_id"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
