# Build Checkpoint — #2032 iteration 1 — COMPLETE

## Changes made

All 9 SPEC tests now pass.

1. `config/event-schema.json`: Added `cycle.member_unfinished.suppressed_convergence` after the two existing suppressed_convergence events.

2. `core/pipeline/cycle-orchestrator.sh`: Added generic suppression block after line 2580 — fires when `converged==0 AND _iter_did_not_finish==1`, emits `cycle.member_unfinished.suppressed_convergence`.

3. `plugins/agent/spec-coverage/plugin.sh`:
   - Added optional `disposition` 5th param to `_scv_write` (default 'complete')
   - Added tempfile rc capture for `route_to_model` call
   - When no parseable verdict and rc!=0, classifies rc → passes disposition to `_scv_write`

4. `plugins/agent/spec-correspondence/plugin.sh`:
   - Added optional `_rc_file` 3rd param to `_sc_call` (writes rc to file inside subshell)
   - Added optional `disposition` 5th param to `_sc_write_result` (default 'complete')
   - Created tempfile in `spec_correspondence_run`, passed to all `_sc_call` calls
   - After all calls, reads rc, classifies, passes disposition to `_sc_write_result`
   - Added `# disposition-ok:` annotation before unavailable fallback

5. `plugins/agent/review-report/plugin.sh`:
   - In failed-lens loop, captures first non-zero rc
   - Classifies via `_router_rc_classify` + `router_reason_disposition`
   - Uses classified disposition instead of hardcoded "complete"
   - Added `# disposition-ok:` annotation before unavailable fallback
   - Removed stale `#2187: the report ran; each lens reports its own cause` comment

6. `docs/adr/ADR-063-budget-disclosure-and-partial-output.md`:
   - Status changed to "Accepted, amended 2026-10-05 by #2032"
   - Added amendment backpointer referencing #2187
   - Removed prescriptive `exhausted` as §3 disposition word
   - Removed `exhausted → escalate` as §4 engine action
   - Replaced "One helper renders the budget block" with per-stage `_<stage>_budget_guidance` helpers language
   - Updated §3/§4 to use `timed_out`/`out_of_turns` vocabulary

7. `docs/adr/ADR-021-pipeline-cycle-semantics.md`:
   - Added amendment note for new suppression case
   - Added `cycle.member_unfinished.suppressed_convergence` to event schema table

## All done
