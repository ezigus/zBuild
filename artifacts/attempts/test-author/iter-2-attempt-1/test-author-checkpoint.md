## Checkpoint — issue #2032 test author — Iteration 2 COMPLETE

### All SPECs written (9 total)

1. **tests/integration/cycle-member-unfinished-no-convergence-test.sh** — FIXED in iter 2
   - SPEC-1 [#2032/SPEC-1]: design=dnf/pass + gate=pass → suppression on iter 1, converges iter 2.
   - SPEC-2 [#2032/SPEC-2]: all members complete → converges iter 1, no suppression event. Guard.
   - SPEC-6 [#2032/SPEC-6]: all iters design=dnf + gate=pass, max_iter=3 → rc=8 + design_timeout_exhausted.
   - **FIXED**: `set -e` mid-file removed. `_run()` now uses `RUN_RC=0; ... || RUN_RC=$?` pattern.
   - lint-test-errexit: clean confirmed.

2. **tests/unit/adr-063-vocabulary-test.sh** — IMPROVED in iter 2
   - SPEC-7 [#2032/SPEC-7]: Status=Accepted, no `disposition: exhausted`, no `exhausted → escalate`.
     **ADDED**: §3 header check for 'exhausted' (catches prose forms like "signalled as `exhausted`").
   - SPEC-8 [#2032/SPEC-8]: no "One helper renders the budget block".
     **ADDED**: §1-scoped check (awk extracts §1 body, checks pattern there specifically).
     **ADDED**: ≥2 distinct helper names check (each stage has its own).
   - SPEC-9 [#2032/SPEC-9]: #2187 amendment back-pointer present.

3. **tests/unit/spec-coverage-test.sh** — AMENDED (iter 1)
   - Added #2032/SPEC-3: route_to_model rc=124 → disposition=timed_out.

4. **tests/unit/spec-correspondence-test.sh** — AMENDED (iter 1)
   - Added #2032/SPEC-4: route_to_model rc=1 → disposition=unavailable.

5. **tests/unit/review-report-v2-contract-test.sh** — AMENDED in iter 2
   - [SPEC-5] (foreign tag from #1843): disposition=unavailable (was complete). Kept tag.
   - **ADDED**: [#2032/SPEC-5] tagged assertion for acceptance-gate. Same disposition=unavailable check.
   - WIRING note not needed (implementation file acceptance-gate check is separate).

### All files pass shellcheck with no warnings.
### lint-test-errexit: clean.
### No SIGPIPE antipatterns.
