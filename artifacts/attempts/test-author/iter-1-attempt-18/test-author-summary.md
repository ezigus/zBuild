## test-author — unusable

- changed 2 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- SPECs in the contract: 12
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, DSPK-1, FRSH-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — added `# Given`, `# When`, `# Then` to RHYD-1 paths 2 and 3; each path now has its own section headings
- answered: test-author finding 2: done — changed FSTG-1 assertion from `cycle.start cycle_id=cyc` to `stage.start stage=cycled`; the SPEC requires a stage.start event for the dispatched stage
- answered: test-author finding 3: done — added `# Then` before AMDR-1 assertions
- answered: test-author finding 4: done — added `# Then` before AMDR-2 assertions
- answered: test-author finding 5: done — added `# Given`, `# When`, `# Then` to DSPK-1 assertion block
- answered: test-author finding 6: done — added `# Given`, `# When`, `# Then` to FRSH-1 section
- answered: test-author finding 7: done — DLGT-1 in hydrate-stage-test.sh already had its Given/When/Then headings from a previous round; verified they are present and correct
- answered: test-author finding 8: done — added `# Then` to CYCL-1 sections in both resume-rehydrate-test.sh and from-stage-rehydrate-test.sh
