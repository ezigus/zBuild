# spec-correspondence notes — issue #1944

## Run context

19 files changed since last run. The assertions I am judging reflect those changes.
I compare each requirement literally against what the assertion code actually tests.

---

## SPEC-1

**Requirement clauses:**
1. Pipeline status `timed_out` in pipeline-state.json when wall-clock exceeds max_run_s
2. `pipeline.end` event carries `status=timed_out`, in-flight stage, and `limit_s`
3. Watchdog fires even when engine is idle between dispatches (not only inside a stage)
4. A process that ignores TERM is dead within TERM+10s
5. Release and persist execute on **every** timed-out exit path

**Assertion analysis:**
- P1: checks rc=1, state status=timed_out, pipeline.end status=timed_out, stage field, limit_s — covers clauses 1 and 2.
- P2: checks pipeline status=timed_out AND that `fast-one` stage_status=complete before watchdog fired. The fast-one-completed check correctly has assert_pass in the true branch and assert_fail in the false branch (previous finding about "always assert_pass in both branches" no longer applies to current code). However, showing fast-one completed only proves the watchdog fired after fast-one ended — not specifically that the engine was idle (no stage running at all) at the moment of firing. A slow second stage could have been active. Clause 3 is only indirectly addressed.
- P3: checks runner exits non-zero within TERM+10s+buffer and that the TERM-ignoring PID is dead. Covers clause 4.
- P4: checks both RELEASE_MARKER and PERSIST_MARKER on the timed-out exit path (previous finding about missing persist is resolved). However, "every timed-out exit path" — P4 tests one specific path; P1, P2, P3's timed-out paths are not checked for release/persist execution.

**Verdict: partial** — idle-between-dispatches is only indirectly evidenced (fast-one complete ≠ engine-idle); "every timed-out exit path" for release/persist is tested in P4 only.

---

## SPEC-2

**Requirement clauses:**
1. Resolution precedence: template max_run_s > ZBUILD_MAX_RUN_S > 20700
2. Non-integer or non-positive value in **template** OR **env** → disposition=misconfigured, run does not reach dispatch loop

**Assertion analysis:**
- Precedence: all four combinations tested at unit (function) level — covers clause 1.
- Env case end-to-end: rc=1, stage marker absent, state file checked for disposition=misconfigured — covers env half of clause 2.
- Template case end-to-end: `_miscfg_tpl_rc`=1 and `STAGE_MARKER_TPL` absent checked — but there is NO check that pipeline-state.json carries `disposition=misconfigured` for the template case (only rc and stage-not-run are checked). The requirement equally requires `disposition=misconfigured` for both the env and template invalid-value paths.

**Verdict: partial** — the template-case end-to-end test verifies rc=1 and dispatch loop not reached, but does not verify disposition=misconfigured in pipeline-state.json for that path.

---

## SPEC-3

**Requirement clauses:**
1. A run that finishes within max_run_s exits with its own pipeline status unchanged
2. The watchdog process does not exist after the runner process exits

**Assertion analysis:**
- Clause 1: rc=0, status complete (not timed_out), no timed_out event — fully covered.
- Clause 2: The assertion tests for the absence of `_ABORT_SENTINEL` after the runner exits. The label says "watchdog killed: abort sentinel absent." An absent sentinel means the watchdog did not fire, but it does not confirm the watchdog process itself is dead. A watchdog that is still running in the background but has not yet fired would also leave the sentinel absent. Process non-existence would require checking that the watchdog PID is gone, not just that it didn't write a sentinel.

**Verdict: partial** — clause 1 is established; clause 2 (watchdog process does not exist) is tested only via sentinel absence, which is a proxy for "watchdog did not fire" rather than direct evidence the process is gone.

---

## SPEC-4

**Requirement clauses:**
1. A resumed run is not stopped immediately
2. Watchdog is armed from the resumed run's wall-clock start, not the original run's

