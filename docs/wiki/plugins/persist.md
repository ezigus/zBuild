# persist

The persist plugin snapshots a run's artifact area to the ADR-050 state branch (`zbuild/state/issue-<N>`) and **pushes it to origin**, on every pipeline exit path — pass, fail, abort, SIGINT, SIGTERM, timeout. It always returns 0: persistence is advisory, and a run that produced good work but could not reach the network still produced good work.

**Persist Plugin**

- **Kind:** `tool`
- **Role:** `persist`
- **Manifest:** `plugins/tool/persist/manifest.yaml`

## Manifest

```yaml
id: persist
name: Persist Stage
kind: tool
version: 0.1.0
hooks:
  run: persist_run
```

## Why this exists

`core/state/artifact-persist.sh` has never contained a `git push`. It writes a *local* ref with git plumbing and reads `refs/remotes/origin/<branch>` only as a restore fallback. The only state-branch push anywhere in the repository was a shell block inside `.github/workflows/zbuild-pipeline.yml` — which no local run executes.

So ADR-050 §4's *"push the state branch once at the end, pass or fail"* was true of CI and of nothing else. Issue #1921 measured the result: hundreds of commits on local state branches, effectively nothing on origin. A dead laptop lost all of it.

This stage closes that gap through **one** mechanism for local and CI alike, which is what ADR-050 asked for and did not get.

## Behavior

1. **Final snapshot.** The per-stage snapshots (ADR-050 §4) already ran at each stage boundary. This one catches whatever the *last* stage produced — including the stage that failed and ended the run, which no boundary call covers.
2. **Secret gate.** Every text artifact is scanned for credentials using the shared patterns in `scripts/lib/secret-patterns.sh`. A finding **refuses the push** and emits `persist.push.refused`. Publishing a credential is not recoverable the way a missing snapshot is.
3. **Push.** `git push --force` to `zbuild/state/issue-<N>`. Force matches the existing CI push: the state branch is a snapshot, not a history.

A `--goal` run has no issue number and therefore no branch to push to. That is a genuine no-op today; ADR-059 §5 gives goal runs an identity of their own (#1931).

## Always-run, and why it is a separate stage from `release`

Both are declared in the template's `always_run:` list (#1831), in this order:

```yaml
always_run:
  - release
  - persist
```

The order is load-bearing. `release` frees live resources — process groups, locks, handles — and must stay fast, because it runs inside the exit trap and a hang there turns Ctrl-C into a lockup. `persist` does network I/O and can block on auth or a dead remote. Persist last, with its own `timeout_s` (120 vs release's 30), means a bad network can never delay an abort.

Declaring it in the template rather than wiring a call site is the point. `_runner_snapshot_artifacts` is invoked from six stage-boundary sites and was gated on `issue > 0`; a snapshot that happens only where someone remembered to wire it is the failure #1878 already found once — *"the snapshot was never called."*

## Events

| Event | Meaning |
|-------|---------|
| `persist.start` | Stage entered |
| `persist.complete` | Stage finished; carries `pushed` and `snapshot` |
| `persist.snapshot.failed` | The final snapshot failed; the run is unaffected |
| `persist.push.refused` | An artifact looks like it carries a credential; nothing was pushed |
| `persist.push.failed` | The push failed; state is local only |
| `persist.result.write_failed` | The result file could not be written |

A failed push is **loud**. A silent one is how #1921 went unnoticed for the life of the feature.

## Result contract

Writes `persist-result.json` (v2, ADR-054 §5) with `verdict: complete` or `degraded`, and `data.snapshot` / `data.pushed`.

`degraded` means the work was done but not fully published — a failed snapshot, a failed push, or a refused push. It never blocks a merge and never changes the run's verdict.

## References

- ADR-050 §4, §7 — the durable store and the push that moved out of CI
- ADR-059 §3 — git is the store, the folder is the working copy
- #1071 (this stage), #1921 (zero on origin), #1878 (the snapshot was never called), #1632 (the pruner this makes necessary), #1831 (`always_run`)
