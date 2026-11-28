claim tie-break — when two runs claim an issue at once, the first claim wins (ADR-005, part 3 of #1764)

## Decision

When two runs claim an issue at the same moment, exactly one proceeds. Part 3 of 3: depends on #1764 (the shared label) and #2533 (heartbeat and staleness).

- After adding the label, a run re-reads the issue. If another run claimed it too, the **run that claimed first wins**. The later run marks its progress comment as not started and exits without removing the label.
- Today the progress comment is started in the background, after the issue lock (`zbuild_issue_lock_acquire`, `core/pipeline/runner.sh`) and `pipeline.start`, so at claim time a run has no comment of its own to compare. Either the claim writes its holder record itself, synchronously, before it re-reads, or the tie-break uses something that exists at claim time (for example when the label was added).

## What is wrong today

- Adding a label is not exclusive: two runs that read the issue at the same moment both see no label, both add it, and both proceed.

## ADR

- **Amend ADR-005**: the first claim wins a tie, and how "first" is decided. ADR-005 is in `config/adr-enforcement-baseline.txt`, so the amendment names its enforcing tests inline.

## Required behavior

Write it as a test first and watch it fail. Never touch the real repo.

- **R1.** Two runs claim at once. Only the run that claimed first proceeds; the other exits without removing the label, and its progress comment says it did not start.
- **R2.** A run that releases its claim removes its holder record (its concurrent claim note), so a later run never counts it.
- **R3.** "First" is read from the times GitHub gives the holder records. Records with the same time are ordered by their id.
- **R4.** If GitHub's reply to posting the holder record has no time, the claim fails closed: the run removes its record and the label and does not proceed. The run's own clock is never used in its place.
- **R5.** Another run's record counts only inside a window before this run's record. The window is its own setting, `ZBUILD_CLAIM_RACE_WINDOW_S`, with a plain default of 120 seconds; it is not worked out from another setting.
- **R6.** After posting its holder record, a run does not re-read the issue's labels. Reading the holder records back is the re-read.
- **R7.** One read of the holder records finds both the winner and the run's own record.

## Tests

- Two real claims run through a **fake GitHub**: a stand-in `gh` that keeps the comments and labels our code posts and gives them back when read (ADR-012, `.zbuild/rules.md`). No test hand-writes a reply that holds our own holder record.
- The tests cover:
  - the winner, when the two records have the same time and differ only by id (R1, R3);
  - the loser keeping the label (R1);
  - a reply with no time, failing closed (R4);
  - claim, release, then claim again inside the window (R2, R5);
  - the window setting and its default (R5).
- The coordinator's unit test runs on macOS as well as Linux: no GNU-only `sed -i`.

## Known limit (accepted)

If each run reads the holder records back before the other run's record is visible, both proceed. This is accepted for now; the PR says so.

## Scope

- **Code:** `plugins/claim-coordinator/github-labels/plugin.sh`, `core/claim/claim.sh`, `core/pipeline/runner.sh`.
- **ADR:** `docs/adr/ADR-005-claim-coordinator.md`.
- **Tests:** `tests/e2e/claim-race-test.sh`, `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`, `tests/unit/claim-acquire-release-test.sh`.
