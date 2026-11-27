## test-author — unusable

- changed 2 test file(s); 10 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-7
- tests/unit/claim-acquire-release-test.sh — DSRACE-4, DSRACE-5
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: TEFND-1: done — added assertions tagged [DSRACE-1], [DSRACE-2], [DSRACE-3], [DSRACE-4], [DSRACE-5], [DSRACE-7] to the two test files named in scope.
- answered: TEFND-2: done — the tagged assertions cover both plugin.sh (concurrent claim ordering, winner/loser, PATCH) and core/claim/claim.sh (race_lost guard, _ZBUILD_CLAIM_ACQUIRED, release skipped).
- answered: BUFND-1: done — `[DSRACE-1]`-tagged assertions added to `claim-coordinator-unit-test.sh` asserting POST_NOTE is made before GET_NOTES.
- answered: BUFND-2: done — `[DSRACE-7]`-tagged assertions added to `claim-coordinator-unit-test.sh` asserting `ISSUE_VIEW` appears after `POST_NOTE` and before `GET_NOTES`.
- answered: BUFND-3: done — `[DSRACE-2]`-tagged assertions added asserting the loser gets `race_lost: true` and winner gets `acquired: true`.
- answered: BUFND-4: done — `[DSRACE-3]`-tagged assertions added asserting the loser PATCHes its note with "not started" and the winner's name.
- answered: BUFND-5: done — `[DSRACE-4]`-tagged assertions added to `claim-acquire-release-test.sh` asserting `_ZBUILD_CLAIM_ACQUIRED` is not set and release hook is not called.
- answered: BUFND-6: done — both `[DSRACE-1]` and `[DSRACE-7]` assertions are present, confirming synchronous ordering (POST_NOTE before ISSUE_VIEW before GET_NOTES).
- answered: IAFND-1: done — `claim-coordinator-unit-test.sh` now has a test where two concurrent notes exist; removing the arbitration logic would leave `acquired: true` where the test expects `acquired: false` → test fails on old code.
- answered: IAFND-2: done — `[DSRACE-7]` assertions assert that an ISSUE_VIEW occurs after the note post; deleting `_ccgl_read_labels` removes the ISSUE_VIEW call and those assertions fail.
- answered: IAFND-3: done — `[DSRACE-2]` assertions cover first-note-wins and loser path with `race_lost: true`.
- answered: IAFND-4: done — `[DSRACE-3]` assertions cover the PATCH to "not started" with winner's name.
- answered: IAFND-5: done — `[DSRACE-4]` assertions cover `_ZBUILD_CLAIM_ACQUIRED` not set and release hook not called.
- answered: IAFND-6: done — `[DSRACE-1]` and `[DSRACE-7]` ordering assertions cover the synchronous write-before-reread contract.
