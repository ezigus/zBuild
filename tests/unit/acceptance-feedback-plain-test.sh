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
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh" >/dev/null 2>&1

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

# F5–F7 (ADR-040, amended 2026-10-31): a run of the change's own test file that
# goes past its limit is the change's to fix, not the pipeline's. On #1754's run
# a new test file took 210 s; every re-run went past its 480 s limit and was
# reported as "a problem in the pipeline, not in your change".
design_md="$TEST_TEMP_DIR/design.md"
cat > "$design_md" <<'EOF'
# Design
```acceptance
SPEC-5[code]: the lint flags an unchecked write
WIRING: none
TESTFILES:
SPEC-5: tests/unit/x-test.sh
```
EOF
printf 'file 210229 /tmp/zbuild-test-stage.X/tests/unit/x-test.sh\n' > "$TEST_TEMP_DIR/timing.log"
export ZBUILD_NEGCTL_TIMING_LOG="$TEST_TEMP_DIR/timing.log" ZBUILD_NEGCTL_TIMEOUT=60
_slow="$(_ag_build_reason negctl_error:timeout:SPEC-5 reachability_error:timeout:lib/c.sh 2>/dev/null)"
for _w in "problem in the pipeline" "timeout:"; do
    if grep -qF -- "$_w" <<< "$_slow"; then
        assert_fail "[F5] a timeout of the change's own test file does not say '$_w'" "in: ${_slow:0:300}"
    else
        assert_pass "[F5] a timeout of the change's own test file does not say '$_w'"
    fi
done
assert_contains "[F5] it names the test file" "$_slow" "tests/unit/x-test.sh"
assert_contains "[F5] ...the time the test run measured for it" "$_slow" "210 s"
assert_contains "[F5] ...and the limit it went past" "$_slow" "480 s"
assert_contains "[F5] ...and says what to change" "$_slow" "faster"
assert_contains "[F6] putting a file back that timed out names it too" "$_slow" "lib/c.sh"
_infra="$(_ag_build_reason negctl_error:worktree_failed 2>/dev/null)"
assert_contains "[F7] an error that is not a timeout is still the pipeline's" "$_infra" "problem in the pipeline"
unset design_md ZBUILD_NEGCTL_TIMING_LOG ZBUILD_NEGCTL_TIMEOUT

cleanup_test_env
print_test_results
exit $((FAIL > 0))
