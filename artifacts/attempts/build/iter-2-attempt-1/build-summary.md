## build — pass

- changed no file

- over 1 pass(es), 1 iteration(s)
- answered: IAFND-1: not mine — test-author must add `[DSRACE-1]`-tagged assertion to `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`: the negctl check requires a test line tagged `[DSRACE-1]` asserting that the concurrent claim note is posted before reading back notes (gh backend). The code does this; the test file has no such tag.
- answered: IAFND-2: not mine — test-author must add `[DSRACE-7]`-tagged assertion to `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`: the negctl check requires a test line tagged `[DSRACE-7]` asserting that `_ccgl_read_labels` is called after the synchronous note post. The code does this; no test file carries that tag.
- answered: IAFND-3: not mine — test-author must add `[DSRACE-2]`-tagged assertion to `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`: the negctl check requires a test line tagged `[DSRACE-2]` asserting that the first note by `created_at` wins and the loser returns `race_lost: true`. The code does this; no test file carries that tag.
- answered: IAFND-4: not mine — test-author must add `[DSRACE-3]`-tagged assertion to `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`: the negctl check requires a test line tagged `[DSRACE-3]` asserting that the loser PATCHes its note to "not started — concurrent claim: `<winner>` was first". The code does this; no test file carries that tag.
- answered: IAFND-5: not mine — test-author must add `[DSRACE-4]`-tagged assertion to `tests/unit/claim-acquire-release-test.sh`: the negctl check requires a test line tagged `[DSRACE-4]` asserting that `_ZBUILD_CLAIM_ACQUIRED` is not set when `race_lost: true` is received. The code does this; no test file carries that tag.
- answered: IAFND-6: not mine — test-author must add `[DSRACE-1]` and `[DSRACE-7]`-tagged assertions to `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`: the negctl check requires those tags to assert the synchronous ordering (note posted before re-read). The code does this; no test file carries those tags.
- step 1: done — plugins/claim-coordinator/github-labels/plugin.sh | if ! rsc_gh "$sd" "$out" api --repo "$slug" "repos/${slug}/issues/${issue}/comments" \
- step 2: done — core/claim/claim.sh | if [[ "$reply" =~ \"race_lost\"[[:space:]]*:[[:space:]]*true ]]; then
- step 3: done — docs/adr/ADR-005-claim-coordinator.md | ### §5 — Concurrent claim detection (amended 2026-11-27, #2534)
