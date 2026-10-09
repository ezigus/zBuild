# Plan Checkpoint — Issue #1806

## Files read
- intake.md: full goal text (malformed ts, self-trigger loop, per-emit forks)
- scope-manifest.md: allows ./  (full repo)
- core/event-bus/event-bus.sh: 316 lines; the payload loop (line 155) runs jq per key=val pair; 
  timestamp (lines 160-164) reads ZBUILD_PLATFORM; _eb_sql_escape (line 292) forks sed per field
- scripts/lib/run-status-comment.sh: 372 lines; rsc_tail_loop (line 255) detects size changes;
  rsc_flush (line 231) calls rsc_outbound_body then rsc_upsert; no unchanged-body guard;
  dirty=0 set after flush but last_size not updated → redaction.applied triggers next loop
- scripts/lib/run-status-render.sh: 471 lines; rsc_outbound_body (line 402) calls
  apply_scope_redaction without setting ZBUILD_CURRENT_STAGE → redaction.applied has no stage
- core/pipeline/strategies/common.sh: _strategy_make_work_unit at line 154 bakes
  `export ZBUILD_PLATFORM='${platform}'` into every work unit → overwrites host platform
- docs/adr/ADR-065-process-budget.md: §1=fork count is tested contract, §2=only ratchets down,
  §4=one pass not one per key, §5=event bus per-event processes named for removal (this issue)
  No "Enforced by" section yet (needs adding per CLAUDE.md lint rule)
- tests/e2e/fork-budget-test.sh: FORK_BUDGET=5480; runs parity fixture under xtrace

## Key conclusions

### Problem 1: per-emit forks in eb_emit_event
- Loop at line 155: `payload="$(echo "$payload" | jq ...)"` = 1 jq per key/val pair
- `date` called once per event (lines 160-164) for timestamp
- These combine with envelope `jq -cn` at line 206
- Fix: single `jq -cn --args "${kv_pairs[@]}"` using `$ARGS.positional` to build payload+envelope

### Problem 2: malformed timestamps from map units
- Line 160: `if [[ "$ZBUILD_PLATFORM" == "macos" ]]` - wrong variable
- Map work units export `ZBUILD_PLATFORM='${platform}'` (the TARGET platform, not the HOST)
- Fix: detect host via `$OSTYPE` at source time into `_EB_HOST_IS_MACOS`; don't use ZBUILD_PLATFORM

### Problem 3: _eb_sql_escape forks sed per field
- Line 291-292: `printf '%s' "$1" | sed "s/'/''/g"` = 1 sed per escaped field
- Fix: `local s="$1" q="'"; printf '%s' "${s//$q/$q$q}"` (no fork)

### Problem 4: rsc_tail_loop self-trigger
- rsc_flush writes redaction.applied to events.jsonl (via apply_scope_redaction → emit_event)
- After flush: dirty=0 but last_size is pre-flush size
- Next poll: new size > last_size → dirty=1 → another flush → infinite loop
- Fix: after rsc_flush, re-read current file size and update last_size

### Problem 5: rsc_upsert patches even when body unchanged
- rsc_flush calls rsc_upsert on every dirty interval without comparing body
- Fix: save last-posted body; use `cmp -s` before calling rsc_upsert

### Problem 6: stage attribution for redaction.applied
- rsc_outbound_body calls apply_scope_redaction without ZBUILD_CURRENT_STAGE
- Fix: set ZBUILD_CURRENT_STAGE="run-status-comment" around the apply_scope_redaction call

## What's still unresolved
- ADR-065 doesn't have an Enforced by section. CLAUDE.md says this fails lint unless in baseline.
  Need to either add it or verify it's in adr-enforcement-baseline.txt. Will note in plan.
- Per-emit fork count reduction not yet measured — plan must note that FORK_BUDGET needs
  updating after measure (but can't measure without running the fixture).
- Whether the test for timestamp (SPEC for "no %3N literal") needs a BSD date mock to work on Linux.

## Additional findings
- ADR-065 is in config/adr-enforcement-baseline.txt (line 62) → exempt from Enforced by lint currently
- loop test already has SPEC-1 through SPEC-5 (new SPECs will be -6 and -7)
- rsc_flush already has a prev-body path, need to add cmp -s guard
- ZBUILD_CURRENT_STAGE attribution: set in rsc_main/rsc_tail_loop (comment.sh), not render.sh
- ADR-065 baseline removal belongs with the fork budget ratchet step

## Final plan if stopped now
step-1: tests/unit/event-bus-timestamp-test.sh (red test: malformed ts from ZBUILD_PLATFORM=linux)
step-2: tests/unit/run-status-comment-loop-test.sh (red tests: self-trigger + unchanged-body)  
step-3: core/event-bus/event-bus.sh (single jq payload, _eb_sql_escape bash builtin)
step-4: core/event-bus/event-bus.sh (OSTYPE-based host detection, not ZBUILD_PLATFORM)
step-5: scripts/lib/run-status-comment.sh (re-read last_size after flush + stage attribution)
step-6: scripts/lib/run-status-comment.sh + run-status-render.sh (cmp -s unchanged-body check)
step-7: tests/e2e/fork-budget-test.sh + docs/adr/ADR-065-process-budget.md + config/adr-enforcement-baseline.txt
