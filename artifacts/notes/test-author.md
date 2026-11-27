# Test Author Notes — DSRACE-1 through DSRACE-7

## Status: DONE (round 3)

All 6 SPECs have tagged assertions in the two named test files. Both files pass
all tests on the working copy (new code). Round 3 fixed TAFND-11 only.

## Round 3 change

TAFND-11: reorganized DSRACE-5 section headings in `tests/unit/claim-acquire-release-test.sh`:
- Removed `# Then: rc 1 (immediate refusal)` heading; rc=1 assertion kept without a Then heading
- Changed `# And: stale-takeover hook was NOT called` → `# Then: the stale-takeover hook is not called`
- Kept `# And: stderr names the concurrent winner as the first claimant`

This matches the SPEC: Then = stale-takeover not called; And = stderr names winner.

## Test files and coverage

| File | SPECs |
|------|-------|
| `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` | DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-7 |
| `tests/unit/claim-acquire-release-test.sh` | DSRACE-4, DSRACE-5 |

## Base code vs new code differences

### plugins/claim-coordinator/github-labels/plugin.sh
New functions in working copy (not in base):
- `_ccgl_self_holder_v` — returns this run's holder string
- `_ccgl_race_note_post_v` — POSTs "concurrent claim by `<holder>`" note; sets `_CCGL_RACE_NOTE_AT`
- `_ccgl_race_note_delete` — DELETE best-effort
- `_ccgl_race_note_update` — PATCH "not started — concurrent claim: `<winner>` was first"
- `_ccgl_race_note_first_v` — reads all concurrent claim notes, returns first by created_at/id

`claim_coordinator_claim` changed (gh backend only): after label add:
1. `_ccgl_self_holder_v my_holder`
2. `_ccgl_race_note_post_v note_id` (synchronous holder record)
3. `_ccgl_read_labels "$issue"` (re-read issue state — DSRACE-7)
4. `_ccgl_race_note_first_v winner` (arbitration)
5. winner == my_holder → `{"acquired": true}`
6. winner != my_holder → PATCH + `{"acquired": false, "holder": "$winner", "race_lost": true}`

### core/claim/claim.sh
`zbuild_claim_acquire`: after `{"acquired": false}`, before stale/own check:
- If `race_lost: true` → print concurrent winner to stderr, return 1 immediately (skip takeover)

## Why base code tests fail

- DSRACE-1: No POST_NOTE in base → `_post_line` empty → assertion fails with "0" vs "1"
- DSRACE-1 epoch: base returns `acquired: true` → assertion fails with "true" vs "false"
- DSRACE-2: base returns `acquired: true` (no race detection) → assertion fails with "true" vs "false"
- DSRACE-3: base makes no PATCH → `patched-99004` absent → assertion fails with "0" vs "1"
- DSRACE-4: base takeover path sets `_ZBUILD_CLAIM_ACQUIRED` → assertion fails with non-empty vs ""
- DSRACE-5: base takeover fires → `_takeover_calls` = 1 → assertion fails with "1" vs "0"
- DSRACE-7: No POST_NOTE → no ordering → assertion fails with "0" vs "1"

## Mock strategy (claim-coordinator-unit-test.sh)

The `_race_gh_reset` mock:
- `api:--paginate` → GET_NOTES token, serves all page-*.json files
- `api:--repo` with `-f body=` → POST_NOTE token, returns post-reply.json
- `issue:view` → ISSUE_VIEW token, returns labels file
- `issue:edit:--add-label` → ADD_LABEL token
- `-X PATCH` → PATCH token, saves body to `patched-<id>`
- `-X DELETE` → DELETE token

Holder predictable: GITHUB_ACTIONS=true + GITHUB_RUN_ID=dsrace-test-run → fixed URL.

## Results (working copy)

- claim-coordinator-unit-test.sh: 53/53 tests pass
- claim-acquire-release-test.sh: 42/42 tests pass
