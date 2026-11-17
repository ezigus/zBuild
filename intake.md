cross-machine issue claim — one shared label, claimed and released by the engine (ADR-005, part 1 of 3 — then #2533, #2534)

## Decision

**Know when someone else is working on an issue, across machines, and refuse to start until it is clear.** GitHub is the central place. The claim goes through the ADR-005 **claim coordinator** plugin (`plugins/claim-coordinator/github-labels/`), so another tracker (e.g. JIRA) can replace GitHub later by providing its own coordinator.

Part 1 of 3: the shared label, claimed and released by the engine. Part 2 (#2533) adds the heartbeat and stale takeover; part 3 (#2534) settles two runs claiming at the same moment.

- **One shared label for every run, local or CI:** `zbuild:claimed`. The label means "a run is working on this issue". It never says who.
- **Who holds it is written in the run's status comment** — the one comment zbuild already posts on the issue for every run and edits as the run goes (ADR-064, `scripts/lib/run-status-comment.sh`, marked `<!-- zbuild-run-status run_id=… -->`). This issue adds no other comment.
- **Claim:** after the one-machine admission lock and before the first stage dispatches, the engine calls the coordinator's `claim` hook.
  - If `zbuild:claimed` is on the issue, the run refuses to start. Its message names the holder, read from the holder's run-status comment.
  - If the label is absent, the coordinator adds it.
- **Release:** in the EXIT path, whether the run passed, failed or was interrupted, the engine calls the coordinator's `release` hook, which removes the label. The run-status comment is already marked finished on every exit (ADR-064); this issue does not change that.
- **Manual clear:** removing the label by hand clears the claim. Until #2533, this is the only way to clear the label of a run that crashed without reaching its EXIT path.
- **Do not build:**
  - a check of a CI job's status through the GitHub Actions API;
  - a "do I still hold the claim" check before each stage.
- The one-machine admission lock (`core/state/issue-lock.sh`, ADR-059 §4) stays as the fast first check.

## Terms

Each term below means this, and only this, everywhere in this issue.

- **Run-status comment:** the comment ADR-064 already posts and edits for every run (`scripts/lib/run-status-comment.sh`). Not a new comment.
- **Holder:** who has the claim. Locally: the run id and the machine's name. In CI: the CI run's URL.
- **Claim coordinator:** the ADR-005 plugin kind; here `plugins/claim-coordinator/github-labels/`. The engine calls its `claim` and `release` hooks through the plugin registry. The label calls (`gh issue edit`) live in the plugin, not in `core/`.

## What is wrong today

- `plugins/claim-coordinator/github-labels/` implements ADR-005's four hooks, but **nothing in the engine calls it**. No run ever claims an issue.
- It uses a per-machine label, `claimed:<hostname>`, so a local run and a CI run don't see each other as the same claim.
- The only protection today is the one-machine lock. Two machines (a laptop and CI) can run one issue at once, and both force-push the same state branch (`_artifact_persist_push`, `core/state/artifact-persist.sh`). The last push silently wipes the other's saved work.

## ADR

- **Amend ADR-005** (claim coordinator) with:
  - the engine calls the coordinator: `claim` after the admission lock and before the first stage, `release` in the EXIT path;
  - the single shared label, and that the holder is in the run-status comment;
  - the stale parts of ADR-005 corrected: selection is not from `config/zbuild.yaml` (no such file), and "the engine has no built-in mechanism" no longer holds once the engine calls the coordinator.

  ADR-005 is in `config/adr-enforcement-baseline.txt`, so the amendment names its enforcing tests inline.
- **ADR-059 §4:** note that cross-machine exclusion is the claim coordinator's job, and the admission lock stays for one machine.

## Required behavior

Write each as a test first and watch it fail. Use a stubbed `gh` and never touch the real repo.

- **R1.** The issue has no `zbuild:claimed` label. The run adds it before the first stage dispatches, and the run's run-status comment (ADR-064) names the holder: run id and machine, or the CI run's URL.
- **R2.** The issue has the `zbuild:claimed` label. The run refuses to start: non-zero exit, no stage dispatched, and the `pipeline.refused.claimed` event, registered in `config/event-schema.json` next to `pipeline.refused.issue_locked`. Its message names the holder, read from the holder's run-status comment (ADR-064), when that comment names one.
- **R3.** On a normal end, a failure and an interrupt (TERM), the `zbuild:claimed` label is removed. The run-status comment (ADR-064) is marked finished, as it already is today.
- **R4.** A run with no issue (goal only) makes no claim and calls no coordinator hook.
- **R5.** A local run and a CI run use the same label, `zbuild:claimed`. There is no machine name in the label.

## Scope

- **Code:**
  - `plugins/claim-coordinator/github-labels/plugin.sh`, `manifest.yaml`, `README.md` (single label; the README still calls it the coordinator "for the zbuild daemon" with `claimed:<machine>`)
  - `core/pipeline/runner.sh` (call `claim` after the admission lock, `release` in the EXIT trap)
  - `scripts/lib/run-status-comment.sh` / `scripts/lib/run-status-render.sh` (the holder in the comment)
  - `config/event-schema.json` (`pipeline.refused.claimed`)
- **ADRs:** `docs/adr/ADR-005-claim-coordinator.md`, `docs/adr/ADR-059-issue-vs-run-keying.md`.
- **Tests:**
  - `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
  - `tests/e2e/claim-race-test.sh`
  - `tests/integration/teardown-repeat-signal-test.sh` (release must survive a second TERM)
- **Out of scope:** heartbeat and staleness (#2533); a tie between two runs claiming at once (#2534); a compare-and-swap on `update-ref` in `core/state/artifact-persist.sh` (ADR-059 §4 chose the admission lock instead).
