# Test-author notes — issue #1944 (run-level wall-clock watchdog)

## What I read
- design.md: full design with SPEC-1 through SPEC-6
- runner.sh: `_runner_end_on_abort`, `_runner_signal_trap`, `_runner_abort_trap`, existing word list
- abort-propagation.sh: sentinel helpers, word vocabulary (sigint|sigterm|cycle_abort|llm_unavailable|llm_rate_limited|scope_too_large)
- stage-limits.sh: `_route_resolve_knob` pattern — `_runner_resolve_run_limit_s` goes here
- run-open-items.sh: `run_end_words` (no `timed_out` case yet), current word handling
- test-helpers.sh: `mock_plugin_factory`, `mock_v2_result_line`, `setup_git_temp_repo`, `install_template_overlay`
- resume-after-sigint-test.sh: integration test pattern (subprocess run, state check, events check)
- abort-propagation-test.sh: unit test pattern (source lib, mock/stub, assert)
- run-open-items-test.sh [O9]: grep for 5 error lines in runner.sh → will be 6 after impl
- always-run-minimal.yaml: always_run: release fixture template
- ADR-025: word vocab at line 365 (no timed_out yet); Enforced by section at line 372
- ADR-054: §11 doesn't exist yet
- adr-enforcement-baseline.txt: line 53 has ADR-054-stage-contract.md → must be removed after impl

## Key facts
- `_runner_resolve_run_limit_s` does NOT exist yet in stage-limits.sh
- `timed_out` NOT in ADR-025 word vocabulary yet
- ADR-054 does NOT have §11 yet
- adr-enforcement-baseline.txt DOES have ADR-054-stage-contract.md (line 53)
- runner.sh: no CI/GITHUB_ACTIONS in actual code lines (only in comments)
- stage-limits.sh: no CI/GITHUB_ACTIONS at all

## Fail-before reasoning for each SPEC
- SPEC-1: slow stage hangs → `timeout 25` kills runner → pipeline-state.json lacks `timed_out` → fails ✓
- SPEC-2: `_runner_resolve_run_limit_s` not defined → assert_fail fires → test fails ✓
- SPEC-3: `_runner_resolve_run_limit_s` not defined in stage-limits.sh → first assertion fails ✓
- SPEC-4: timed_out run can't be created (no impl) → phase 1 hangs → timeout kills it → state lacks `timed_out` → fails ✓
- SPEC-5: [no-code] no-fail requirement, but grepping for CI in stage-limits.sh → passes before AND after ✓
- SPEC-6: ADR-025 lacks timed_out; ADR-054 lacks §11; baseline.txt still has ADR-054-stage-contract.md → fails ✓

## Progress
- [x] tests/unit/run-open-items-test.sh [O9] — already shows "6"; no change needed
- [x] tests/unit/run-limit-precedence-test.sh [SPEC-2, SPEC-5, SPEC-6] — file existed, complete
- [x] tests/unit/run-watchdog-clean-exit-test.sh [SPEC-3] — file existed, complete
- [x] tests/integration/run-timed-out-test.sh [SPEC-1] — file existed, complete
- [x] tests/integration/resume-after-run-timeout-test.sh [SPEC-4] — CREATED in this run

## DONE
All SPECs have assertions written to disk. resume-after-run-timeout-test.sh was the only missing file.
