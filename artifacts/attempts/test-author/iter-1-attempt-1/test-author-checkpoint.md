## Checkpoint — issue #2032 test author — Iteration 3

### Files to write (9 SPECs across 5 files)

**Analysis complete.** This is iteration 3 (no prior files exist on disk).

### Key findings from source reading

1. **router_reason_disposition** (scripts/lib/router-rc-classify.sh:259–270):
   - rc=124 → router_timeout → `timed_out`
   - rc=1 (generic) → router_rc_nonzero → `unavailable`
   - rc=0 → no failure

2. **disposition_unfinished** (core/pipeline/disposition.sh:147–151):
   - Returns 0 for `timed_out`, `out_of_turns`, `interrupted` only

3. **cycle-orchestrator.sh convergence path** (lines 2541–2805):
   - `_iter_did_not_finish` computed at 2541–2548 over ALL member dispositions
   - Build-specific suppression at 2575–2580 (existing)
   - No-committed-changes suppression at 2613–2621 (existing)
   - `converged=0` path (actual convergence) at 2695
   - `_cycle_check_max_iterations` path at 2714: if `_iter_did_not_finish==1 && _exh_tests_reported==0` → term_rc=8, design_timeout_exhausted
   - **NEW SPEC-1 suppression block** does not exist yet — that's what we're testing

4. **spec-coverage plugin** (plugins/agent/spec-coverage/plugin.sh):
   - line 187: `_raw="$(route_to_model ... || true)"` — rc DISCARDED
   - line 200–204: empty _v → writes "unreadable" verdict with hardcoded `disposition:"complete"`
   - SPEC-3: after fix, rc captured and classified; `timed_out` when rc=124

5. **spec-correspondence plugin**: similar rc-discard pattern; SPEC-4 tests rc=1 → `unavailable`

6. **review-report plugin**: `_RR_FAIL_LENS=performance` triggers rc=1 in subshell;
   SPEC-5 currently asserts `disposition=complete`; after fix must be `unavailable`

7. **ADR-063 current content**:
   - Status: "Proposed"
   - §3 header: "Partial is signalled as `disposition: exhausted`"
   - §4 bullet: "`exhausted → escalate` already routes..."
   - §1: "One helper renders the budget block"
   - No #2187 back-pointer

### Files written this iteration

1. tests/integration/cycle-member-unfinished-no-convergence-test.sh — IN PROGRESS
2. tests/unit/adr-063-vocabulary-test.sh — TODO
3. tests/unit/spec-coverage-test.sh (amend SPEC-3) — TODO
4. tests/unit/spec-correspondence-test.sh (amend SPEC-4) — TODO
5. tests/unit/review-report-v2-contract-test.sh (update SPEC-5, add #2032/SPEC-5) — TODO

### Next: write integration test first
