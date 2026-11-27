## test-author — pass

- tests for DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-4, DSRACE-5, DSRACE-6, DSRACE-7

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-7
- tests/unit/claim-acquire-release-test.sh — DSRACE-4, DSRACE-5
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: TAFND-11: done — Reorganized DSRACE-5 section headings in `tests/unit/claim-acquire-release-test.sh`: removed `# Then: rc 1 (immediate refusal)` (kept the rc=1 assertion bare after `# When`); changed `# And: stale-takeover hook was NOT called` to `# Then: the stale-takeover hook is not called`; kept `# And: stderr names the concurrent winner as the first claimant`. This matches the SPEC's Then/And ordering as required.
- answered: TAFND-7: done — `[DSRACE-1]`-tagged assertions were added in round 2; they assert POST_NOTE was recorded (fails on base code where no POST_NOTE call is made), so a tagged `[DSRACE-1]` line now appears in the failing output on base code.
- answered: TAFND-8: done — `[DSRACE-2]`-tagged assertions were added in round 2; they assert `acquired` is false and `race_lost` is true (fails on base code which returns `acquired: true`), so tagged `[DSRACE-2]` lines now fail on base code.
- answered: TAFND-9: done — `[DSRACE-3]`-tagged assertions were added in round 2; they assert the `patched-99004` file exists (fails on base code which makes no PATCH call), so tagged `[DSRACE-3]` lines now fail on base code.
- answered: TAFND-10: done — `[DSRACE-7]`-tagged assertions were added in round 2; they assert ISSUE_VIEW appears after POST_NOTE (fails on base code which makes no POST_NOTE), so tagged `[DSRACE-7]` lines now fail on base code.
- answered: BUFND-1: done — `[DSRACE-1]`-tagged assertions in `claim-coordinator-unit-test.sh` assert POST_NOTE is recorded before GET_NOTES in the call sequence.
- answered: BUFND-2: done — `[DSRACE-7]`-tagged assertions assert ISSUE_VIEW appears after POST_NOTE and before GET_NOTES.
- answered: BUFND-3: done — `[DSRACE-2]`-tagged assertions assert the loser gets `race_lost: true` and `acquired: false`, and the sole winner gets `acquired: true`.
- answered: BUFND-4: done — `[DSRACE-3]`-tagged assertions assert the loser PATCHes its note with "not started", "concurrent claim", winner's name, and "was first".
- answered: BUFND-5: done — `[DSRACE-4]`-tagged assertions assert `_ZBUILD_CLAIM_ACQUIRED` is not set and the release hook is not called.
- answered: BUFND-6: done — `[DSRACE-1]` and `[DSRACE-7]` assertions together assert synchronous ordering: POST_NOTE before ISSUE_VIEW before GET_NOTES.
- answered: TEFND-1: done — All six SPECs (DSRACE-1 through DSRACE-5 and DSRACE-7) now have tagged assertions in the named test files; each assertion carries its `[DSRACE-X]` tag on the line.
- answered: TEFND-2: done — Tagged assertions cover the plugin (DSRACE-1,2,3,7) and core/claim/claim.sh (DSRACE-4,5); removing the race detection would leave the base-code path returning `acquired: true` and not calling PATCH/POST, causing the tagged assertions to fail.
- answered: IAFND-1: done — DSRACE-1,2,3 assertions in `claim-coordinator-unit-test.sh` cover the gh-backend concurrent-claim path; removing arbitration logic breaks those assertions.
- answered: IAFND-2: done — DSRACE-7 assertions assert ISSUE_VIEW occurs after POST_NOTE; deleting `_ccgl_read_labels` removes the ISSUE_VIEW call and those assertions fail.
- answered: IAFND-3: done — DSRACE-2 assertions cover the first-note-wins rule and the loser path with `race_lost: true`.
- answered: IAFND-4: done — DSRACE-3 assertions cover the PATCH body with the full required format "not started — concurrent claim: `<winner>` was first".
- answered: IAFND-5: done — DSRACE-4 assertions cover `_ZBUILD_CLAIM_ACQUIRED` not set and release hook not called.
- answered: IAFND-6: done — DSRACE-1 and DSRACE-7 ordering assertions cover the synchronous write-before-reread contract.
