## issue-acceptance — fail

- The test suite fails across 12 tests; the live dispatch-unit loop still dispatches completed stages on resume, --from-stage still re-dispatches skipped stages, the R-9 iteration-count assertion was deleted rather than fixed, and the cycle-orchestrator.sh change introduces regressions that break four unrelated cycle tests.

- 10 requirement(s) not met — each is a finding, sent to the stages that can fix it
