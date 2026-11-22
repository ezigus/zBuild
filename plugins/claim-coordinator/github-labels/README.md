# GitHub Labels Claim Coordinator

**Plugin id:** `claim-coordinator-github-labels`
**Kind:** `claim-coordinator`
**ADR:** [ADR-005 — Claim Coordinator](../../../docs/adr/ADR-005-claim-coordinator.md)

## Purpose

The default cross-machine claim. The engine calls this plugin's `claim` hook before a run's first stage and its `release` hook on exit (ADR-005 §1). One shared GitHub issue label, `zbuild:claimed`, means "a run is working on this issue" — the same label for a laptop run and a CI run. Who holds it is not in the label: it is the `<!-- zbuild-holder: … -->` line of the holder's run-status comment (ADR-064), read back only from comments by the CI bot or by a repository owner, member or collaborator.

## Contract (ADR-005)

| Hook | Signature | stdout | Exit codes |
|---|---|---|---|
| `claim_coordinator_claim` | `claim <issue_id>` | `{"acquired": true}`, `{"acquired": false, "holder": "…"}`, or `{"acquired": false, "skipped": "…"}` | 0 answered, 1 backend error, 2 usage error |
| `claim_coordinator_release` | `release <issue_id>` | — | 0 removed, 1 failed (stderr says to remove the label by hand) |
| `claim_coordinator_heartbeat` | `heartbeat <issue_id>` | — | 0 always (labels don't expire; staleness is #2533) |
| `claim_coordinator_list_claims` | `list_claims` | `[{"issue": N, "holder": "...", "acquired_at": null}]` | 0 success, 1 backend error |

## Behaviour

- **Missing label.** A repository that does not define `zbuild:claimed` gets it (`gh label create --force`) the first time an add fails with "not found"; the add is then tried once more.
- **Every `gh` call is bounded** by the run-status comment's watchdog (`rsc_gh`, `ZBUILD_STATUS_COMMENT_GH_TIMEOUT`): a hung `gh` cannot hold up a run's exit.
- **`NO_GITHUB=true`** makes no claim: the reply is `skipped`, and the engine records `pipeline.claim.skipped`.
- **Clearing a claim by hand.** Removing the `zbuild:claimed` label clears it. Until #2533, that is the only way to clear the claim of a run that crashed before its exit path — or of a cancelled GitHub Actions job: the cancel sends INT, then TERM, then KILL a few seconds later, and the KILL can land while the exit path is still running the always-run stages and persist, which come before the release.
- **The holder named on a refusal** is the newest run-status comment's: a finished run names none, and neither does a run that posts no comment (`ZBUILD_STATUS_COMMENT=0`), so the refusal then says the holder is unknown rather than naming an older run.

## Known limit: two runs claiming at the same moment

GitHub's label add does not check whether the label is already there. Two runs that read "no label" at the same moment can both add it and both start. Nothing here prevents that; #2534 settles it.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ZBUILD_CLAIM_BACKEND` | `gh` | `gh` (GitHub), or `local-fs` (a flock-serialised local store, for tests) |
| `ZBUILD_CLAIM_STORE` | _(required for local-fs)_ | Directory of the local-fs store: `<issue>/labels.txt`, and `<issue>/run-status-comment.txt` for the holder |
| `ZBUILD_CLAIM_FLOCK_TIMEOUT_SEC` | `5` | flock wait for the local-fs store |
| `ZBUILD_CLAIM_MACHINE_ID` | `${HOSTNAME}` | The machine named in a local run's holder (engine side, `core/claim/claim.sh`) |
| `ZBUILD_STATUS_COMMENT_GH_TIMEOUT` | `30` | Seconds a `gh` call may take |

The test harness (`setup_test_env`) sets `NO_GITHUB=true` and the local-fs store, so a test never claims on GitHub.
