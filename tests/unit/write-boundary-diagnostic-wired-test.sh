#!/usr/bin/env bash
# The write-boundary violation log must be wired everywhere a run can halt on it.
#
# write_boundary_violation_recorded names the offending path on three channels:
# stderr, the event stream, and ZBUILD_WRITE_BOUNDARY_LOG. The first two are
# routinely unavailable in practice — most test harnesses discard the runner's
# stderr, and a nested run's event stream dies with its throwaway state dir — so
# the append-only sink is the channel that survives.
#
# It was set in exactly ONE place: the integration job of test.yml. Issue #1839's
# pipeline halted on a write-boundary violation in the e2e tier, inside the
# dogfood workflow — neither of which set it. The run recorded that a violation
# happened and could not say which file caused it, and the disposition is
# `broken`: terminal, not retryable, so there is no second chance to observe it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "write-boundary diagnostic is wired wherever a run can halt on it"
setup_test_env "wb-diagnostic-wired"

_TEST_YML="$REPO_ROOT/.github/workflows/test.yml"
_PIPE_YML="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"

# ─── SPEC-1: the dogfood pipeline names a sink ──────────────────────────────
# This is the workflow that ran #1839. A violation here halts a real run.
_pipe_hits=$(grep -c 'ZBUILD_WRITE_BOUNDARY_LOG' "$_PIPE_YML" 2>/dev/null || true)
assert_gt "[SPEC-1] the dogfood pipeline workflow sets ZBUILD_WRITE_BOUNDARY_LOG" \
    "$_pipe_hits" "0"

# ─── SPEC-2: every suite job that can trip the boundary names a sink ────────
# The e2e tier runs nested pipelines (parity-local-vs-ci, plugin-event-balance),
# so it can trip the fence exactly as the integration tier can.
_e2e_block="$(awk '/^  e2e-mocked:/{f=1} f{print} f&&/^  [a-z]/&&!/^  e2e-mocked:/{if(++n>1)exit}' \
    "$_TEST_YML" 2>/dev/null || true)"
_e2e_hits=$(printf '%s\n' "$_e2e_block" | grep -c 'ZBUILD_WRITE_BOUNDARY_LOG' || true)
assert_gt "[SPEC-2] the e2e job sets ZBUILD_WRITE_BOUNDARY_LOG" "$_e2e_hits" "0"

# ─── SPEC-4: EVERY suite job that runs a tier names a sink ──────────────────
# Now that the shipped watch list covers the system temp again (SPEC-4g), any
# tier can trip the fence — the unit tier dispatches stages through
# plugin_hook_call just as integration does. A job without a sink reports rc=1
# and no path, which is the state that made #1839 undiagnosable.
_tier_jobs_missing=""
while IFS= read -r _job; do
    [[ -z "$_job" ]] && continue
    _block="$(awk -v j="  ${_job}:" '
        $0==j {f=1; next}
        f && /^  [a-z][a-z0-9_-]*:/ {exit}
        f {print}
    ' "$_TEST_YML" 2>/dev/null || true)"
    grep -q 'run-tests.sh' <<< "$_block" || continue
    grep -q 'ZBUILD_WRITE_BOUNDARY_LOG' <<< "$_block" \
        || _tier_jobs_missing="${_tier_jobs_missing}${_job} "
done < <(grep -oE '^  [a-z][a-z0-9_-]*:' "$_TEST_YML" | tr -d ' :' || true)

if [[ -z "$_tier_jobs_missing" ]]; then
    assert_pass "[SPEC-4] every test.yml job that runs a tier sets the sink"
else
    assert_fail "[SPEC-4] every test.yml job that runs a tier sets the sink" \
        "missing: $_tier_jobs_missing"
fi

# ─── SPEC-3: GUARD — the integration job keeps its sink ─────────────────────
# It is the one that already had it; a refactor must not trade one for another.
_int_hits=$(grep -c 'ZBUILD_WRITE_BOUNDARY_LOG' "$_TEST_YML" 2>/dev/null || true)
assert_gt "[SPEC-3] GUARD: test.yml still sets the sink in more than one job" \
    "$_int_hits" "1"

# ─── SPEC-5: the Coverage job is not a black box ───────────────────────────
# It failed on main for a full day with nothing to diagnose from: no timing
# file, no uploaded artifact, no per-file record — only
# "TIMEOUT … exceeded 480s" with every assertion in the killed file passing.
# Every other tier job writes ZBUILD_TEST_TIMING_FILE and uploads it; this one
# records nothing, so the one job whose failure mode is "a file got slower"
# is the only job that cannot say which file, or by how much.
_cov_block="$(awk '/^  coverage:/{f=1} f{print} f&&/^  summary:/{exit}' "$_TEST_YML" 2>/dev/null || true)"
for _need in ZBUILD_TEST_TIMING_FILE upload-artifact; do
    if grep -q "$_need" <<< "$_cov_block"; then
        assert_pass "[SPEC-5] the Coverage job carries $_need"
    else
        assert_fail "[SPEC-5] the Coverage job carries $_need" \
            "coverage job records nothing to diagnose a timeout from"
    fi
done

# ─── SPEC-6: no job-level env uses the `runner` context ────────────────────
# `runner.*` does not exist at JOB level — only inside steps. GitHub rejects the
# whole workflow at STARTUP, so every run reports `failure` with ZERO jobs and
# no annotation naming the cause. From the outside the file looks corrupted.
#
# This shipped: a job-level `ZBUILD_WRITE_BOUNDARY_LOG: ${{ runner.temp }}/…`
# in zbuild-pipeline.yml broke four zbuild-daemon runs, which fail with it
# because the daemon CALLS that workflow (`uses: ./.github/workflows/…`).
#
# SPEC-1..SPEC-5 above did not catch it: they assert the variable is PRESENT and
# that the YAML parses. Both were true. Valid YAML is not a valid workflow, and
# the only thing that distinguishes them here is where the expression sits.
_BAD_CTX=""
for _wf in "$REPO_ROOT"/.github/workflows/*.yml; do
    _hits="$(awk '
        /^    steps:/                 { instep = 1 }
        /^    env:/                   { inenv = (instep ? 0 : 1); next }
        inenv && /\$\{\{ *runner\./   { printf "%s:%d\n", FILENAME, NR }
        /^    [a-z]/ && !/^    env:/  { inenv = 0 }
    ' "$_wf" 2>/dev/null || true)"
    [[ -n "$_hits" ]] && _BAD_CTX="${_BAD_CTX}${_hits} "
done
if [[ -z "$_BAD_CTX" ]]; then
    assert_pass "[SPEC-6] no workflow uses the runner context in job-level env"
else
    assert_fail "[SPEC-6] no workflow uses the runner context in job-level env" \
        "job-level runner.* (rejected at startup): $_BAD_CTX"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
