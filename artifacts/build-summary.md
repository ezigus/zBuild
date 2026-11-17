## build — pass

- changed config/shape-change-paths.txt (+0 / -1)

- over 1 pass(es), 1 iteration(s)
- answered: acceptance-gate finding 1: done — removed `core/claim/claim.sh` from `config/shape-change-paths.txt`; no requirement asks for that entry and I cannot add tests (test files are read-only), so the correct fix is to drop the unasked-for change that the finding says no test covers.
- answered: issue-acceptance finding 1: done — removed `core/claim/claim.sh` from `config/shape-change-paths.txt`; the entry had no requirement asking for it. All 3 acceptance test files continue to pass (27/27, 21/21, 29/29).
