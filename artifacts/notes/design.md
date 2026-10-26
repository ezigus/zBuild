# design stage notes — issue #1944

## What I read (initial pass)

- core/pipeline/runner.sh (lines 1-100, 871-1006, 1698-2663, 2813-2857): main() structure, traps, signal trap, abort trap, _runner_end_on_abort, _render_pipeline_end, _pipeline_status_glyph, _runner_render_open_items
- scripts/lib/abort-propagation.sh: full file — abort word vocabulary (6 words), sentinel mechanics, first-wins
- scripts/lib/stage-limits.sh: full file — _route_resolve_knob pattern (template > env > manifest > constant)
- scripts/lib/proc-group.sh: full file — zbuild_pg_kill (refuses own group), _zbuild_pg_term_then_kill (TERM+grace+KILL)
- core/pipeline/template.sh: template_stage_router_timeout and related accessors, _TPL_SOURCE_FILE pattern
- docs/adr/ADR-025-abort-propagation.md: full — abort word list, Enforced by section
- docs/adr/ADR-054-stage-contract.md: full — §6a (disposition words incl. timed_out), §7 (always-run/release/persist), §9 (per-stage router knobs); timed_out IS already a disposition word in §6a
- config/adr-enforcement-baseline.txt: ADR-054 IS in baseline (line 53); ADR-025 is NOT (has Enforced by)
- core/state/resume.sh: get_resume_recommendation — timed_out falls through to `*) → fresh_start` (NO resume)
- core/pipeline/state_helpers.sh: _set_pipeline_status — no status validation, just sets the field
- tests/unit/abort-propagation-test.sh: A8 loop (line 86) enumerates 6 abort words → wrong by omission
- tests/unit/runner-pipeline-end-test.sh: T9 STATUSES (lines 155-161) enumerates 5 pipeline statuses → wrong by omission
- tests/unit/run-open-items-test.sh: O3 loop (line 102) tests specific reasons; O9 (line 189) asserts EXACTLY "5" runner loop-ending lines → will break if timed_out arm added to _runner_end_on_abort (count becomes 6) → supersedes
- tests/integration/resume-state-machine-test.sh: no hardcoded status count, just specific transition tests; not wrong by omission

## What I read (refinement pass)

- docs/adr/ADR-006-resume-contract.md lines 140-149: exhaustive pipeline status enum table — WRONG BY OMISSION when timed_out added
- docs/adr/ADR-015-stage-io-capture.md lines 819-823: exhaustive pipeline status → glyph/color table — WRONG BY OMISSION when timed_out added
- scripts/lib/run-open-items.sh lines 79-116: run_end_words() case statement — timed_out falls through to catch-all; needs explicit case added

## What I read (iteration 9 verification pass)

Verified current worktree state after prior build:
- runner.sh lines 2529-2540: `_runner_abort_trap` fires on EXIT and kills watchdog via SIGKILL at line 2539; uses `:-0` default → potential issue if PID empty sends SIGKILL to PG 0; bugs table updated to use `:-` (empty default instead)
- runner.sh line 2734: `trap '_runner_abort_trap' EXIT` — fires on ALL exits (clean and abort)
- runner.sh lines 2776-2818: watchdog subshell armed after traps; `_RUNNER_WATCHDOG_PID=$!` at line 2818

## What I read (current verification pass — after test stage failure)

Git log shows latest commit is `f915476a test-author: acceptance assertions for 6 SPEC(s), still failing their check`.
The test stage ran on an EARLIER state (before f915476a). The current worktree is test-author's latest output.

**Verified state of ALL 4 new test files in current worktree (f915476a):**

- `tests/unit/run-watchdog-clean-exit-test.sh`: NO `set -e` patterns (FIXED). Uses `_clean_rc=0; (...) || _clean_rc=$?` pattern throughout (158 lines).
- `tests/integration/run-timed-out-test.sh`: NO `set -e` patterns (FIXED, 382 lines). P4 at lines 312-378 tests BOTH release AND persist markers (FIXED). P2 at lines 236-255 uses conditional assert_pass/assert_fail correctly (not both assert_pass — FIXED).
- `tests/unit/run-limit-precedence-test.sh`: Line 213 uses correct `( cd "$MISCFG_OVERLAY" && ZBUILD_MAX_RUN_S="not-a-number" bash "$RUNNER" ... )` syntax (FIXED). Line 173 is a comment (FIXED). Has lint-test-errexit assertion at line 459 (FIXED).
- `tests/integration/resume-after-run-timeout-test.sh`: NO `set -e` patterns (FIXED, 238 lines). P1-P4 structure correct.

**Remaining bug — runner.sh lines 2539-2540:**
```
2539:        kill -KILL "${_RUNNER_WATCHDOG_PID:-0}" 2>/dev/null || true
2540:        wait "${_RUNNER_WATCHDOG_PID:-0}" 2>/dev/null || true
```

BOTH use `:-0`:
- `kill -KILL "${_RUNNER_WATCHDOG_PID:-0}"` when empty → `kill -KILL 0` → SIGKILL to process group (kills test harness)
- `wait "${_RUNNER_WATCHDOG_PID:-0}"` when empty → `wait 0` → waits for ALL background processes (hangs)

Fix: `:-` (empty default) for BOTH lines. `kill -KILL ""` fails silently (2>/dev/null || true). `wait ""` fails silently.

**run-open-items-test.sh O3 loop (lines 100-105): timed_out NOT in loop.**
The `run_end_words "timed_out"` function exists in run-open-items.sh (line 107) and returns "stopped: the run exceeded its wall-clock limit". But there's no assertion in run-open-items-test.sh testing this output. O9 at line 189 says "6" (FIXED from 5). The bugs table entry for this is still valid.

**run-watchdog-clean-exit-test.sh S3-4: no state-file re-read after sleep.**
The test-author checker found that SPEC-3's requirement "after waiting past max_run_s the status is still the stage-driven result" is not directly verified: the test checks the state file BEFORE sleep (S3-2), then sleeps and checks only the sentinel (S3-4). No state-file re-read after sleep. SPEC-3 needs updating.

**run-open-items.sh line 107:** `timed_out) printf 'stopped: the run exceeded its wall-clock limit%s' "$with" ;;` — the function exists and returns the right message. The O3 loop just needs `timed_out` added.

## Key architectural findings (carried forward)

1. **No existing run-level limit**: only per-stage router.timeout_s knobs. This is entirely new.
2. **Abort word vocabulary** (ADR-025): 6 words → 7 with timed_out.
3. **zbuild_pg_kill refuses its own group** — watchdog uses raw kill commands.
4. **Sentinel first-wins**: watchdog writes timed_out BEFORE sending TERM → SIGTERM trap's sentinel call is a no-op → timed_out propagates correctly.
5. **resume.sh** updated to return manual_resume_only for timed_out status.
6. **EXIT trap kill must use `:-` not `:-0`** — avoids SIGKILL to PG 0 when watchdog never armed; `wait 0` would hang waiting for all background processes.
7. **ADR-054 §9** already exists for per-stage router config; new run-level limit goes in §11.
8. **O9 count assertion** superseded: 5 → 6 loop-ending lines when timed_out arm added (already fixed in current worktree).
