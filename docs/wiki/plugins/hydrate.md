# hydrate

The hydrate plugin puts this issue's earlier outputs, saved on the ADR-050 state branch (`zbuild/state/issue-<N>`), back in their live places in the run's artifacts folder. A rerun of an issue continues it: each is that stage's latest output until the stage writes a newer one (ADR-050 §9). A file the run already has is kept.

**Hydrate Plugin**

- **Kind:** `tool`
- **Role:** `hydrate`
- **Manifest:** `plugins/tool/hydrate/manifest.yaml`

## Manifest

```yaml
id: hydrate
name: Hydrate Stage
kind: tool
version: 0.1.0
hooks:
  run: hydrate_run
```

## What was missing

Restore itself already ran, as engine code, identically in local runs and CI. Two things did not.

**The fetch.** `_artifact_persist_restore` reads `refs/heads/<branch>` first and `refs/remotes/origin/<branch>` second. On a fresh clone — which every CI runner is — *neither* exists until something fetches, so restore reported "first run" for an issue with plenty of prior work. That only ever worked because the CI workflow fetched the branch itself in a `run:` block. Doing it in the stage is what makes local and CI one mechanism, which is the same gap the `persist` stage closes on the way out.

**A guarantee against partial trees.** `git archive | tar` can fail mid-stream — disk full, permissions — leaving a half-extracted tree that satisfies a bare `-d`/`-n` check. PR #1880's review caught the engine adopting one and added a status gate. Hydrate extracts to a staging directory and copies only a complete extraction into place, so a half-extracted tree never reaches a stage. The failure mode is removed rather than detected.

## One place to read

There is no separate restored area. Hydrate copies the earlier run's outputs into the live
`artifacts/` folder, skipping any file the run already has, so every reader — the previous-work index,
the prior-output reader, design's own latest design — reads one place. What moved since a stage last ran
(files changed, whether the issue text changed) is the engine's to say, in each stage's Previous work
block (ADR-067 §8).

## Local wins on read, and that is deliberate

ADR-059 §3 says git is the store. That is about **durability**, not read precedence.

`_artifact_persist_restore` prefers `refs/heads/<branch>` over `refs/remotes/origin/<branch>`, and hydrate keeps it that way. A local snapshot may carry work an earlier push never delivered; preferring origin there would *lose* that work, which is the opposite of the goal. `git fetch` updates only the remote-tracking ref and never moves `refs/heads`, so fetching cannot clobber an unpushed local snapshot.

Within a run, a live artifact still beats a restored one — `input-resolve.sh` tries the live path first. A stage's own output should not be overwritten by an older copy of itself.

## Position

First in `flow:`, before intake. **Not** always-run: there is nothing to hydrate at the end of a run. That is the asymmetry with `release` and `persist`, which are always-run and are not in the flow at all.

An **old-shape** template (`stages:` rather than `flow:`) inherits nothing from its base under ADR-016's full-replace overlay, so it must list `hydrate` itself. Unlike `always_run:` — which is shape-independent because losing resource cleanup silently is unacceptable — losing prior-work restore degrades to doing the work from scratch. It is an optimisation, not a safety mechanism, and the seam already documents the fallback.

## Events

| Event | Meaning |
|-------|---------|
| `hydrate.start` | Stage entered |
| `hydrate.complete` | Finished; carries `restored` (file count) and `status` |
| `hydrate.fetch.failed` | Could not reach origin; a local snapshot may still be used |
| `hydrate.restore.failed` | Extraction failed; the staging tree is discarded whole |
| `hydrate.result.write_failed` | The result file could not be written |

## Result contract

Writes `hydrate-result.json` (v2, ADR-054 §5) with `verdict: complete` or `degraded`, and `data.status` / `data.restored`.

Always returns 0. Prior work is an optimisation: a run that finds none still has everything it needs to do the work from scratch.

## References

- ADR-050 §4, §7 — the durable store and the stages that read and write it
- ADR-059 §3 — git is the store, the folder is the working copy
- #1074 (this stage), #1071 (`persist`, its counterpart), #1880 (the partial-tree hazard), #1831 (`always_run`, and why hydrate is not one)
