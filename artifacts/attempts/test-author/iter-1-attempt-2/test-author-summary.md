## test-author — unusable

- changed 1 test file(s); 2 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-7
- tests/unit/claim-acquire-release-test.sh — DSRACE-4, DSRACE-5
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: RLCORRECTNESS-2: done — Replaced all four `| /usr/bin/head -1 | cut -d: -f1` pipelines in `claim-coordinator-unit-test.sh` with safe bash-variable extraction: `_all_post="$(grep -n ... || true)"` followed by `${_all_post%$'\n'*}; ${_post_line%%:*}`. grep writes its full output to a captured variable; no head in any pipeline; no SIGPIPE possible.
- answered: RLSCOPE-1: done — Same change as RLCORRECTNESS-2 above; all four `| head` occurrences in the DSRACE-1 and DSRACE-7 sections are now gone.
- answered: RLSRE-4: done — Same change as RLCORRECTNESS-2 above.
- answered: RLTESTS-1: done — Added an epoch-boundary test section (tagged `[DSRACE-1]`) in `claim-coordinator-unit-test.sh`. The fixture has: stale note at `2026-01-01T00:00:00Z` (T-60s, outside the 20s window) and this run's note at `2026-01-01T00:01:00Z` (at T). Two assertions: (1) GET_NOTES was called — fails on base code which never calls GET_NOTES; (2) `acquired: true` — fails on new code with a broken filter (since=0 would include the stale note, which wins by id/time, making this run a loser), passes when the filter correctly excludes it.
- answered: RLSECURITY-1: not mine — the code must change: `plugins/claim-coordinator/github-labels/plugin.sh`: when `_ccgl_race_note_post_v` returns rc 2 (note was POSTed but no numeric id was returned), `note_id` remains empty; `_ccgl_race_note_update` returns early because `[[ "$id" =~ ^[0-9]+$ ]]` fails, leaving DSRACE-3 unmet. The code must implement an alternative PATCH path (e.g. search for the note by body/created_at to recover the id) or the design must explicitly accept this gap. A test that asserts DSRACE-3 holds for rc-2 would fail on the current new code — i.e., it cannot be a test that "passes once the code is written" unless the code also changes.
