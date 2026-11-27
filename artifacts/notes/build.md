# Build notes — issue #2534 (concurrent-claim race detection)

## Status: COMPLETE (code done; tests need test-author)

## What was done

All three files were modified across earlier passes:

### plugins/claim-coordinator/github-labels/plugin.sh
- Added `_CCGL_TRUSTED`, `_CCGL_RACE_NOTE_PREFIX`, `_CCGL_RACE_NOTE_AT` constants
- Added `_ccgl_self_holder_v`: computes this run's holder string
- Added `_ccgl_race_note_post_v`: posts concurrent claim note, captures id and created_at
- Added `_ccgl_race_note_delete`: best-effort DELETE of race note by id
- Added `_ccgl_race_note_update`: PATCHes race note to "not started" message
- Added `_ccgl_race_note_first_v`: reads back all trusted concurrent claim notes, returns holder of the first
- Extended `claim_coordinator_claim`: after successful label add on gh backend, posts note, re-reads issue, reads back notes, returns `race_lost: true` for losers

### core/claim/claim.sh
- Added `race_lost: true` check in `zbuild_claim_acquire`: refuses immediately without entering stale-takeover path, prints message naming the concurrent winner (DSRACE-4, DSRACE-5)

### docs/adr/ADR-005-claim-coordinator.md
- Added §5 (concurrent claim detection): note posted as holder record, re-read issue, first by created_at then id wins, loser updates note, race_lost: true skips stale-takeover (DSRACE-6)
- Updated header amendment line, Implementation Notes table, Enforced by section

## Test results
- Full suite: 986/986 PASS
- `shellcheck plugins/claim-coordinator/github-labels/plugin.sh`: CLEAN

## Open issue: missing DSRACE-tagged test assertions
The issue-acceptance negctl check requires [DSRACE-N]-tagged assertions in test files:
- DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-7 → `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
- DSRACE-4, DSRACE-5 → `tests/unit/claim-acquire-release-test.sh`

The test-author stage timed out and never wrote those tagged assertions. I cannot change test files. Test-author must add them.

The ADR-005 Enforced by section already names the correct test file for each DSRACE tag.

## Findings disposition
- IAFND-1 through IAFND-6: not mine — test-author must add [DSRACE-N] assertions to test files
