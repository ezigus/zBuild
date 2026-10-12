# Plan notes — issue #1944 (run-level wall-clock limit)

## What I read

- `core/pipeline/runner.sh` (3975 lines) — main(), EXIT trap, _runner_abort_trap, _runner_signal_trap, _runner_end_on_abort, _runner_dispatch_always_run
- `core/pipeline/template.sh` — load_template(), _TPL_PR_DRAFT pattern (top-level key parsing), template_stage_router_timeout accessor pattern
- `scripts/lib/abort-propagation.sh` — _zbuild_arm_abort_sentinel, _zbuild_abort_reason (first-recorded-wins), word list
- `scripts/lib/proc-group.sh` — zbuild_pg_kill, _zbuild_pg_term_then_kill
- `scripts/lib/stage-limits.sh` — _route_resolve_knob pattern (template > env > manifest > default)
- `docs/adr/ADR-054-stage-contract.md` — §6a (timed_out disposition word), §9 (router knobs table needing max_run_s)
- `docs/adr/ADR-025-abort-propagation.md` — #1850 amendment (word list, _runner_end_on_abort map)
- `config/templates/simple.yaml` — max_run_s not present yet, always_run: [release, persist]
- `config/adr-enforcement-baseline.txt` — ADR-054-stage-contract.md is baselined (0 Enforced by sections); ADR-025 has its section already
- `scripts/lib/lint-adr-enforced-by.sh` — checks that section exists AND names ≥1 backticked path that exists on disk

## Conclusions

**Watchdog mechanism:**
- Background bash subprocess: writes `timed_out` to `$ZBUILD_STATE_DIR/.abort.signal`, then sends SIGTERM to the runner PID
- The first-recorded-wins rule in _zbuild_arm_abort_sentinel means the sentinel has `timed_out` before the runner's TERM trap runs, which calls `_zbuild_arm_abort_sentinel "sigterm"` — that reads the prior `timed_out` from the sentinel and short-circuits; `_ZB_ABORT_REASON` becomes `timed_out`
- The watchdog PID is stored in `_RUNNER_WATCHDOG_PID`; the EXIT trap kills it before dispatching always_run

**Limit resolution (template > env > default):**
- `_TPL_MAX_RUN_S` — parsed in load_template() from top-level YAML key `max_run_s`
- `template_max_run_s()` — accessor (reads `_TPL_SOURCE_FILE` like template_stage_negctl_timeout)
- `_runner_resolve_run_limit_s()` in runner.sh — template_max_run_s() > ZBUILD_MAX_RUN_S > 20700; validates both sources are positive integers, returns misconfigured on invalid
- `_RUNNER_MAX_RUN_S` — global storing the resolved value, used in _runner_end_on_abort event

**abort word `timed_out`:**
- Already defined in ADR-054 §6a as a disposition word
- Needs to be added to the ADR-025 word list comment in abort-propagation.sh
- _runner_end_on_abort: add `timed_out` to the `llm_unavailable|llm_rate_limited|scope_too_large` arm (maps to status `aborted`, resumable); event carries `limit_s=$_RUNNER_MAX_RUN_S` and the in-flight unit

**ADR amendment implications:**
- ADR-054 §9 amended: add `max_run_s` row and `ZBUILD_MAX_RUN_S` row to the router knobs table; add `## Enforced by` section; remove ADR-054 from config/adr-enforcement-baseline.txt
- ADR-025 amended: add `timed_out` to the word list; add § describing the run-limit path

**Tests needed (TDD order):**
1. tests/unit/run-limit-precedence-test.sh — AC 5: template > ZBUILD_MAX_RUN_S > 20700, invalid values refused as misconfigured
2. tests/unit/run-watchdog-clean-exit-test.sh — AC 6: watchdog gone after run exits within limit
3. tests/integration/run-timed-out-test.sh — ACs 1-4: planted hang, timed_out disposition naming stage+limit, process group killed after TERM+10s, release+persist run
4. tests/integration/resume-after-run-timeout-test.sh — AC 7: run stopped at limit, resumed, not stopped at once

## Assumptions / gaps

- #1801 (stage-level limit) is listed as a prerequisite ("all three edit runner.sh main() and the exit trap") but is NOT yet in the codebase (no ZBUILD_MAX_STAGE_S found). The "TERM → KILL after 10 s, as #1801 decides" grace period therefore cannot reference #1801's implementation; we use zbuild_pg_kill's existing _zbuild_pg_term_then_kill with 10s grace passed explicitly.
- "Same behaviour locally and in CI" (AC 8) is structural — no branch on platform; verified by the integration tests which run in CI. No separate test is written for it.
- The watchdog runs as a child of the runner but in its own process group (set -m at spawn) so the runner's TERM trap does not reflexively kill it when processing a group kill. The watchdog's SIGTERM write-and-exit is fast enough that it will have exited before the KILL sweep.
- resume-after-run-timeout test needs two actual runner invocations; mocking is required to keep the test fast (small max_run_s, planted hang plugin for first run; normal completion for second).
