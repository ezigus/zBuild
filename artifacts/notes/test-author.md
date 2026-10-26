# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 11

## Round 11 work

**Single outstanding finding from round 2 of 2 (test-author check):**
SPEC-3's S3-4 state-file assertion was wrapped in `if [[ -f "$_sentinel_state_file" ]]`,
making it conditional: if the state file was absent, the assertion was silently skipped
rather than failing. The checker flagged this as "cannot be determined from the assertion
code" whether the sleep preceded the read, because the assertion didn't ALWAYS fire.

### Change made to tests/unit/run-watchdog-clean-exit-test.sh

In the S3-4 section (lines 143–161), replaced the conditional `if [[ -f ... ]]` block
with an UNCONDITIONAL three-way assertion:

```bash
sleep 5

_sentinel_state_file="$ZBUILD_STATE_DIR/pipeline-state.json"
_post_sleep_status="$(jq -r '.status // empty' "$_sentinel_state_file" 2>/dev/null || true)"
if [[ "$_post_sleep_status" == "timed_out" ]]; then
    assert_fail "..." "status is timed_out — watchdog fired after runner exited..."
elif [[ -n "$_post_sleep_status" ]]; then
    assert_pass "... ${_post_sleep_status} ..."
else
    assert_fail "..." "pipeline-state.json absent or status empty..."
fi
```

Key improvements:
1. `sleep 5` is unconditional and top-level — unambiguously before the read
2. `jq` reads the file directly (no `if [[ -f ]]` guard); fails gracefully with `|| true`
3. THREE branches: `timed_out` → fail, non-empty → pass, empty → fail
4. EVERY code path fires either assert_fail or assert_pass — no silent skip

Why falsifiable:
- If the watchdog is NOT reaped, it fires 4s after the runner exits (since the runner
  exits well before the 4s limit), writing `status=timed_out`. The `sleep 5` ensures
  the un-reaped watchdog has had time to fire. The first branch catches this.
- If the state file is absent, the else branch asserts_fail — the test cannot trivially
  pass by skipping the check.

### Verified

- `bash -n tests/unit/run-watchdog-clean-exit-test.sh` → SYNTAX OK
- `bash scripts/lib/lint-test-errexit.sh` → clean

## All files — current state

### tests/unit/run-watchdog-clean-exit-test.sh — assertions (updated round 11)
- [#1944/SPEC-3] S3-1: _runner_resolve_run_limit_s defined (fails before impl)
- [#1944/SPEC-3] S3-2: clean run exits 0 + pipeline status is complete (not timed_out)
- [#1944/SPEC-3] S3-3: no pipeline.end/timed_out event in events log
- [#1944/SPEC-3] S3-4: clean run exits 0 with max_run_s=4 → sleep 5 past max_run_s
  → UNCONDITIONAL state-file read (jq, no if guard)
  → three-way assert: timed_out=fail, non-empty=pass, empty=fail [FIXED round 11]
  → abort sentinel absent (watchdog was reaped)

### tests/unit/run-limit-precedence-test.sh — unchanged from round 9
- [#1944/SPEC-2] _runner_resolve_run_limit_s defined
- [#1944/SPEC-2] precedence unit tests (template>env>20700)
- [#1944/SPEC-2] non-integer/non-positive → rc=1 for both template and env
- [#1944/SPEC-2] template_max_run_s() from real template.sh
- [#1944/SPEC-2] full runner: invalid ZBUILD_MAX_RUN_S → rc=1, no dispatch, source named
- [#1944/SPEC-2] full runner: invalid template max_run_s → rc=1, no dispatch, source named
- [#1944/SPEC-5] no GITHUB_ACTIONS, bare $CI, TRAVIS, CIRCLECI, RUNNER_OS, BUILD_BUILDID
- [#1944/SPEC-6] ADR-025 timed_out in vocabulary + Enforced by cites new tests
- [#1944/SPEC-6] ADR-054 §11 exists + Enforced by cites run-limit tests
- [#1944/SPEC-6] ADR-054-stage-contract.md removed from adr-enforcement-baseline.txt
- [#1944/SPEC-6] run_end_words timed_out describes wall-clock limit
- [#1944/SPEC-6] lint-adr-enforced-by passes
- [#1944/SPEC-6] lint-test-errexit passes

### tests/unit/run-open-items-test.sh — unchanged
- [O9]: 6 loop-ending lines (updated from 5→6 in prior round)

### tests/integration/run-timed-out-test.sh — unchanged from round 10
- [#1944/SPEC-1] P1: status=timed_out in state + pipeline.end event with stage + limit_s
- [#1944/SPEC-1] P2: fast-one=complete proves watchdog fires independently of dispatch
- [#1944/SPEC-1] P3: TERM-ignoring stage dead within TERM+10s
- [#1944/SPEC-1] P4: release AND persist (always_run) both execute on timed-out exit

### tests/integration/resume-after-run-timeout-test.sh — unchanged from round 10
- [#1944/SPEC-4] P1: get_resume_recommendation(timed_out) = manual_resume_only
- [#1944/SPEC-4] P2: _runner_resolve_run_limit_s defined
- [#1944/SPEC-4] P3: resumed run with generous max_run_s completes (not timed_out)
- [#1944/SPEC-4] P4: resumed run with tight max_run_s times out (watchdog is armed)

## Lint: CLEAN
- lint-test-errexit: clean (no mid-file set -e)
- All 4 test files: SYNTAX OK

## LOOP_COMPLETE
