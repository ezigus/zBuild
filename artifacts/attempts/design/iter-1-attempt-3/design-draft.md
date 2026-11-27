# Design: Concurrent-claim race detection (issue #2534)

## Decision

GitHub's label API has no check-and-set: two runs can both read "no claim" and both add
`zbuild:claimed`, each getting a success reply. After adding the label (gh backend only),
the coordinator posts a concurrent claim note — `"concurrent claim by \`<holder>\`"` —
then re-reads the GitHub issue itself (its labels or state), then reads back all trusted
concurrent claim notes. The note is the synchronous holder record (RQTIE-3 path 1). The
run whose note is first by GitHub's `created_at` (then `id` on a tie) is the winner; it
returns `{"acquired": true}`. Every other run marks its note "not started — concurrent
claim: `<winner>` was first" and returns
`{"acquired": false, "holder": "<winner>", "race_lost": true}`. The engine receives
`race_lost: true` and refuses immediately, skipping the stale-takeover path that would
otherwise trigger for any cross-machine refusal. ADR-005 gains §5 to document all of this.

Why the stale-takeover path cannot set `_ZBUILD_CLAIM_ACQUIRED` for a race-lost response:
in `zbuild_claim_acquire`, the new `race_lost: true` branch (DSRACE-5) returns 1 before
the code reaches `_zbuild_claim_takeover`, so the takeover's `_ZBUILD_CLAIM_ACQUIRED="$issue"`
assignment is never reached. DSRACE-4 is [code] because that guarantee requires DSRACE-5 to
be in place; without it, the existing takeover path can and does set `_ZBUILD_CLAIM_ACQUIRED`.

Reviewed alternatives: GitHub's `labeled` events are not usable as the tie-break — GitHub
does not create a second `labeled` event when the label is already there, so the events
give no information about concurrent adders. The local-fs test backend is unaffected; its
`flock`-serialised add already returns rc 2 for a duplicate add.

Outside assumptions:
- `rsc_gh` and `jq` are available in the coordinator (already used throughout `plugin.sh`)
- GitHub's comment `created_at` and `id` are ordered and stable (standard API guarantee)
- The concurrent claim note format (`"concurrent claim by \`"`) is distinct from takeover
  notes (`"took over a stale claim from \`"`) — no interference
- GitHub's REST API for issue comments does not guarantee instantaneous cross-connection
  visibility: a comment posted by one client may not be seen by another client's read
  within a sub-second propagation window. This creates a narrow residual race: if two
  competing runs each complete their note-post and read-back before the other run's note
  has propagated, both see only their own note and both return `{"acquired": true}`. Closing
  this window requires a sleep-based wait, which the determinism rules prohibit in tests
  and would slow every claim in production. The residual probability is accepted: GitHub's
  internal replication latency for comment visibility is in practice well under a second,
  the race requires both runs to complete their entire note-post-and-read cycle inside that
  window, and occurrences are extremely rare. This assumption is noted in ADR-005 §5.

```steps
- 1 Add `_ccgl_self_holder_v`, `_ccgl_race_note_post_v`, `_ccgl_race_note_delete`, `_ccgl_race_note_update`, `_ccgl_race_note_first_v` to plugin.sh; extend `claim_coordinator_claim` to: post the concurrent claim note, re-read the GitHub issue, then read back concurrent claim notes, returning `race_lost: true` for the loser (gh backend only) | areas: plugins/claim-coordinator/github-labels/plugin.sh | serves: DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-7
- 2 In `zbuild_claim_acquire`, detect `race_lost: true` in the refused reply and refuse immediately (skip stale-takeover, print concurrent-winner message) | areas: core/claim/claim.sh | serves: DSRACE-4, DSRACE-5
- 3 Amend ADR-005: add §5 (concurrent claim detection: arbitration note, first-by-created_at-then-id wins, loser updates note to not-started, `race_lost` skip); extend `Enforced by` | areas: docs/adr/ADR-005-claim-coordinator.md | serves: DSRACE-6
```

```acceptance
DSRACE-1[code]: After successfully adding the zbuild:claimed label (gh backend), the claim posts a concurrent claim note with the run's holder, then reads back all trusted concurrent claim notes to detect concurrent claimants covers: RQTIE-1, RQTIE-3
  Given: the zbuild:claimed label was just successfully added via the gh backend
  When: the claim posts a "concurrent claim by `<holder>`" note and reads back all trusted concurrent claim notes since the note's own created_at minus the detection window
  Then: the note is posted synchronously before the read-back
  And: all concurrent claim notes from the current label epoch are returned

DSRACE-2[code]: Only the run whose concurrent claim note is first (by created_at, then id) returns {"acquired": true}; all others return {"acquired": false} covers: RQTIE-2, RQTIE-1
  Given: two or more concurrent claim notes exist for the same issue within the detection window
  When: each run compares the notes and identifies the first
  Then: the run whose note has the earliest created_at returns {"acquired": true}
  And: all other runs return {"acquired": false, "holder": "<winner_holder>", "race_lost": true}

DSRACE-3[code]: The losing run updates its concurrent claim note body to "not started" covers: RQCMT-1
  Given: the run's concurrent claim note is not the first by created_at (or id)
  When: the run determines it has lost the race
  Then: the run PATCHes its note body to "not started — concurrent claim: `<winner>` was first"

DSRACE-4[code]: When zbuild_claim_acquire receives {"acquired": false, "race_lost": true} from the coordinator, _ZBUILD_CLAIM_ACQUIRED is not set and zbuild_claim_release does not remove the zbuild:claimed label covers: RQLBL-1
  Given: claim_coordinator_claim returns {"acquired": false, "race_lost": true}
  When: zbuild_claim_acquire processes the response
  Then: _ZBUILD_CLAIM_ACQUIRED is not set
  And: zbuild_claim_release does not remove the zbuild:claimed label

DSRACE-5[code]: A coordinator response with race_lost: true causes zbuild_claim_acquire to refuse immediately without entering the stale-takeover path, printing a message that names the concurrent winner covers: RQTIE-1
  Given: claim_coordinator_claim returns {"acquired": false, "holder": "<winner>", "race_lost": true}
  When: zbuild_claim_acquire processes the response
  Then: the stale-takeover hook is not called
  And: stderr names the concurrent winner as the first claimant

DSRACE-6[doc]: ADR-005 §5 tells a reader: after adding the label (gh backend), a note is posted as the holder record, the first note by created_at then id wins, the loser marks its note "not started", and race_lost: true in the refused response skips the stale-takeover path covers: RQADR-1

DSRACE-7[code]: After posting the concurrent claim note (the synchronous holder record, gh backend), the claim reads back the GitHub issue's current state before proceeding with arbitration covers: RQREB-1
  Given: the zbuild:claimed label was added and the concurrent claim note was posted synchronously
  When: the claim reads the GitHub issue's current labels or state
  Then: fresh issue data is obtained from GitHub after the synchronous holder record was written

WIRING: core/claim/claim.sh
```
