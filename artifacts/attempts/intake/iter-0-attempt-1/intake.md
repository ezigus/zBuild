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

Write it as a test first and watch it fail. Use a stubbed `gh` and never touch the real repo.

- **R1.** Two runs claim at once. Only the run that claimed first proceeds; the other exits without removing the label, and its progress comment says it did not start.

## Scope

- **Code:** `plugins/claim-coordinator/github-labels/plugin.sh`, `core/pipeline/runner.sh`.
- **ADR:** `docs/adr/ADR-005-claim-coordinator.md`.
- **Tests:** `tests/e2e/claim-race-test.sh`, `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`.
