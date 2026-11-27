# Design: Concurrent-claim race detection (issue #2534)

## Decision

GitHub's label API has no check-and-set: two runs can both read "no claim" and both add
`zbuild:claimed`, each getting a success reply. After adding the label (gh backend only),
the coordinator posts a concurrent claim note — `"concurrent claim by \`<holder>\`"` — then
reads back all trusted such notes. The note is the synchronous holder record (RQTIE-3 path
1). The run whose note is first by GitHub's `created_at` (then `id` on a tie) is the winner;
it deletes its note and returns `{"acquired": true}`. Every other run marks its note "not
started — concurrent claim: `<winner>` was first" and returns
`{"acquired": false, "holder": "<winner>", "race_lost": true}`. The engine receives
`race_lost: true` and refuses immediately, skipping the stale-takeover path that would
otherwise trigger for any cross-machine refusal. ADR-005 gains §5 to document all of this.

Reviewed alternatives: GitHub's `labeled` events are not usable as the tie-break — GitHub
does not create a second `labeled` event when the label is already there, so the events
give no information about concurrent adders. The local-fs test backend is unaffected; its
`flock`-serialised add already returns rc 2 for a duplicate add.

RQLBL-1 is [done]: `zbuild_claim_release` is a no-op when `_ZBUILD_CLAIM_ACQUIRED` is
unset, and a refused claim never sets it.

Outside assumptions:
- `rsc_gh` and `jq` are available in the coordinator (already used throughout `plugin.sh`)
- GitHub's comment `created_at` and `id` are ordered and stable (standard API guarantee)
- The concurrent claim note format (`"concurrent claim by \`"`) is distinct from takeover
  notes (`"took over a stale claim from \`"`) — no interference

UNCLEAR RQCMT-1 | "marks its progress comment as not started" | (1) the run-status comment (ADR-064) is marked "not started"; (2) the concurrent claim note posted for arbitration is marked "not started" | ASSUMED: (2) the concurrent claim note is the run's progress comment for this claim attempt — the sidecar never creates a run-status comment for a refused run (it waits for `pipeline.start`, which never comes), so the arbitration note is the only GitHub comment the loser posts.

```steps
- 1 Add `_ccgl_self_holder_v`, `_ccgl_race_note_post_v`, `_ccgl_race_note_delete`, `_ccgl_race_note_update`, `_ccgl_race_note_first_v` to plugin.sh; extend `claim_coordinator_claim` to invoke them after a successful label add (gh backend only), returning `race_lost: true` for the loser | areas: plugins/claim-coordinator/github-labels/plugin.sh | serves: DSRACE-1, DSRACE-2, DSRACE-3
- 2 In `zbuild_claim_acquire`, detect `race_lost: true` in the refused reply and refuse immediately (skip stale-takeover, print concurrent-winner message) | areas: core/claim/claim.sh | serves: DSRACE-5
- 3 Amend ADR-005: add §5 (concurrent claim detection: arbitration note, first-by-created_at-then-id wins, loser updates note to not-started, `race_lost` skip); extend `Enforced by` | areas: docs/adr/ADR-005-claim-coordinator.md | serves: DSRACE-6
```

```acceptance
DSRACE-1[code]: After successfully adding the zbuild:claimed label (gh backend), the claim posts a concurrent claim note with the run's holder, then reads back all trusted concurrent claim notes to detect concurrent claimants covers: RQTIE-1, RQREB-1, RQTIE-3
  Given: the zbuild:claimed label was just successfully added via the gh backend
  When: the claim posts a "concurrent claim by `<holder>`" note and reads back all trusted notes since the note's own created_at minus the detection window
  Then: the note is posted synchronously before the read-back
  And: all concurrent claim notes from the current label epoch are returned

DSRACE-2[code]: Only the run whose concurrent claim note is first (by created_at, then id) returns {"acquired": true}; all others return {"acquired": false} covers: RQTIE-2, RQTIE-1
  Given: two or more concurrent claim notes exist for the same issue within the detection window
  When: each run compares the notes and identifies the first
  Then: the run whose note has the earliest created_at returns {"acquired": true} and deletes its note
  And: all other runs return {"acquired": false, "holder": "<winner_holder>", "race_lost": true}

DSRACE-3[code]: The losing run updates its concurrent claim note body to "not started" covers: RQCMT-1
  Given: the run's concurrent claim note is not the first by created_at (or id)
  When: the run determines it has lost the race
  Then: the run PATCHes its note body to "not started — concurrent claim: `<winner>` was first"

DSRACE-4[done]: A run whose claim_coordinator_claim returns {"acquired": false} never removes the zbuild:claimed label covers: RQLBL-1
  evidence: core/claim/claim.sh | [[ -n "$issue" ]] || return 0
  When: claim_coordinator_claim returns {"acquired": false, ...}
  Then: _ZBUILD_CLAIM_ACQUIRED is never set, zbuild_claim_release is a no-op, and the label is not removed

DSRACE-5[code]: A coordinator response with race_lost: true causes zbuild_claim_acquire to refuse immediately without entering the stale-takeover path, printing a message that names the concurrent winner covers: RQTIE-1
  Given: claim_coordinator_claim returns {"acquired": false, "holder": "<winner>", "race_lost": true}
  When: zbuild_claim_acquire processes the response
  Then: the stale-takeover hook is not called
  And: stderr names the concurrent winner as the first claimant

DSRACE-6[doc]: ADR-005 §5 tells a reader: after adding the label (gh backend), a note is posted as the holder record, the first note by created_at then id wins, the loser marks its note "not started", and race_lost: true in the refused response skips the stale-takeover path covers: RQADR-1

WIRING: core/claim/claim.sh
```
