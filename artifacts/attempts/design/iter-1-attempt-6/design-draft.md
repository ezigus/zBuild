# Design: Concurrent-claim race detection (issue #2534)

## Decision

GitHub's label API has no check-and-set: two runs can both read "no claim", both add
`zbuild:claimed`, and both get a success reply. After adding the label (gh backend only) the
coordinator posts its holder record synchronously: a comment `concurrent claim by \`<holder>\``
(RQTIE-3, first option; GitHub `labeled` events cannot be the tie-break because a second add of an
existing label creates no event). It then reads the issue's comments **once** (RQREAD-1). That one
read is the re-read (RQREB-1); the labels are NOT re-read (RQREB-2). The first record by GitHub's
`created_at`, then `id`, wins. Other runs' records count only if their `created_at` lies inside
`[own created_at − window, ∞)`. The window is `ZBUILD_CLAIM_RACE_WINDOW_S`, default 120, read on its own
and not derived from `ZBUILD_STATUS_COMMENT_GH_TIMEOUT` (RQWIN-1, RQWIN-2).

- Winner: `{"acquired": true}`; its record stays until release.
- Loser: PATCHes its record to "not started — concurrent claim: `<winner>` was first" (a body that no
  longer starts with the record prefix, so no later run counts it), keeps the label, returns
  `{"acquired": false, "holder": "<winner>", "race_lost": true}`. The engine (`zbuild_claim_acquire`)
  sees `race_lost` and refuses at once, skipping stale takeover (so `_ZBUILD_CLAIM_ACQUIRED` is never set and
  release never removes the label).
- Reply to the POST has no `created_at`: fail closed. Delete the record, remove the label, return a
  backend error. The run's own clock (`date`) is never used (RQFAIL-1). The current code falls back to
  `date +%s`; that is removed.
- Release (`claim_coordinator_release`): delete this run's own record (found by one read, matching
  trusted prefix + own holder), then remove the label, so a later run never counts it (RQREL-1).
- local-fs backend: flock already serialises the add; unchanged.

What already owns the job: the coordinator plugin (`plugins/claim-coordinator/github-labels/`), the
`lib/takeover.sh` pattern for coordinator-side helpers, and ADR-005 §5 (already drafted in the working
copy). The working copy already holds the race helpers in `plugin.sh` (433 lines); the change needs ~40
more lines, so the race helpers move to `lib/race.sh` (as `takeover.sh` is a lib) to keep `plugin.sh`
under 500 lines.

Outside assumptions:
- `rsc_gh`, `jq`, GitHub comments API: already used in `plugin.sh`. A failed read-back or post fails
  closed (record + label removed, backend error).
- GitHub's `created_at` and `id` are assigned at POST time and are stable; once both records are visible
  every run picks the same winner. Known accepted limit (RQLIM-1): if each run reads before the other's
  record is visible, both proceed. Stated in ADR-005 §5 and in the PR body.
- The record format is distinct from takeover notes ("took over a stale claim from"): no interference.

UNCLEAR RQTIE-3 | "Either the claim writes its holder record itself, synchronously, before it re-reads, or the tie-break uses something that exists at claim time" | (a) own comment record, (b) label-added time | ASSUMED: (a), the own comment record.

```steps
- 1.1 Move the race helpers into a new lib sourced like takeover.sh; post the record and read `created_at` without a clock fallback (no time → rc distinct from a post failure); read back with a window of ZBUILD_CLAIM_RACE_WINDOW_S (default 120) from one comments read that yields winner and own record; add a helper that deletes this run's own record for release | areas: plugins/claim-coordinator/github-labels/lib/race.sh | serves: DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-9, DSRACE-10, DSRACE-11, DSRACE-13, DSRACE-14
- 1.2 In `claim_coordinator_claim` source the lib, drop the label re-read, fail closed on a missing time (delete record, remove label), and in `claim_coordinator_release` delete the run's own record before removing the label | areas: plugins/claim-coordinator/github-labels/plugin.sh | serves: DSRACE-1, DSRACE-2, DSRACE-8, DSRACE-9, DSRACE-12, DSRACE-14
- 2 `zbuild_claim_acquire` refuses at once on `race_lost: true`, naming the winner, without stale takeover (kept from earlier rounds; check it still holds) | areas: core/claim/claim.sh | serves: DSRACE-4, DSRACE-5
- 3 Amend ADR-005 §5: window setting and default, no label re-read, fail-closed on a missing time, release removes the record, known limit, tests named inline in the text and in Enforced by | areas: docs/adr/ADR-005-claim-coordinator.md | serves: DSRACE-6
```

