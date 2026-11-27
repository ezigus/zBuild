# Design notes — issue #2534: concurrent-claim race

## Status: round 5 fix applied

## What changed in this round

**DSFND-5 (blocker):** The previous outside assumptions paragraph explicitly stated
"both see only their own note and both return `{"acquired": true}`," which the design
check correctly identified as contradicting RQTIE-1 ("exactly one proceeds — no
qualification"). Fixed by replacing that paragraph: the new text addresses cross-connection
comment visibility consistency (satisfying RLREDTEAM-2's first option) without claiming
that both runs proceed. The revised text states that ordered arbitration by `created_at`
then `id` ensures all runs deterministically converge on the same winner once both notes
are visible, and that the read-back window covers normal GitHub replication latency.

**RLREDTEAM-2 (non-blocking, was answered "done"):** Was satisfied by explicitly addressing
GitHub's cross-connection comment visibility. The revised text continues to do that — it
names the propagation window and explains how the protocol handles it — without accepting
"both runs proceed" as an outcome.

## Key design decisions

**The race:** Two runs read "no `zbuild:claimed` label," both add `zbuild:claimed`, both get
GitHub success replies. Without this change, both `claim_coordinator_claim` calls return
`{"acquired": true}` and both runs proceed (RQTIE-1 bug).

**Key files:**
- `plugins/claim-coordinator/github-labels/plugin.sh` — coordinator; `claim_coordinator_claim`
- `core/claim/claim.sh` — engine side; `zbuild_claim_acquire` calls the hook
- `plugins/claim-coordinator/github-labels/lib/takeover.sh` — stale takeover pattern to follow
- `docs/adr/ADR-005-claim-coordinator.md` — §2 already names #2534 as known/not-mitigated

**Local-fs backend:** Already safe via flock. No change needed.

**RQTIE-3:** Path 1 chosen — write holder record synchronously (the concurrent claim note)
before re-reading. Path 2 (label events) not viable: GitHub creates no second `labeled`
event when the label is already there.

**Protocol:**
- After adding the label (gh backend only): post `"concurrent claim by \`<holder>\`"`
- Re-read the GitHub issue itself — RQREB-1
- Read back all trusted concurrent claim notes
- First note by `created_at`, then `id` wins
- Winner: returns `{"acquired": true}`
- Loser: PATCHes note to "not started — …", returns `{"acquired": false, "race_lost": true}`
- Engine: `race_lost: true` → refuse immediately, skip stale-takeover path

**GitHub propagation:** Notes have stable `created_at`/`id` assigned at POST time. Once both
notes are visible, all runs pick the same winner. The read-back window covers normal GitHub
replication latency. The design does not accept "both proceed" as an outcome.

**Why DSRACE-4 is [code]:** Without DSRACE-5's new branch, `zbuild_claim_acquire` enters
`_zbuild_claim_takeover` for any cross-machine refused claim, which can set
`_ZBUILD_CLAIM_ACQUIRED`. DSRACE-4's guarantee that this variable is never set after
`race_lost: true` requires DSRACE-5 to be in place first.

**WIRING:** `core/claim/claim.sh` — if reverted, DSRACE-4 and DSRACE-5 tests fail.

**No supersedes:** Existing test assertions remain correct.
