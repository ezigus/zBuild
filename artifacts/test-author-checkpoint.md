## Checkpoint — issue #2032 test author — COMPLETE

### All SPECs written

1. **tests/integration/cycle-member-unfinished-no-convergence-test.sh** — NEW
   - SPEC-1 [#2032/SPEC-1]: design=dnf/pass + gate=pass → suppression on iter 1, converges iter 2. Fails on old (iter_count=1, no event).
   - SPEC-2 [#2032/SPEC-2]: all members complete → converges iter 1, no suppression event. Guard — passes before and after.
   - SPEC-6 [#2032/SPEC-6]: all iters design=dnf + gate=pass, max_iter=3 → rc=8 + design_timeout_exhausted. Fails on old (rc=0 false convergence).
   - Schema registration check for cycle.member_unfinished.suppressed_convergence.

2. **tests/unit/adr-063-vocabulary-test.sh** — NEW
   - SPEC-7 [#2032/SPEC-7]: Status=Accepted, no `disposition: exhausted`, no `exhausted → escalate`, has timed_out/out_of_turns. Fails on old (Status=Proposed).
   - SPEC-8 [#2032/SPEC-8]: no "One helper renders the budget block", has _<stage>_budget_guidance pattern. Fails on old.
   - SPEC-9 [#2032/SPEC-9]: #2187 amendment back-pointer present in amendment context. Fails on old.

3. **tests/unit/spec-coverage-test.sh** — AMENDED
   - Added #2032/SPEC-3: route_to_model rc=124 → disposition=timed_out. Fails on old (disposition=complete).

4. **tests/unit/spec-correspondence-test.sh** — AMENDED
   - Added #2032/SPEC-4: route_to_model rc=1 → disposition=unavailable. Fails on old (disposition=complete).

5. **tests/unit/review-report-v2-contract-test.sh** — AMENDED
   - Updated [SPEC-5]: changed disposition=complete assertion to disposition=unavailable. Updated section comment (removed stale "exhausted (ADR-063 §3)" reference). Header comment also updated.

### All files pass shellcheck (only SC2317 info-level warnings, consistent with existing tests).
### No SIGPIPE antipatterns (all greps are file-based or use here-strings).
