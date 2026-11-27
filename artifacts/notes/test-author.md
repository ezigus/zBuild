# Test Author Notes — DSRACE-1 through DSRACE-7

## Status: DONE (round 5)

All 6 SPECs have tagged assertions in the two named test files.
All 55 tests pass on the working copy (claim-coordinator-unit-test.sh).
All 43 tests pass on the working copy (claim-acquire-release-test.sh).
Round 5 fixed TAFND-13 and TAFND-14.

## Test files and coverage

| File | SPECs |
|------|-------|
| `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` | DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-7 |
| `tests/unit/claim-acquire-release-test.sh` | DSRACE-4, DSRACE-5 |

## Round 5 changes

### TAFND-13: added "first" assertion for DSRACE-5

The existing DSRACE-5 assertions checked for the winner's URL and "concurrent claim"
but not for language saying the winner was *first*. Added:

```bash
assert_contains "[DSRACE-5] stderr names the winner as the first claimant" \
    "$(cat "$TEST_TEMP_DIR/race5.err")" "first" # [DSRACE-5]
```

Fails on base code: the stale-takeover path fires (no race_lost early-return), no "first"
is ever printed to stderr.
Passes on new code: the race_lost early-return prints a message that includes "first".

### TAFND-14: restructured DSRACE-7 as standalone with code under Given/When/Then

The old DSRACE-7 section had no executable code under Given or When; all code was under
the Then heading, reusing the DSRACE-1 invocation's call sequence. Replaced it with a
standalone section:

- **Given**: `_race_gh_reset` + fixture files (post-reply.json, notes-pages/page-1.json)
- **When**: `claim_coordinator_claim 8007` (its own invocation)
- **Then**: three assertions about the call sequence

The three assertions (POST_NOTE recorded; ISSUE_VIEW after POST_NOTE; ISSUE_VIEW before
GET_NOTES) all fail on base code because the base code makes only ISSUE_VIEW + ADD_LABEL
(no POST_NOTE, no second ISSUE_VIEW, no GET_NOTES).

## Round 4 changes (preserved for reference)

### RLCORRECTNESS-2 / RLSCOPE-1 / RLSRE-4: fixed 4 `| head -1` SIGPIPE violations

Replaced piped `grep -n | head -1 | cut` with safe bash extraction:
```bash
_all_post="$(/usr/bin/grep -n "^POST_NOTE$" "$GHS/call-sequence" || true)"
_post_line="${_all_post%$'\n'*}"; _post_line="${_post_line%%:*}"
```

### RLTESTS-1: added epoch-boundary test fixture

Stale note at T-60s (outside 20s window) + current note at T.
Fails on base code (no GET_NOTES); fails on new code with broken since=0 filter;
passes on new code with correct since filter.

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
2. `_ccgl_race_note_post_v note_id` (synchronous holder record) → POST_NOTE in call sequence
3. `_ccgl_read_labels "$issue"` (re-read issue state) → ISSUE_VIEW in call sequence (DSRACE-7)
4. `_ccgl_race_note_first_v winner` (arbitration) → GET_NOTES in call sequence
5. winner == my_holder → `{"acquired": true}`
6. winner != my_holder → PATCH + `{"acquired": false, "holder": "$winner", "race_lost": true}`

### core/claim/claim.sh
`zbuild_claim_acquire`: after `{"acquired": false}`, before stale/own check:
- If `race_lost: true` → print concurrent winner (with "first") to stderr, return 1 immediately

## Why base code tests fail

- DSRACE-1: No POST_NOTE in base → `_post_line` empty → assertion fails
- DSRACE-1 epoch-boundary: GET_NOTES not called in base → GET_NOTES assertion fails
- DSRACE-2: base returns `acquired: true` (no race detection) → loser assertion fails
- DSRACE-3: base makes no PATCH → `patched-99004` absent → assertion fails
- DSRACE-4: base takeover path sets `_ZBUILD_CLAIM_ACQUIRED` → assertion fails
- DSRACE-5: base takeover fires → rc=0, no "first" in stderr → all three assertions fail
- DSRACE-7 (standalone): No POST_NOTE in base → `_post7` empty → all three ordering assertions fail

## Results (working copy)

- claim-coordinator-unit-test.sh: 55/55 tests pass
- claim-acquire-release-test.sh: 43/43 tests pass