**Assertion analysis:**
- P1: `get_resume_recommendation(timed_out) = manual_resume_only` — tests the advisory label, not the watchdog timing.
- P2: `_runner_resolve_run_limit_s` is defined — necessary but not sufficient.
- P3: Resumed run status is NOT timed_out — establishes the run completes without immediate timeout. If the original wall-clock were used (with near-zero time remaining), the run would time out immediately; P3 passes only when that doesn't happen. However, P3's assert_pass condition (status != timed_out) is also satisfied by a completely disarmed watchdog.
- P4: A resumed run with a slow stage ends with status=timed_out — establishes the watchdog IS armed on resume (a disarmed watchdog would cause P4 to fail). Together with P3, this demonstrates armed-from-resume behavior.

The combination P3+P4 establishes: watchdog fires on long resumed runs (P4), and doesn't fire on short resumed runs that complete successfully (P3). For "from the resumed run's wall-clock start, not the original run's" to be established, P3's test scenario must be arranged so that if the original clock were used, the resumed run would time out. This is a test-setup assumption that cannot be verified from the assertion code alone. The assertion code itself doesn't encode the timing parameters or demonstrate measurement of the timer origin.

**Verdict: partial** — P4 resolves the "watchdog not armed at all" gap from the prior run; but the specific claim "armed from the resumed run's wall-clock start, not the original run's" is inferred from the combination of P3+P4 and depends on test-scenario timing parameters that are not visible in the assertion.

---

## SPEC-5

**Requirement:** `scripts/lib/stage-limits.sh` and `core/pipeline/runner.sh` contain no reference to GITHUB_ACTIONS, CI, or **any platform-specific variable** in the new code.

**Assertion analysis:**
The assertion checks: GITHUB_ACTIONS (both files), bare $CI in non-comment lines (both files), TRAVIS, CIRCLECI, RUNNER_OS, BUILD_BUILDID (both files). The previous finding about missing TRAVIS/CIRCLECI/RUNNER_OS/BUILD_BUILDID is resolved in the current assertion.

However, "any platform-specific variable" is an open-ended category. Many CI/CD platform variables are not in the enumerated list (CODEBUILD_BUILD_ID, BITBUCKET_BUILD_NUMBER, DRONE_BUILD_NUMBER, APPVEYOR, TF_BUILD, SYSTEM_TEAMFOUNDATIONCOLLECTIONURI, etc.). The assertion checks a finite set; the requirement's prohibition is unlimited.

**Verdict: partial** — the checked set now includes the most common CI variables, but "any platform-specific variable" is unbounded and the assertion covers only an enumerated subset.

---

## SPEC-6

**Requirement clauses:**
1. ADR-025 names timed_out in its word vocabulary with Enforced-by entries citing new tests
2. ADR-054 gains §11 for the run-level limit with Enforced-by
3. config/adr-enforcement-baseline.txt no longer lists ADR-054-stage-contract.md
4. `npm test` and `npm run lint` pass

**Assertion analysis:**
- Clauses 1–3: checked via grep/awk in the ADR files and baseline file — covered.
- `run_end_words` function checked for wall-clock description — covered.
- `lint-adr-enforced-by.sh` run directly — covers one lint sub-command.
- `lint-test-errexit.sh` run directly — covers another lint sub-command.
- Clause 4 (`npm test` and `npm run lint`): neither full command is executed. Two specific lint sub-scripts are run, but `npm run lint` invokes ~20 lint scripts in sequence. None of the test suite is executed. The requirement's explicit condition "npm test and npm run lint pass" is not established by the assertion.

**Verdict: partial** — ADR content, baseline, and two lint sub-scripts are verified; the explicit "npm test" and full "npm run lint" conditions are not exercised.

---

## Summary

SPEC-1: partial  
SPEC-2: partial  
SPEC-3: partial  
SPEC-4: partial  
SPEC-5: partial  
SPEC-6: partial  

## Findings addressed from prior run

- SPEC-1 P2 "always assert_pass in both branches": no longer true in current assertion — correctly uses assert_fail in else branch. Idle-between-dispatches gap remains.
- SPEC-1 P4 "only release, not persist": both markers now checked. "Every exit path" gap remains.
- SPEC-5 "missing TRAVIS/CIRCLECI/etc.": these variables are now checked in the assertion. "Any platform-specific variable" (unbounded) gap remains.
- SPEC-4 "disarmed watchdog satisfies P3": P4 now establishes the watchdog fires on resumed runs, addressing this gap. "Armed from resumed start specifically" gap remains.
