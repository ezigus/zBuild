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

- docs/adr/ADR-006-resume-contract.md lines 140-149: exhaustive pipeline status enum table (in_progress, complete, interrupted, aborted, failed, preflight_failed) — WRONG BY OMISSION when timed_out added
- docs/adr/ADR-015-stage-io-capture.md lines 819-823: exhaustive pipeline status → glyph/color table — WRONG BY OMISSION when timed_out added
- scripts/lib/run-open-items.sh lines 79-116: run_end_words() case statement — timed_out falls through to catch-all; needs explicit case added
- core/pipeline/runner.sh _runner_abort_trap (2487-2559): sets pipeline status "interrupted" on exit; does NOT check abort word — the timed_out arm needs to be in _runner_end_on_abort (called from dispatch points), AND the signal trap (line 2652) overwrites _RUNNER_ABORT_REASON with the signal word, which must be amended to read from sentinel post-arm
- core/pipeline/runner.sh _runner_render_open_items (line 996): gate is `failed|interrupted|aborted` — needs timed_out added
- tests/integration/always-run-exit-paths-test.sh: tests specific exit paths for always-run stages; does NOT enumerate all cases exhaustively; not wrong by omission
- tests/integration/pipeline-resume-test.sh: tests specific get_resume_recommendation cases; does NOT enumerate all manual_resume_only cases; not wrong by omission

## Key architectural findings

1. **No existing run-level limit**: only per-stage router.timeout_s knobs. This is entirely new.

2. **Abort word vocabulary** (ADR-025 #1850): sigint | sigterm | cycle_abort | llm_unavailable | llm_rate_limited | scope_too_large. Adding timed_out grows this set.

3. **zbuild_pg_kill in proc-group.sh REFUSES ITS OWN GROUP** — the watchdog runs in the runner's PG, so it cannot use zbuild_pg_kill to kill that PG. Watchdog must use raw kill commands instead.

4. **Watchdog design**: background subshell captures _RUNNER_RUN_PGID at arm time (before & ), then sleeps, writes timed_out to sentinel, kills the runner PG with TERM + 10s + KILL. Does NOT source proc-group.sh — uses raw kill/sleep.

5. **Sentinel first-wins**: _zbuild_arm_abort_sentinel is no-op if a word is already recorded. Watchdog writes timed_out BEFORE sending TERM → runner's SIGTERM trap calls _zbuild_arm_abort_sentinel("sigterm") which is a no-op → _RUNNER_ABORT_REASON must be read from the sentinel after arming (not from the signal word) for timed_out to propagate correctly.

6. **resume.sh get_resume_recommendation** falls through to `*) → fresh_start` for unknown statuses. A timed_out pipeline-state would NOT be resumable unless resume.sh is updated to handle `timed_out → manual_resume_only`.

7. **timed_out disposition** already exists in disposition.sh for STAGE-level use. This change adds it as a PIPELINE-level abort word and pipeline status.

8. **O9 count assertion**: run-open-items-test.sh O9 asserts EXACTLY 5 runner "loop-ending lines." Adding a timed_out arm to _runner_end_on_abort adds a 6th matching line → O9 is SUPERSEDED.

9. **_render_pipeline_end has a catch-all** (line 947: `*) word="$status"`) so `timed_out` would render as "Pipeline timed_out:" without a specific case — this is acceptable. But _pipeline_status_glyph and _pipeline_status_color need explicit timed_out → fail cases (currently `*` gives `?` glyph / yellow color).

10. **proc-group.sh is NOT sourced by runner.sh** — only by route.sh. Watchdog uses inline kill commands (no zbuild_pg_kill needed, since it's killing its own PG which zbuild_pg_kill refuses anyway).

11. **ADR-006 and ADR-015 missed in previous pass** — both enumerate the pipeline status set exhaustively and are wrong by omission when timed_out is added. Added to scope in refinement pass.

## Scope — confirmed exhaustive

### Wrong by omission (closed-set enumerations that grow):
- tests/unit/abort-propagation-test.sh (A8 abort word loop, line 86)
- tests/unit/runner-pipeline-end-test.sh (T9 STATUSES array, lines 155-161)
- tests/unit/run-open-items-test.sh (O3 reason loop, line 102)
- tests/golden/pipeline-end/ — two new golden files needed
- docs/adr/ADR-006-resume-contract.md (pipeline status enum table, lines 140-149) [NEW]
- docs/adr/ADR-015-stage-io-capture.md (glyph/color table, lines 819-823) [NEW]

### Superseded by behavior change:
- tests/unit/run-open-items-test.sh O9: asserts count=5, becomes 6 when timed_out arm added to _runner_end_on_abort

### ADR baseline:
- config/adr-enforcement-baseline.txt — remove ADR-054-stage-contract.md when ## Enforced by added

## WIRING

Primary: core/pipeline/runner.sh — calls _runner_resolve_run_limit_s(), arms watchdog, modifies _runner_abort_trap and _runner_end_on_abort for timed_out
Secondary: core/pipeline/template.sh — provides template_max_run_s() which _runner_resolve_run_limit_s() calls
