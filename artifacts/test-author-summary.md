## test-author — pass

- tests for DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-4, DSRACE-5, DSRACE-6, DSRACE-7

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-7
- tests/unit/claim-acquire-release-test.sh — DSRACE-4, DSRACE-5
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: TAFND-13: done — Added `assert_contains "[DSRACE-5] stderr names the winner as the first claimant" "$(cat "$TEST_TEMP_DIR/race5.err")" "first"` to `tests/unit/claim-acquire-release-test.sh`. On base code the stale-takeover path fires (no race_lost early-return exists), nothing with "first" is printed to stderr → assertion fails. On new code the race_lost path prints a message containing "first" → passes.
- answered: TAFND-14: done — Replaced the DSRACE-7 section in `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` with a standalone section: **Given** calls `_race_gh_reset` and writes fixture files; **When** calls `claim_coordinator_claim 8007` on its own; **Then** asserts "POST_NOTE was recorded", "ISSUE_VIEW comes after POST_NOTE", and "ISSUE_VIEW comes before GET_NOTES". All three fail on base code (base code makes only ISSUE_VIEW + ADD_LABEL — no POST_NOTE, no second ISSUE_VIEW, no GET_NOTES).
- answered: RLSECURITY-1: not mine — the code must change: `plugins/claim-coordinator/github-labels/plugin.sh`: when `_ccgl_race_note_post_v` returns rc 2 (note posted but no numeric id returned), `note_id` remains empty; `_ccgl_race_note_update` returns early because `[[ "$id" =~ ^[0-9]+$ ]]` fails, so DSRACE-3's requirement is silently not met. A test asserting DSRACE-3 holds for rc-2 would fail on the current new code — it cannot "pass once the code is written" unless the code also changes.
- answered: RLCORRECTNESS-2: done — fixed in round 4; all four `| head -1` pipelines replaced with safe bash extraction.
- answered: RLSCOPE-1: done — fixed in round 4; same change as RLCORRECTNESS-2.
- answered: RLSRE-4: done — fixed in round 4; same change as RLCORRECTNESS-2.
- answered: RLTESTS-1: done — fixed in round 4; added epoch-boundary test fixture with a stale note (T-60s, outside 20s window) that is excluded by the correct since filter.
