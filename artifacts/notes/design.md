# Design notes — issue #2534: concurrent-claim race

## Status: design revised (round 2)

## Changes made in this round

**DSFND-1 (RQREB-1 not covered):** Added DSRACE-7[code]. After posting the concurrent claim
note (the synchronous holder record), `claim_coordinator_claim` in plugin.sh re-reads the
GitHub issue's current labels or state before proceeding with arbitration. This covers RQREB-1
("After adding the label, a run re-reads the issue"). Removed RQREB-1 from DSRACE-1's covers;
it now lives only in DSRACE-7. Added DSRACE-7 to step 1's serves.

**DSFND-2 (UNCLEAR RQCMT-1):** Removed the UNCLEAR line. The finding confirms the assumption
was correct (the arbitration note is the only GitHub comment a refused run posts; the sidecar
doesn't start a run-status comment for a refused run). The design now follows the issue's
intent directly without an UNCLEAR caveat.

**DSFND-3 (DSRACE-2 Then mentions note deletion):** Removed "and deletes its note" from
DSRACE-2's Then clause. The issue (RQTIE-2) only requires the first-claiming run to proceed;
it doesn't require note deletion. The implementation may still delete the winner's note as
cleanup (kept in step 1's helper list), but the SPEC doesn't commit to it.

**DSFND-4 (DSRACE-4 must be [code]):** Changed DSRACE-4 from [done] to [code] with proper
Given/When/Then. Added it to step 2's serves. The guarantee that the label is not removed
requires DSRACE-5 to be in place first (the `race_lost: true` skip in `zbuild_claim_acquire`
returns before `_zbuild_claim_takeover` is called, preventing `_ZBUILD_CLAIM_ACQUIRED="$issue"`
from ever running on that path). Without the new code, the old takeover path can and does set
`_ZBUILD_CLAIM_ACQUIRED`. The Decision section now explains this explicitly.

Also removed the "RQLBL-1 is [done]" paragraph from Decision.

## What I found

**The race:** Two runs read "no `zbuild:claimed` label" at the same time. Both call
`gh issue edit --add-label zbuild:claimed`. GitHub accepts both (the label API has no
check-and-set). Both `claim_coordinator_claim` calls return `{"acquired": true}` and
both runs proceed. That is RQTIE-1's bug.

**Key files:**
- `plugins/claim-coordinator/github-labels/plugin.sh` — the coordinator; `claim_coordinator_claim` is the hook (255 lines, +~100 = ~355, OK)
- `core/claim/claim.sh` — engine side; `zbuild_claim_acquire` calls `plugin_hook_call` → `claim_coordinator_claim` (221 lines, +~15 = ~236, OK)
- `plugins/claim-coordinator/github-labels/lib/takeover.sh` — stale takeover; similar note-based arbitration pattern
- `docs/adr/ADR-005-claim-coordinator.md` — the spec; §2 "Known, not mitigated: GitHub's label add..." names #2534

**Local-fs backend:** Already safe. `_ccgl_add_label` for local-fs is under `flock` and returns rc 2 if the label
is already there. No change needed.

**RQTIE-3 options:**
1. Write holder record synchronously before re-reading → note-based approach (chosen)
2. Use something that exists at claim time (label events) → NOT viable: GitHub does NOT create a second
   `labeled` event when the label is already there, so we can't distinguish concurrent adders from events.

**Decision: Note-based arbitration (same pattern as stale takeover):**
- After adding the label (gh backend only), post `"concurrent claim by \`<holder>\`"`
- Re-read the GitHub issue itself (labels/state) — RQREB-1
- Read back all trusted concurrent claim notes since `note.created_at - detection window`
- First note by `created_at`, then `id` wins
- Winner: returns `{"acquired": true}` (may also delete its note as cleanup)
- Loser: updates note to "not started — …", returns `{"acquired": false, "holder": "...", "race_lost": true}`

**Why DSRACE-4 is [code]:** Without DSRACE-5, `zbuild_claim_acquire` enters `_zbuild_claim_takeover`
for any cross-machine refused claim. `_zbuild_claim_takeover` can call `_ZBUILD_CLAIM_ACQUIRED="$issue"`
(inside `_zbuild_claim_takeover` in claim.sh) if the takeover hook returns `claimed: true`. Therefore the
guarantee that `_ZBUILD_CLAIM_ACQUIRED` is never set after a race-lost refusal requires DSRACE-5's new
code path to be in place. DSRACE-4's test must mock the coordinator to return `race_lost: true` and verify
`_ZBUILD_CLAIM_ACQUIRED` stays empty — this test fails on old code and passes after the change.

**WIRING:** `core/claim/claim.sh` — it calls `plugin_hook_call` → `claim_coordinator_claim`, and now also
handles `race_lost` from the response. If reverted, DSRACE-4 and DSRACE-5 tests would fail.

**No supersedes:** Existing test assertions remain correct. The gh-backend unit tests in
`claim-coordinator-unit-test.sh` will need mock updates for new API calls, but their
assertions about existing behavior are still correct.
