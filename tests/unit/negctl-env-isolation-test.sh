#!/usr/bin/env bash
# tests/unit/negctl-env-isolation-test.sh
# The acceptance-gate's negative-control sandbox does not leak runner state (#1644).
#
# _negctl_run executes a candidate TESTFILE as a child of the pipeline, so without
# scrubbing it inherits the runner's environment. When it does, unrelated
# assertions in that TESTFILE fail and the gate reports a false
# `not_passing_at_head` — rejecting a correct change. That has happened four
# times, each time discovered the same way and patched by adding one more
# variable to a hand-maintained list:
#
#   #983   test-runner parallelism knobs   (a fork-bomb)
#   #1211  ZBUILD_STAGE_IO_FD              (banners escaping via inherited fd 3)
#   #1567  ZBUILD_STAGE_IO_SEQ_LABEL       (a test asserting a fresh banner)
#   #1644  ZBUILD_RUN_ID                   (flips the router into its in-a-run
#                                            branch; 21 assertions fail in any
#                                            TESTFILE that calls it)
#
# SPEC-2 is the one that matters: it pins the GENERAL property, so a fifth
# variable cannot repeat the series. A test that only checked ZBUILD_RUN_ID would
# pass against a one-line patch and teach us nothing.
#
# SPEC-1[change]: ZBUILD_RUN_ID does not reach the TESTFILE
# SPEC-2[change]: NO runner variable reaches it — including one invented here
# SPEC-3[guard]: the user-shell environment (PATH, HOME) still does
set -uo pipefail
# Not `set -e`: assert_fail returns non-zero when called without a detail arg,
# which under -e aborts before print_test_results — a failing test that exits 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

for _dep in scripts/lib/helpers.sh scripts/lib/test-helpers.sh scripts/lib/acceptance-negctl.sh; do
    if [[ ! -f "$REPO_ROOT/$_dep" ]]; then
        printf 'negctl-env-isolation-test: required dependency missing: %s\n' \
            "$REPO_ROOT/$_dep" >&2
        exit 2
    fi
done
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "negctl sandbox env isolation (#1644)"
setup_test_env "negctl-env-isolation"

# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh" 2>/dev/null
set +e   # acceptance-negctl's sibling libs may set -e; this file asserts on rc

if ! declare -F _negctl_run >/dev/null 2>&1; then
    assert_fail "[SPEC-1] _negctl_run must be defined" "not found after sourcing"
    cleanup_test_env; print_test_results; exit 1
fi

# A probe TESTFILE that records the environment it was handed.
_PROBE="$TEST_TEMP_DIR/probe-test.sh"
_SEEN="$TEST_TEMP_DIR/seen.env"
cat > "$_PROBE" <<PROBE
#!/usr/bin/env bash
env > "$_SEEN"
exit 0
PROBE
chmod +x "$_PROBE"

# Runner state as the pipeline would export it, plus one variable invented for
# this test — nothing in the implementation can know its name, so passing SPEC-2
# requires a scrub that generalizes rather than a list that enumerates.
export ZBUILD_RUN_ID="leak-probe-run-id"
export ZBUILD_A_VARIABLE_INVENTED_BY_THIS_TEST="leak-probe-generic"
export _TPL_STAGE_INVENTED_BY_THIS_TEST="leak-probe-tpl"

_negctl_run "$_PROBE" "$TEST_TEMP_DIR" >/dev/null 2>&1

if [[ ! -s "$_SEEN" ]]; then
    assert_fail "[SPEC-1] the probe TESTFILE must have run" "no env captured at $_SEEN"
    cleanup_test_env; print_test_results; exit 1
fi

# ─── SPEC-1: the specific variable that caused #1644 ────────────────────────
if grep -q '^ZBUILD_RUN_ID=' "$_SEEN"; then
    assert_fail "[SPEC-1] ZBUILD_RUN_ID must not reach the TESTFILE" \
        "$(grep '^ZBUILD_RUN_ID=' "$_SEEN")"
else
    assert_pass "[SPEC-1] ZBUILD_RUN_ID does not reach the TESTFILE"
fi

# ─── SPEC-2: the general property — no runner state at all ─────────────────
# This is what distinguishes a scrub from a patch. The invented variables above
# cannot be in any enumerated list, so only a wildcard scrub passes here.
_leaked="$(grep -E '^(ZBUILD_|_TPL_)' "$_SEEN" | cut -d= -f1 | tr '\n' ' ')"
if [[ -z "$_leaked" ]]; then
    assert_pass "[SPEC-2] no ZBUILD_*/_TPL_* runner state reaches the TESTFILE"
else
    assert_fail "[SPEC-2] the sandbox must scrub ALL runner state, not a known list" \
        "leaked: $_leaked"
fi

# ─── SPEC-3[guard]: the sandbox is not over-scrubbed ───────────────────────
# A TESTFILE still needs a usable shell. Scrubbing PATH would make every test
# fail for the opposite reason — an invariant, so it holds at the merge-base too.
if grep -q '^PATH=' "$_SEEN"; then
    assert_pass "[SPEC-3] PATH still reaches the TESTFILE"
else
    assert_fail "[SPEC-3] PATH must survive the scrub" "no PATH in captured env"
fi
if grep -q '^HOME=' "$_SEEN"; then
    assert_pass "[SPEC-3] HOME still reaches the TESTFILE"
else
    assert_fail "[SPEC-3] HOME must survive the scrub" "no HOME in captured env"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
