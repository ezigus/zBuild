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
- run-timed-out-test.sh, run-watchdog-clean-exit-test.sh, resume-after-run-timeout-test.sh: NO `set +e`/`set -e` patterns in current worktree (bugs already fixed from prior build iteration)
- run-limit-precedence-test.sh: syntax error on old line 173 is fixed; now correctly uses `( cd ... && ZBUILD_MAX_RUN_S=... bash ... )` at line ~213

## Design iteration 9 — what changed

The ONLY design-stage finding was: **R-10 not covered by any SPEC**.

Fix: added `covers: R-10` to SPEC-1. SPEC-1 covers the primary integration test (run-timed-out-test.sh). Once the implementation bugs in the bugs table are all fixed and SPEC-1 through SPEC-6 pass, both `npm test` and `npm run lint` are green → R-10 is met.

Also clarified in the bugs table Decision point 3:
- Changed `:-0` to `:-` for the watchdog kill default (empty = no kill when watchdog never armed; `0` = SIGKILL entire PG, which kills the test harness)

All other scope entries, acceptance criteria, and findings are unchanged from iteration 8.

## Key architectural findings (carried forward)

1. **No existing run-level limit**: only per-stage router.timeout_s knobs. This is entirely new.
2. **Abort word vocabulary** (ADR-025): 6 words → 7 with timed_out.
3. **zbuild_pg_kill refuses its own group** — watchdog uses raw kill commands.
4. **Sentinel first-wins**: watchdog writes timed_out BEFORE sending TERM → SIGTERM trap's sentinel call is a no-op → timed_out propagates correctly.
5. **resume.sh** updated to return manual_resume_only for timed_out status.
6. **EXIT trap kill must use `:-` not `:-0`** — avoids SIGKILL to PG 0 when watchdog never armed.
7. **ADR-054 §9** already exists for per-stage router config; new run-level limit goes in §11.
8. **O9 count assertion** superseded: 5 → 6 loop-ending lines when timed_out arm added.
