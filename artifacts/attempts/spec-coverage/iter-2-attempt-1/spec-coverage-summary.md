## spec-coverage — uncovered

- The design's acceptance block commits only to SPEC-1 through SPEC-5; SPEC-6 and SPEC-7 are omitted from both the acceptance block and the TESTFILES mapping, so the implementation has no verifiable commitment for them.

- NOT COVERED: SPEC-6 — at max_iterations with the last iteration unfinished the cycle must emit cycle.timeout_exhausted with reason=design_timeout_exhausted and term_rc=8 (not rc=0 complete)
- NOT COVERED: the design prose alludes to "the existing exhaustion path" but the acceptance block carries no SPEC-6 entry and no test-file binding for tests/integration/cycle-member-unfinished-no-convergence-test.sh on this case
- NOT COVERED: SPEC-7 — ADR-063 must be updated to status Accepted and contain no prescriptive use of `exhausted` or `escalate`
- NOT COVERED: the design prose describes the ADR amendment and tests/unit/adr-063-vocabulary-test.sh appears in the scope list, but SPEC-7 is absent from the acceptance block and the file is not listed under TESTFILES, leaving the requirement unverifiable by the acceptance mechanism
