# Design notes — #1753

## Findings

### Bug location
`core/pipeline/strategies/map.sh:157`
```bash
[[ "$outcome" == fail ]] && flagged=yes
```
Only `fail` sets `flagged=yes`. Outcomes like `timed_out`, `out_of_turns`, `broken`, `missing` go
to `unfinished[]` (for the group banner) but leave `flagged=no`, so `ZBUILD_RUN_FLAGGED=no` is
exported and delivery proceeds to merge.

### Fix
```bash
[[ "$outcome" == pass ]] || flagged=yes
```
Any outcome that is not `pass` — conclusive `fail` or any unfinished outcome — sets
`ZBUILD_RUN_FLAGGED=yes`.

### Delivery path is already correct
`plugins/agent/pr-delivery/plugin.sh:161` blocks merge under `auto_unless_flagged` when
`ZBUILD_RUN_FLAGGED=yes`. No change needed there, or in merge/runner.

### ADR-040 §2368 part 2 (line 465)
Says `ZBUILD_RUN_FLAGGED` is `yes` "when a lens found a high or critical problem the change
introduced". After fix, also `yes` when any element did not finish. Amendment needed.

### Tests
- `engine-combines-map-test.sh` M2 says "yes when an element failed, no otherwise". Need new
  assertion for timed_out → yes. Existing M2 assertions still pass (they test fail and all-pass).
- `map-members-reported-test.sh` MR4 runs with timed_out beta; doesn't check ZBUILD_RUN_FLAGGED.
  May add assertion but not strictly needed — SPEC-1 primary test is engine-combines-map-test.sh.
- `merge-policy-auto-unless-flagged-test.sh` already has SPEC-7 (ZBUILD_RUN_FLAGGED=yes → pr-open).
  No code changes needed; this covers SPEC-3 as [done] evidence.

### No supersedes
No existing assertion pins "timed_out → ZBUILD_RUN_FLAGGED=no". The bug was invisible to the
test suite. No supersedes block needed.

### WIRING
Runner.sh already calls `_strategy_run_map` from map.sh; no new wiring needed. The unit test
(`engine-combines-map-test.sh`) sources map.sh directly and calls `_strategy_run_map`. Runner.sh
is the live-path caller.

### Previous run finding — fixed
The previous design listed `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` under TESTFILES
for SPEC-2. The validator rejected it because it is not a test file. Since SPEC-2 is `[no-code]`,
no TESTFILES entry is required. The line was removed.

## Status: complete — design-draft.md written
