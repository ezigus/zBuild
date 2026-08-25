[bug] the ADR-050 state branch never fires in CI — local snapshots work, origin has none, so every CI retry is a cold start

**Build Mode: Dogfood** — ADR-057 gate 4, re-derived 2026-08-24 (was `Design Decision needed`). **The decision this was waiting on has been made and built.** ADR-059 §Phase 2 settled it — *git is the store; every run pushes to it, local and CI alike* — and the push that never existed now does: `_artifact_persist_push` (`core/state/artifact-persist.sh:295`), invoked by the always-run `persist` stage (`plugins/tool/persist/plugin.sh:130`, wired at `config/templates/simple.yaml:67`). Gate 1 no longer fires; nothing here is a pending decision.

> ### Status 2026-08-24 — what is left is VERIFICATION, not design
>
> The original defect (*"artifact-persist contains no `git push` at all"*) is **fixed**. What is not yet proven is that it fires **in CI**, which is the half this issue was filed for.
>
> Measured on this machine, 2026-08-24:
> ```
> local  refs/heads/zbuild/state/*  = 11
> origin refs/heads/zbuild/state/*  = 2   (issue-1789, issue-4244)
> ```
> So origin is no longer empty — but two branches against eleven local is not evidence the CI path works; both could be local pushes. `issue-4244` is **residue**, not a real run: it is the issue number used by `tests/unit/persist-stage-test.sh`, pushed by a pre-secret-gate version of that test. The local-ref leak is fixed (re-verified 2026-08-24: running that file creates no refs), but the stray origin branch should be deleted.
>
> **Remaining work:**
> 1. Delete `origin/zbuild/state/issue-4244` (test residue).
> 2. Drive one CI pipeline run and assert a `zbuild/state/issue-<N>` branch appears on origin with that run's commit — the assertion this issue exists to make.
> 3. Confirm `hydrate` reads it back on the next CI run (cold start stops being cold).
> 4. If the push is refused in CI, the cause is almost certainly the App token, not the code — cross-reference #1780.

Part of #1819 (Phase 0 — the stage↔engine contract).

**Build Mode: Design Decision needed** — the symptoms are measured, the cause is not. This issue must not be built until the cause is traced; this repo has lost runs to issues built on unverified premises (#1635, #1755).

**Classification: INFRA — `core/state/artifact-persist.sh` × `.github/workflows/zbuild-pipeline.yml`.**

## Measured

ADR-050 / #1581 prior-work reuse persists a run's artifacts to a per-issue state branch (`zbuild/state/issue-<N>`) so a later run can restore them instead of starting cold. Both halves are wired in CI: a fetch at `zbuild-pipeline.yml:118-140` and a push at `:236-243`.

Measured on the operator's checkout, 2026-08-22:

| branch | commits | last commit |
|---|---|---|
| `zbuild/state/issue-999` | 344 | 2026-08-21 |
| `zbuild/state/issue-698` | 195 | 2026-08-21 |
| `zbuild/state/issue-1832` | 89 | 2026-08-18 |
| `zbuild/state/issue-1860` | 68 | 2026-08-20 |
| `zbuild/state/issue-1750` | 32 | 2026-08-21 |

```
$ git ls-remote origin 'refs/heads/zbuild/state/*' | wc -l
0
```

**Local snapshotting works, and has all along.** Five branches, hundreds of commits, current. Origin has none.

| direction | works? | why |
|---|---|---|
| local → local | **yes** | snapshots land on the local branch and a later local run restores from it |
| local → CI | no | nothing pushes from a local run; only the CI workflow pushes |
| CI → CI | **no** | origin has no state branches despite the push step existing |
| CI → local | no | nothing on origin to fetch |

## Related design decision (2026-08-23) — covers one row, not the issue

A layout redesign now in flight adds an always-run **persist** stage that pushes state to
`zbuild/state/issue-<N>` on **every** exit path, from local runs as well as CI. That directly
closes the **local → CI** row of the table above — *"nothing pushes from a local run; only the CI
workflow pushes"* — because a local run would push too.

**It does not answer this issue's narrow question.** Why `_artifact_persist_snapshot` produces
nothing on a fresh CI runner is unchanged, and the four untested candidates below still stand.
The push at `:236-243` is not the defect; it correctly reports *"no state branch to push"*
because there is nothing to push. **This issue stays `Design Decision needed` and must still be
traced before it is built.**

One consequence worth noting: if the persist stage lands first, a local run will have pushed the
branch to origin, so a later CI run's fetch will find one. That would mask the CI-side snapshot
failure rather than fix it — so trace the cause *before* relying on the new stage.

## The narrow question

The push at `:236-243` is conditional on the branch existing locally on the runner:

```
echo "::notice::no state branch '$state_branch' to push (nothing was snapshotted)"
```

So the **snapshot is not firing on a fresh, shallow-cloned CI runner** — the push is doing exactly what it was told. #1632 independently records the same zero-on-origin observation and attributes it to the #1601 run producing nothing.

Candidates, untested:
1. `_artifact_persist_snapshot` fails against a **shallow** clone (`fetch-depth` in the checkout step) — it builds a tree through a throwaway `GIT_INDEX_FILE` and reads `--git-common-dir` (`core/state/artifact-persist.sh:59-68,104`).
2. The snapshot's ref update is refused (#1764 documents a bare check-then-update-ref with no lock or CAS).
3. The call sites are never reached on the CI path — all are post-stage-completion (`runner.sh:2907,3008,3085,3409`, `cycle-orchestrator.sh:213-214`), so an early abort skips them.
4. `_ARTIFACT_PERSIST_LAST_STATUS` returns `failed`/`empty` and the outcome is discarded.

`_artifact_persist_snapshot` has a structured outcome channel (`saved|empty|unchanged|failed` + `_LAST_REASON`) — the first diagnostic step is to surface it in a CI run rather than guess.

## Cost

Every CI retry of a failed issue is a **cold start**, redoing work a previous attempt already completed. That is the entire value ADR-050 was built for, and it has never been realised in CI.

## Ask

1. Trace the cause on a real CI run — surface `_ARTIFACT_PERSIST_LAST_STATUS` and `_LAST_REASON` in the job log first.
2. Then decide the fix and rewrite this issue's Ask with a cause, not a symptom.

## Acceptance

- [ ] A CI run's snapshot outcome (`saved`/`empty`/`unchanged`/`failed` + reason) is visible in the job log.
- [ ] The cause of the non-firing snapshot is stated in this issue before implementation begins.
- [ ] After the fix: a second CI run on the same issue restores artifacts from the state branch rather than starting cold, proven by a run log.
- [ ] Guard: local → local reuse still works exactly as it does today.

## Correction to an earlier claim

An earlier investigation of mine recorded *"zero `artifact.snapshot.saved` events ever, zero `zbuild/state/*` refs on origin ever — every CI re-run is a cold start."* The second half is right; **the first half is wrong** — local snapshots plainly do fire. The defect is CI-specific, and stating it as universal would have sent an implementer to the wrong layer.

Where: `core/state/artifact-persist.sh`, `.github/workflows/zbuild-pipeline.yml:118-140,236-243`, `core/pipeline/runner.sh:1808-1838`. Refs ADR-050, #1581, #1632, #1764, #1601.