```acceptance
DSRACE-1[code]: After adding the label (gh backend) the claim posts its holder record "concurrent claim by `<holder>`" before it reads any records back covers: RQTIE-1, RQTIE-3
  Given: the label was added through the gh backend
  When: the claim runs
  Then: the record is on the issue before the first read of the issue's comments

DSRACE-2[code]: Of two concurrent claims exactly one returns {"acquired": true}, the one whose record is first by created_at covers: RQTIE-1, RQTIE-2, RQTIE-4
  Given: two runs claim the same issue through the fake GitHub
  When: both claims finish
  Then: exactly one returns {"acquired": true}
  And: the other returns {"acquired": false, "holder": "<winner>", "race_lost": true}

DSRACE-3[code]: The losing run marks its record as not started covers: RQCMT-1
  Given: this run's record is not the first
  When: the run finds it lost
  Then: its record reads "not started — concurrent claim: `<winner>` was first"

DSRACE-4[code]: A race loser keeps the label: after race_lost the engine sets no claim and its release does not remove zbuild:claimed covers: RQLBL-1, RQTST-3
  Given: claim_coordinator_claim returns {"acquired": false, "race_lost": true}
  When: zbuild_claim_acquire processes the reply and the run exits
  Then: the label is still on the issue

DSRACE-5[code]: race_lost makes zbuild_claim_acquire refuse at once without the stale-takeover hook, naming the winner covers: RQTIE-1, RQSCP-1
  Given: the coordinator returns {"acquired": false, "holder": "<winner>", "race_lost": true}
  When: zbuild_claim_acquire processes the reply
  Then: the takeover hook is not called
  And: stderr names the winner as the first claimant

DSRACE-6[doc]: ADR-005 §5 tells a reader that the first record by GitHub's created_at then id wins, the window is ZBUILD_CLAIM_RACE_WINDOW_S (default 120), a record with no time fails closed, release removes the record, the known limit (both read before the other's record is visible, both proceed), and names its enforcing tests inline covers: RQADR-1, RQADR-2, RQADR-3, RQLIM-1

REMOVED: DSRACE-7 — it required re-reading the issue's labels after the record; RQREB-2 forbids it, and reading the records back is the re-read.

DSRACE-8[code]: After posting its record the claim does not read the issue's labels again; the one comments read is the re-read covers: RQREB-1, RQREB-2
  Given: the label was added and the record posted
  When: the claim runs to its answer
  Then: the issue's labels are read once (before the add), not after the record

DSRACE-9[code]: If GitHub's reply to the record POST has no created_at, the claim removes its record and the label and does not acquire covers: RQFAIL-1, RQTST-4
  Given: the fake GitHub answers the record POST without created_at
  When: the claim runs
  Then: the answer is not acquired
  And: the record and the label are no longer on the issue
  And: no value from the run's own clock is used

DSRACE-10[code]: With no setting, a record older than 120 seconds before this run's record is not counted covers: RQWIN-1, RQWIN-2, RQTST-6
  Given: ZBUILD_CLAIM_RACE_WINDOW_S is unset and another run's record is 121 s before this run's
  When: the claim runs
  Then: this run returns {"acquired": true}

DSRACE-11[code]: ZBUILD_CLAIM_RACE_WINDOW_S sets the window on its own, not derived from ZBUILD_STATUS_COMMENT_GH_TIMEOUT covers: RQWIN-2, RQTST-6
  Given: ZBUILD_CLAIM_RACE_WINDOW_S=10 and ZBUILD_STATUS_COMMENT_GH_TIMEOUT set to a large value; another record is 30 s before this run's
  When: the claim runs
  Then: that record is not counted and this run returns {"acquired": true}

DSRACE-12[code]: Release removes the run's own record, so claim, release, claim again inside the window acquires covers: RQREL-1, RQTST-5
  Given: run A claimed and released, then run B claims inside the window
  When: B's claim finishes
  Then: A's record is no longer on the issue
  And: B returns {"acquired": true}

DSRACE-13[code]: Two records with the same created_at are ordered by id; the lower id wins covers: RQTIE-4, RQTST-2
  Given: the fake GitHub gives both records the same created_at
  When: both claims finish
  Then: the run whose record has the lower id returns {"acquired": true}

DSRACE-14[code]: One read of the issue's comments finds both the winner and this run's own record covers: RQREAD-1
  Given: a claim that posted its record
  When: the claim arbitrates
  Then: the comments list is requested once per claim

DSRACE-15[no-code]: The race tests run two real claims through a fake gh that keeps the labels and comments our code posts, never touch the real repo, and the coordinator's unit test uses no GNU-only sed -i covers: RQTST-1, RQTST-7, RQPORT-1, RQSCP-2

WIRING:
core/claim/claim.sh
plugins/claim-coordinator/github-labels/plugin.sh
```

```supersedes
plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh [DSRACE-7]: asserted a label re-read after the record; RQREB-2 forbids it, the test goes with the REMOVED SPEC
plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh [DSRACE-1/2]: any assertion that the window is 4 × ZBUILD_STATUS_COMMENT_GH_TIMEOUT or that a missing created_at falls back to the run's clock is now wrong
```

## Findings
- DSFND-5, RLREDTEAM-2, RLSCOPE-2: kept as answered earlier; the outside-assumption text still does not accept both-proceed as a result except the stated known limit RQLIM-1, which the issue itself accepts.
- Requirements changed since the last design: RQREB-2 removed the label re-read (DSRACE-7 REMOVED); the others added DSRACE-8..15.
