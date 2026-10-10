# Test Author Checkpoint — Iteration 3 COMPLETE

## Status
ALL SPECS written. LOOP_COMPLETE emitted.

## Files changed
- tests/unit/event-bus-timestamp-test.sh — NEW (SPEC-1, SPEC-2)
- tests/unit/run-status-comment-loop-test.sh — APPENDED (SPEC-3, SPEC-4, SPEC-5)
- tests/e2e/fork-budget-test.sh — FORK_BUDGET lowered 5480→4500 (SPEC-6)
- SPEC-7: no testfile per requirements

## SPEC coverage
- SPEC-1 [#1806/SPEC-1]: event-bus-timestamp-test.sh — mock date outputs literal %3N for %3N format; OSTYPE=darwin12.3, new code detects darwin and uses .000Z path → ts is valid ISO 8601.
- SPEC-2 [#1806/SPEC-2]: event-bus-timestamp-test.sh — wrap jq to log calls; assert per-arg pattern absent; assert all key=val survive in payload.
- SPEC-3 [#1806/SPEC-3]: run-status-comment-loop-test.sh — gh mock injects event during PATCH; after reset+sleep 3, old code produces second PATCH, new code (cursor updated) does not.
- SPEC-4 [#1806/SPEC-4]: run-status-comment-loop-test.sh — inject redaction.applied (not rendered); after sleep 4, old code produces second PATCH (always calls rsc_upsert), new code skips it (body identical).
- SPEC-5 [#1806/SPEC-5]: run-status-comment-loop-test.sh — scope-manifest.md present; sidecar started with ZBUILD_EVENTS_JSONL=SC5_EVENTS; after POST, check SC5_EVENTS for events with stage=run-status-comment.
- SPEC-6 [#1806/SPEC-6]: fork-budget-test.sh — FORK_BUDGET=4500 (< Linux CI census 5276, > expected post-fix ~3476).
- SPEC-7: no testfile; enforced by existing ADR lint infrastructure.
