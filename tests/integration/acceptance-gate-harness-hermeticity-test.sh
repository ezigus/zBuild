#!/usr/bin/env bash
# Integration: guard that setup_test_env sandboxes ZBUILD_STATE_DIR so stage-io
# writes during a replayed test cannot escape into the outer pipeline's state
# directory (#1713).
#
# All three SPECs are [change] and each must redden INDEPENDENTLY at the
# merge-base. That matters here because the negative control — for [change]
# (acceptance-negctl.sh: rc_base/rc_head) as well as for [guard] (#1737) — runs
# the WHOLE testfile and keys on its exit code. A vacuous assertion in a file
# whose siblings fail is credited by them and never noticed.
#
# That is not hypothetical: the first version of this file asserted SPEC-2
# against an inline gate replay that wrote nothing to the canary even at the
# merge-base. It passed there, which makes it inert — and NEGCTL PASSed anyway,
# carried by SPEC-1 and SPEC-3. Verified at merge-base 00927cc, per assertion:
#
#   SPEC-1  FAIL   SPEC-2  pass (inert)   SPEC-3  FAIL
#
# SPEC-2 below is now the reproduction from the issue body, which is what the
# issue asked for ("The repro above is the test"): 13 records at the merge-base,
# 0 after the fix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Establish a canary ZBUILD_STATE_DIR BEFORE sourcing test-helpers, matching the
# real scenario: the pipeline exports ZBUILD_STATE_DIR before `npm test` runs.
CANARY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermeticity-canary.XXXXXX")"
REPRO_CANARY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermeticity-repro.XXXXXX")"
export ZBUILD_STATE_DIR="$CANARY_DIR"
# ZBUILD_ARTIFACT_DIR gets the same unset-then-restore treatment in the harness;
# without an ambient value here its restore branch would never be exercised.
export ZBUILD_ARTIFACT_DIR="$CANARY_DIR/artifacts"

# Captured BEFORE sourcing test-helpers.sh, which prepends a mock bin dir to
# PATH at SOURCE time (not in setup_test_env). SPEC-2's subprocess must see the
# pristine environment the pipeline actually hands `npm test`; inheriting the
# mock PATH makes the inner test fail for reasons unrelated to hermeticity.
_PRISTINE_PATH="$PATH"
_PRISTINE_HOME="$HOME"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# Both canaries live outside TEST_TEMP_DIR so the master trap does not remove
# them; hook into the standard cleanup point so they go on exit/signal.
_test_cleanup_hook() { rm -rf "$CANARY_DIR" "$REPRO_CANARY_DIR" 2>/dev/null || true; }

print_test_header "acceptance-gate harness hermeticity (#1713)"

# ── SPEC-2 (change): the issue's reproduction, end to end ────────────────────
# Run the real acceptance-gate integration test in a subprocess with BOTH
# variables the bug needs: a canary ZBUILD_STATE_DIR and the inherited
# _TPL_STAGE_IO_DESTS_* that makes template_stage_io_dests return a destination
# list. Without the second variable this passes vacuously — the exact trap the
# issue calls out. At the merge-base the replay writes its stage-io records
# into the canary; after the fix the canary stays empty.
#
# Deliberately BEFORE setup_test_env: the subprocess must inherit this
# process's real HOME and PATH, which is what the pipeline hands `npm test`.
# Running it after the sandbox is installed makes the inner test inherit the
# mock PATH and sandboxed HOME and fail for unrelated reasons (rc=2).
_repro_rc=0
set +e
# ZBUILD_TESTS_DIR takes the re-entrancy guard's documented exemption for
# fixture-isolated nested runs (test-helpers.sh:29-34, #971). The guard exists to
# stop the ablation gates fork-bombing the test stage; this is a single bounded
# `bash <file>` with its own state dir, which is what the exemption is for. It
# only feeds run-tests.sh's discovery root, and we do not go through run-tests.sh.
env ZBUILD_STATE_DIR="$REPRO_CANARY_DIR" \
    _TPL_STAGE_IO_DESTS_acceptance_gate="file,stdout" \
    ZBUILD_TESTS_DIR="$REPO_ROOT/tests" \
    PATH="$_PRISTINE_PATH" HOME="$_PRISTINE_HOME" \
    bash "$REPO_ROOT/tests/integration/acceptance-gate-test.sh" >/dev/null 2>&1
_repro_rc=$?
set -e

# Order matters: assert the replay RAN before asserting what it wrote. A crashed
# subprocess leaves an empty canary, so the count assertion would log a
# spurious PASS first and the reader would meet the real cause second. (Both
# failure modes were hit while writing this: a mock PATH, then the re-entrancy
# guard — each surfaced as rc=2 with an empty canary.)
assert_eq "[SPEC-2] guard: the replayed test actually ran (rc=0)" "0" "$_repro_rc"

_REPRO_IO_COUNT="$(find "$REPRO_CANARY_DIR" -name '*.json' -path '*/stage-io/*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-2] a replayed acceptance-gate test writes no stage-io into the ambient state dir" \
    "0" "$_REPRO_IO_COUNT"

