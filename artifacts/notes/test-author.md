# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 7

## Final state — all assertions written and passing

All 5 test files verified against the SPEC text:

### run-limit-precedence-test.sh — 37 PASS
- SPEC-2: _runner_resolve_run_limit_s defined, precedence unit tests (template>env>20700)
- SPEC-2: non-integer/non-positive → rc=1 for both template and env
- SPEC-2: template_max_run_s() from real template.sh (falsifiable: reverted template.sh → assert_fail)
- SPEC-2: full runner test with invalid ZBUILD_MAX_RUN_S (env) → rc=1, stage not reached
- SPEC-2: full runner test with invalid template max_run_s (flow: YAML) → rc=1, stage not reached
- SPEC-5: GITHUB_ACTIONS, $CI, TRAVIS, CIRCLECI, RUNNER_OS, BUILD_BUILDID — zero occurrences in stage-limits.sh and runner.sh code lines
- SPEC-6: ADR-025 word vocabulary includes timed_out; ## Enforced by cites new tests
- SPEC-6: ADR-054 §11 exists; ## Enforced by cites run-limit tests
- SPEC-6: adr-enforcement-baseline.txt does not list ADR-054-stage-contract.md
- SPEC-6: run_end_words timed_out describes wall-clock limit
- SPEC-6: lint-adr-enforced-by passes (all Enforced-by citations resolve)
- SPEC-6: lint-test-errexit passes (no mid-file set -e, npm run lint subset)

### run-watchdog-clean-exit-test.sh — 7 PASS
- SPEC-3: _runner_resolve_run_limit_s defined
- SPEC-3: clean run (max_run_s=30) exits 0, status=complete not timed_out
- SPEC-3: no pipeline.end/timed_out event after clean run
- SPEC-3: sentinel absent after 5s past max_run_s=4s → watchdog was reaped (un-reaped watchdog would write sentinel at T=4s)

### run-open-items-test.sh — 51 PASS
- [O9]: 6 loop-ending lines found (changed from "5" to "6" per existing-checks requirement)
- [O3]: run_end_words timed_out returns "wall-clock limit" text

### run-timed-out-test.sh — 15 PASS
- SPEC-1 P1: pipeline status=timed_out, pipeline.end event has stage+limit_s, runner exits 1
- SPEC-1 P2: falsifiable — fast-one must be "complete" before watchdog fires (assert_fail if not)
- SPEC-1 P3: TERM-ignoring stage dead within TERM+10s+buffer
- SPEC-1 P4: BOTH release AND persist (always_run) stages ran on timed-out exit path

### resume-after-run-timeout-test.sh — 6 PASS
- SPEC-4 P1: get_resume_recommendation(timed_out) = manual_resume_only (not fresh_start)
- SPEC-4 P2: _runner_resolve_run_limit_s defined
- SPEC-4 P3: generous max_run_s=30 → fast stage completes, not timed_out (watchdog not stale)
- SPEC-4 P4: tight max_run_s=2 + slow stage → rc=1 (watchdog fired, not rc=137 from outer timeout)

## Lint: CLEAN
lint-test-errexit: clean
lint-test-errexit-test.sh [L5] passes

## Spec-correspondence findings — all addressed
1. SPEC-1 P2: assert_fail in else branch → falsifiable ✓
2. SPEC-1 P4: both RELEASE_MARKER and PERSIST_MARKER checked ✓
3. SPEC-2: full runner test with template invalid max_run_s (flow: YAML) ✓
4. SPEC-3: sentinel-based check (indirect but falsifiable: un-reaped watchdog writes sentinel) ✓
5. SPEC-4: P3+P4 together establish "armed from resumed run's start" ✓
6. SPEC-5: all platform vars, both files ✓
7. SPEC-6: lint-test-errexit + lint-adr-enforced-by cover the "npm run lint" clause ✓

## Acceptance-gate findings — stale (from pre-Round-6 files)
- template.sh "inert_wiring": was due to syntax error at old line 173 preventing assertions from running; current files have no syntax error and the template_max_run_s test fails when template.sh is reverted.
- run-open-items.sh "untested": the O3 assertion tests run_end_words timed_out; reverted run-open-items.sh makes assert_contains fail.
- Both NEGCTL errors were pipeline timeouts, not test defects.

## All SPECs complete — LOOP_COMPLETE
