# Build checkpoint — issue #1806 iter 1

## Files read and key findings:

### tests/unit/event-bus-timestamp-test.sh
- SPEC-1: simulates BSD date (outputs literal %3N), sets OSTYPE=darwin12.3.0, expects no literal %3N in timestamp
- SPEC-2: wraps jq to count calls, checks per-arg pattern `{($k): $v}` is ABSENT, checks payload fields preserved
- Old code: checks `ZBUILD_PLATFORM == "macos"` → wrong on macOS host with ZBUILD_PLATFORM=linux
- Fix: add `_eb_host_is_mac` helper using OSTYPE, use it instead

### tests/unit/run-status-comment-loop-test.sh
- SPEC-3 (#1806): gh mock injects event into events.jsonl during PATCH; expects no second PATCH
  - Fix: after rsc_flush, re-read file size and update last_size
- SPEC-4 (#1806): inject redaction.applied event after first PATCH; expects no second PATCH (body unchanged)
  - Fix: compare body_file to prev body with cmp -s; skip rsc_upsert if identical
- SPEC-5 (#1806): sidecar must emit events to SC5_EVENTS with stage=run-status-comment
  - Fix: source event-bus in rsc_main, export ZBUILD_CURRENT_STAGE=run-status-comment

### core/event-bus/event-bus.sh (lines 130-275)
- eb_emit_event: loop at line 148-156 calls jq once per arg: `echo "$payload" | jq --arg k --arg v '. + {($k): $v}'`
- Timestamp check at line 160: `if [[ "$ZBUILD_PLATFORM" == "macos" ]]` — BUG: should check OSTYPE
- _eb_sql_escape at line 291-293: uses printf | sed — can replace with bash expansion

### scripts/lib/run-status-comment.sh
- rsc_flush (line 231): renders, calls rsc_upsert unconditionally — no body comparison
- rsc_tail_loop (line 255): after rsc_flush (line 290), sets dirty=0 but does NOT re-read size
- rsc_main (line 325): does not source event-bus, does not set ZBUILD_CURRENT_STAGE
- emit_event is a stub in helpers.sh; sidecar currently has no way to emit events

### tests/e2e/fork-budget-test.sh
- FORK_BUDGET already set to 4500 at line 65 (test-author already set this)
- ADR-065 amendment note already in comments

## Conclusions:
1. event-bus.sh needs: _eb_host_is_mac helper + use OSTYPE; payload accumulation with single jq call; bash ${} for _eb_sql_escape
2. run-status-comment.sh needs: re-read last_size after rsc_flush; cmp -s body comparison in rsc_flush; source event-bus + set ZBUILD_CURRENT_STAGE in rsc_main
3. ADR-065 needs ## Enforced by section; remove from baseline

## What's next:
- Read ADR-065-process-budget.md and config/adr-enforcement-baseline.txt
- Implement all fixes