# Independent oracle for SPEC-1 and SPEC-3: what the CALLER had before setup.
# Deliberately not test-helpers' own ORIG_STATE_DIR — asserting against the
# implementation's private bookkeeping compares it to itself.
_PRE_SETUP_STATE_DIR="${ZBUILD_STATE_DIR:-}"
_PRE_SETUP_ARTIFACT_DIR="${ZBUILD_ARTIFACT_DIR:-}"

# ── SPEC-1 (change): setup_test_env diverts ZBUILD_STATE_DIR off the canary ──
setup_test_env "hermeticity"
_POST_SETUP_STATE_DIR="${ZBUILD_STATE_DIR:-<unset>}"
_POST_SETUP_ARTIFACT_DIR="${ZBUILD_ARTIFACT_DIR:-<unset>}"

if [[ "${ZBUILD_STATE_DIR:-<unset>}" == "$_PRE_SETUP_STATE_DIR" ]]; then
    assert_fail "[SPEC-1] setup_test_env diverts ZBUILD_STATE_DIR away from the ambient canary" \
        "still == canary ($CANARY_DIR)"
elif [[ -z "${ZBUILD_STATE_DIR:-}" || "${ZBUILD_STATE_DIR:-}" == "$TEST_TEMP_DIR"* ]]; then
    # Unset is a valid diversion: stage-io then falls back to ${HOME}/.zbuild/state,
    # and setup_test_env has already sandboxed HOME. An explicit in-sandbox path
    # is equally valid. Either way the ambient value is no longer in force.
    assert_pass "[SPEC-1] setup_test_env diverts ZBUILD_STATE_DIR away from the ambient canary"
else
    assert_fail "[SPEC-1] ZBUILD_STATE_DIR points somewhere unexpected" \
        "expected unset or under $TEST_TEMP_DIR, got ${ZBUILD_STATE_DIR:-<unset>}"
fi

# ── SPEC-3 (change): setup/cleanup is a round trip ──────────────────────────
# Both halves, against the caller-side oracle: setup must have diverted the
# value, and cleanup must put the caller's own value back. Asserting only the
# second half would pass at the merge-base, where nothing diverted it and so
# nothing needed restoring.
cleanup_test_env
_RESTORED_STATE_DIR="${ZBUILD_STATE_DIR:-<unset>}"

if [[ "$_POST_SETUP_STATE_DIR" != "$_PRE_SETUP_STATE_DIR" \
   && "$_RESTORED_STATE_DIR" == "$_PRE_SETUP_STATE_DIR" ]]; then
    assert_pass "[SPEC-3] cleanup_test_env restores the caller's ZBUILD_STATE_DIR after setup diverted it"
else
    assert_fail "[SPEC-3] cleanup_test_env restores the caller's ZBUILD_STATE_DIR after setup diverted it" \
        "pre=$_PRE_SETUP_STATE_DIR post_setup=$_POST_SETUP_STATE_DIR restored=$_RESTORED_STATE_DIR"
fi

# ZBUILD_ARTIFACT_DIR gets the identical unset-then-restore treatment, and
# nothing asserted it. Untagged: not a declared SPEC, but the branch is real
# code and this is the only thing that exercises it.
_RESTORED_ARTIFACT_DIR="${ZBUILD_ARTIFACT_DIR:-<unset>}"
if [[ "$_POST_SETUP_ARTIFACT_DIR" != "$_PRE_SETUP_ARTIFACT_DIR" \
   && "$_RESTORED_ARTIFACT_DIR" == "$_PRE_SETUP_ARTIFACT_DIR" ]]; then
    assert_pass "ZBUILD_ARTIFACT_DIR takes the same divert-then-restore round trip"
else
    assert_fail "ZBUILD_ARTIFACT_DIR takes the same divert-then-restore round trip" \
        "pre=$_PRE_SETUP_ARTIFACT_DIR post_setup=$_POST_SETUP_ARTIFACT_DIR restored=$_RESTORED_ARTIFACT_DIR"
fi

# An ambient EMPTY ZBUILD_STATE_DIR must come back SET-and-empty, not be dropped
# to unset. "unset" and "set but empty" are different states, and the first
# version of this sandboxing collapsed them: `${VAR:-}` at capture plus `-n` at
# restore turned a deliberate `export ZBUILD_STATE_DIR=""` into an unset var.
# No production consumer notices (they all read `${VAR:-...}`), but the harness
# contract is "restore what the caller had", and at the merge-base — which never
# touched the variable — an empty value did survive. This is the regression
# guard for that.
#
# Runs in a subprocess because ORIG_* is captured at SOURCE time, so a single
# process can only ever exercise one ambient value. `bash -c` keeps $0 as `bash`,
# which the #971 re-entrancy guard deliberately exempts.
_empty_probe="$(ZBUILD_STATE_DIR="" ZB_ROOT="$REPO_ROOT" bash -c '
    source "$ZB_ROOT/scripts/lib/helpers.sh"
    source "$ZB_ROOT/scripts/lib/test-helpers.sh"
    setup_test_env "empty-state-dir-probe" >/dev/null 2>&1
    cleanup_test_env >/dev/null 2>&1
    printf "%s" "${ZBUILD_STATE_DIR+set}"
' 2>/dev/null)"
assert_eq "an ambient empty ZBUILD_STATE_DIR is restored as set, not dropped to unset" \
    "set" "$_empty_probe"

print_test_results
exit $((FAIL > 0))
