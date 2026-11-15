cross-machine issue claim — one shared label, claimed and released by the engine (ADR-005, part 1 of 3 — then #2533, #2534)

## Decision

**Know when someone else is working on an issue, across machines, and refuse to start until it is clear.** GitHub is the central place. The claim goes through the ADR-005 **claim coordinator**, so another tracker (e.g. JIRA) can replace GitHub later by providing its own coordinator.

Part 1 of 3: the shared label, claimed and released by the engine. Part 2 (#2533) adds the heartbeat and stale takeover; part 3 (#2534) settles two runs claiming at the same moment.

- **One shared label for every run, local or CI:** `zbuild:claimed`. The label means "a run is working on this issue". Who holds it (run id, machine or CI job) is in that run's progress comment (ADR-064), not in the label.
- **Claim:** before the first stage dispatches, a run reads the issue.
  - If `zbuild:claimed` is present, the run refuses to start and says who holds it, read from the holder's progress comment when there is one.
  - If the label is absent, the run adds it.
- **Release:** when a run ends, whether it passed, failed or was interrupted, the EXIT path removes the label and marks its progress comment finished.
- **Manual clear:** removing the label by hand clears the claim. Until #2533, this is the only way to clear the label of a run that crashed without reaching its EXIT path.
- **Do not build:**
  - a check of a CI job's status through the GitHub Actions API;
  - a "do I still hold the claim" check before each stage.
- The one-machine admission lock (`core/state/issue-lock.sh`, ADR-059 §4) stays as the fast first check.

## What is wrong today

- `plugins/claim-coordinator/github-labels/` implements ADR-005's four hooks, but **nothing in the engine calls it**. No run ever claims an issue.
- It uses a per-machine label, `claimed:<hostname>`, so a local run and a CI run don't see each other as the same claim.
- The only protection today is the one-machine lock. Two machines (a laptop and CI) can run one issue at once, and both force-push the same state branch (`_artifact_persist_push`, `core/state/artifact-persist.sh`). The last push silently wipes the other's saved work.

## ADR

- **Amend ADR-005** (claim coordinator) with:
  - the engine calls the coordinator: claim before the first stage, release in the EXIT path;
  - the single shared label;
  - the stale parts of ADR-005 corrected: selection is not from `config/zbuild.yaml` (no such file), and "the engine has no built-in mechanism" no longer holds once the engine calls the coordinator.

  ADR-005 is in `config/adr-enforcement-baseline.txt`, so the amendment names its enforcing tests inline.
- **ADR-059 §4:** note that cross-machine exclusion is the claim coordinator's job, and the admission lock stays for one machine.

## Required behavior

Write each as a test first and watch it fail. Use a stubbed `gh` and never touch the real repo.

- **R1.** The issue has no `zbuild:claimed` label. The run adds it before the first stage dispatches, and its progress comment names the holder: run id and machine, or CI run URL.
- **R2.** The label is present. The run refuses to start (non-zero exit, no stage dispatched), and its message names the holder when the holder's progress comment says who it is.
- **R3.** On a normal end, a failure and an interrupt (TERM), the label is removed and the progress comment is marked finished.
- **R4.** A run with no issue (goal only) makes no claim.
- **R5.** A local run and a CI run use the same label. There is no hostname in the label.

## Scope

- **Code:**
  - `plugins/claim-coordinator/github-labels/plugin.sh`, `manifest.yaml`, `README.md` (single label; the README still calls it the coordinator "for the zbuild daemon" with `claimed:<machine>`)
  - `core/pipeline/runner.sh` (claim at startup, release in the EXIT trap)
- **ADRs:** `docs/adr/ADR-005-claim-coordinator.md`, `docs/adr/ADR-059-issue-vs-run-keying.md`.
- **Tests:**
  - `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
  - `tests/e2e/claim-race-test.sh`
  - `tests/integration/teardown-repeat-signal-test.sh` (release must survive a second TERM)
- **Out of scope:** heartbeat and staleness (#2533); a tie between two runs claiming at once (#2534); a compare-and-swap on `update-ref` in `core/state/artifact-persist.sh` (ADR-059 §4 chose the admission lock instead).
