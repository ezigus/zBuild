# ADR-059: What belongs to an issue, what belongs to a run

**Status:** Accepted (2026-08-23)
**Date:** 2026-08-23
**Issue:** #141
**Amends:** ADR-023 (§#888 layout string), ADR-024 (the nested-run fence must widen before the layout moves), ADR-035 (§2 pool-dir exclusion rationale), ADR-050 (§storage layer), ADR-054 §7 (three-actor table is run-keyed throughout), ADR-058 (§1 area lifetimes, §6 retention clock)
**Supersedes:** ADR-052 §Decision 1 ("Reuse is keyed on `run_id`") and its #1869 amendment
**Related:** ADR-006 (resume — supplies the liveness predicate §4 reuses), ADR-011 (the cache and memory stores, which this does not re-key), ADR-052 (engine-owned run worktree)

## Context

Everything zBuild writes is keyed by **run**, across five unrelated roots:

```
~/.zbuild/state/runs/<run_id>/     state, artifacts, events, runtime/, scratch/
~/.zbuild/runs/<run_id>/worktree   the git worktree
${TMPDIR}/zbuild-runs/<run_id>/    orchestrator pools
~/.zbuild/plan-context/            a cross-run cache, keyed differently
~/.zbuild/cache/, ~/.zbuild/state/memory.db
```

**No ADR owns the question this document answers.** ADR-023 states the layout as a given.
ADR-052 §Decision 1 asserts `run_id` keying and defends it on an *ownership* argument —
*"creation needs only `run_id` — which the engine has, and intake does not own"* — and its
"Alternatives considered" weighs three variations on ownership and timing. **Keying is not among
them.** ADR-035 keys pool dirs per run by analogy to #889. ADR-058 lists five writable areas and
gives four of them the lifetime "the run".

That absence is the defect this ADR exists to correct. Run-keying was **inherited, not decided**.

### What run-keying was actually chosen for

#887 (per-run state) and #888 (per-run worktree) were both filed for one incident:

> *"#846's `plan.json` clobbered #864's, so #864's `build_test_cycle` executed #846's plan — 77
> min, zero usable output."*

**Two runs of different issues.** Issue-keying separates those equally well. Same-issue re-runs
appear in neither rationale.

### What it cost

Two mechanisms exist solely to reconnect what run-keying split apart, and both say so:

> **#1658:** *"The next `zbuild pipeline start` for that issue creates a **new** worktree (**the
> path is keyed by `run_id`**), intake tries to check the branch out there, and git refuses."*
>
> **#1869:** *"A bare `zbuild pipeline start --issue N` therefore collides with its own previous
> run, every time, and **the collision is terminal**."*

`zbuild_worktree_reclaim_dead` — with four refusal codes, a liveness predicate, a mutation spec
and a test file — exists to resolve a collision between two runs of *one issue* over *one
branch*. ADR-050's `zbuild/state/issue-<N>` branch exists so a later run of the same issue can
read work an earlier run produced, because the two runs cannot see each other's directories.

Both were built *around* the keying rather than questioning it.

### Measured

On the operator's store, 2026-08-23: **35 consecutive same-issue run pairs, zero overlapping.**
Every re-run of an issue began after its predecessor had ended, typically minutes later. The
concurrency run-keying buys has never been exercised; the machinery compensating for it is
exercised constantly.

## Decision

### 1. Three lifetimes, and the path states which

| Belongs to | Contains | Lifetime |
|---|---|---|
| **the repository** | everything below it | as long as the repo is worked on |
| **the issue** (or goal) | the worktree, prior-work artifacts | across runs, until reclaimed |
| **the run** | scratch, runtime bookkeeping, events, `pipeline-state.json` | the run, then evidence |

```
$ZBUILD_HOME/                              default ~/.zbuild
  repos/<repo>/
    issues/<N>/          or  goals/<goal_hash>/
      worktree/                  one tree, reused across runs
      artifacts/                 prior work, readable by the next run
      runs/<run_id>/
        scratch/  runtime/  events.jsonl  pipeline-state.json
        pool/                    orchestrator pool dirs (ADR-035)
  cache/<key>                    content-keyed — neither issue nor run (ADR-011)
  memory.db                      never reclaimed (ADR-011)
```

**Pool dirs move here from `${TMPDIR}/zbuild-runs/`, and that is a storage-class
change, not only a path change.** ADR-035 keys them per run and that keying is correct —
nothing reads a finished run's pool to start the next one. What changes is the medium.
`${TMPDIR}` is ephemeral by contract, and ADR-023 already rejected it for the worktree
on measured evidence: on macOS it resolves into `/var/folders/...`, where entries can
**vanish mid-run** (#1571, #1609/#1611). A pool dir holds live coordination state for a
dispatch, so it has the same exposure the worktree had, for the same reason. Bringing it
under `$ZBUILD_HOME` also puts it inside something a reclaimer can name — which the
2026-08-22 amendment to ADR-035 already conceded when it reversed *"pool dirs are
intentionally not in the cleanup scanner."*

**The path is the keying.** No registry, no table of "which things are per-run", nothing to drift.
A reclaimer deletes a `runs/<id>/` or an `issues/<N>/` and the scope follows from where it sits.

### 2. Why the worktree belongs to the issue

A worktree holds a branch, and **the branch is named for the issue**
(`zbuild/issue-<N>-<slug>`). Keying the tree by run while the branch is keyed by issue is the
mismatch that produces #1658 and #1869: two runs of one issue want one branch in two trees, and
git refuses. One tree per issue removes the collision **by construction** rather than by
reclaiming after the fact.

`zbuild_worktree_reclaim_dead`'s *sequential* case — yesterday's dead run — disappears. Its
*concurrent* case does not, and §4 replaces it with something stronger.

The invariant ADR-052 established survives unchanged and is restated here: **no plugin decides
which tree it works in.** The engine still acquires it; only the key changes.

### 3. Prior work is stored in git, and the folder is the working copy

ADR-050 already keys prior work by issue (`zbuild/state/issue-<N>`). This ADR does not add a
competing store. It states which is authoritative:

**Git is the store. Every run pushes to it — local and CI alike. The folder is the working copy.
On a disagreement, git wins.**

This satisfies ADR-050's own requirement — *"identically locally and in GitHub CI … through one
mechanism, not two code paths"* — **literally**, where the present arrangement satisfies it only
in CI, and only because CI has a second code path.

`core/state/artifact-persist.sh` contains **no `git push`** at all. It writes a *local* ref with
plumbing and reads `refs/remotes/origin/<branch>` only as a restore fallback. The only push of a
state branch anywhere in the repository is a shell block inside
`.github/workflows/zbuild-pipeline.yml`, which no local run executes. That is the two-code-path
outcome ADR-050 set out to avoid, arrived at by omission rather than by decision.

#1921 measured the consequence: hundreds of commits on local state branches, **zero on origin**.
Roughly 344 commits of prior work exist on one machine and nowhere else, and a dead laptop loses
all of it. Moving the push into the persist stage puts local and CI on one mechanism and makes
ADR-050 §4's *"push the state branch once at the end, pass or fail"* true of both.

Three stages carry this, declared in the pipeline template rather than buried in the runner:

| stage | position | always-run | does |
|---|---|---|---|
| **hydrate** | before intake | no | pull the branch into the folder; git wins |
| **release** | end | **yes** | free live resources — kill process groups, drop locks. **Deletes nothing** |
| **persist** | end, after release | **yes** | snapshot **and push** to `zbuild/state/issue-<N>` |

Two of the three already exist as engine code and **move out of the engine into plugins**:
`_artifact_persist_restore` (`core/pipeline/runner.sh:1813`) becomes hydrate; the RUN-END snapshot
becomes persist, plus the push that was never written. `core/state/artifact-persist.sh` remains as
the shared library both source.

**Corrected 2026-08-23, while building #1071.** This sentence first said
*"`_runner_snapshot_artifacts` (`:146`) becomes persist"*, which reads as moving the function
wholesale. It is called from **six** stage-boundary sites, and that is ADR-050 §4's incremental
design — *"commit a snapshot at each stage boundary, so a mid-run crash still leaves every
completed stage recoverable"*. Those stay engine-side; they are stage-boundary bookkeeping, like
events. What was missing is only the **run-end** half: a final snapshot catching whatever the last
stage produced (including the stage that failed and ended the run, which no boundary call covers),
and the push. That is what the persist stage owns. This follows
`docs/VISION.md` — *"a minimal core, with all behavior plugin-delivered and template-composed"* —
and makes the behaviour visible and reorderable in the template.

**Release and persist are separate stages, deliberately.** Release runs inside the exit trap and
must stay fast: a hang there turns Ctrl-C into a lockup. Persist is network I/O and can hang on
auth or a dead remote. Separate stages with separate `timeout_s`, persist last, so a bad network
can never delay an abort — and a failed push degrades to "state is local only", which is
today's behaviour and therefore a proven fallback.

**Always-run is what makes this trustworthy.** The run-end snapshot had no call site at all, and
the push existed only inside a CI workflow's `run:` block. A snapshot that happens only where someone remembered
to wire it is the failure #1878 already found once — *"the snapshot was never called."*
Declaring it in the template makes "on every exit path" a property of the flow rather than a
line number a future edit can silently drop.

**Persist redacts before it writes.** All persisted text passes
`core/redaction/apply_scope_redaction`. A stage that writes model-adjacent content outside the
chokepoint is a bug (CLAUDE.md), and this stage pushes to a remote.

**Gate verdicts are excluded from the store.** ADR-050's *"always re-evaluated fresh"* rule is
unchanged. It exists because reuse produced **observed** false greens, and a durable cross-run
store makes that leak easier, not harder.

### 4. One issue, one run at a time

Sharing a worktree removes the isolation that made concurrent same-issue runs survivable. Today
the worst case is #1688's *"two competing PRs"* — cosmetic. With one tree, two runs mutate one
`.git/index`: **silent corruption**. #1664 shows the scenario is routine — two runs 18 minutes
apart, one local and one from the daemon.

**A run acquires an exclusive lock on its issue before entering the worktree, and refuses if it
cannot.** `flock`, the pattern `core/state/` already uses throughout, keyed on
`repos/<repo>/issues/<N>/`. #1764 proposes exactly this primitive for the same race one level
down.

Liveness is decided before admission, not lazily: a lock whose holder is gone is reaped first.
`zbuild_run_is_live` (ADR-006's staleness gate) supplies the predicate, which is the half of
`zbuild_worktree_reclaim_dead` this ADR keeps.

**This is not the same as a capacity limit.** Legacy shipwright's pipeline lock
(`legacy/scripts/sw-pipeline.sh:325`) refuses on a *host-wide count* for an OOM reason, keyed on
PID, with `issue_or_goal` recorded only so the error can name the blocker. That is a different
control, and zBuild has neither today. **Issue exclusivity is a keyed mutex; host capacity is a
counted cap.** This ADR decides only the first.

### 5. A run without an issue is keyed by its goal

`--goal` runs have no issue number. `issue=0` is the sentinel today, and
`plugins/agent/intake/lib/branch-names.sh` already produces `zbuild/issue-0-<slug>` for them.
Under §1 that would place **every** goal run in one shared directory, and
`zbuild_worktree_acquire` would silently *reuse* the tree rather than refusing — reintroducing
the wrong-tree defect class of #1640.

**A goal run is keyed by a hash of its goal text**, under `goals/<goal_hash>/`, on the same
footing as an issue. `plan_context_goal_hash` already computes exactly this — sha256 of the goal
text, whitespace-insensitive so reflow does not change the key — and §6 extracts it.

The goal string becomes a path component, so it is sanitised as one. #34 covers goal
sanitisation at capture and resume boundaries; this extends that obligation to path safety.

### 6. One derivation of identity, extracted, with no subsystem attached

Repo id, issue-or-goal key and goal hash are computed **once**, in a module that owns identity
and nothing else — no cache, no GC, no LLM, no I/O.

`scripts/lib/plan-context.sh` already implements all three, at
`<repo_id>/<scope_key>/<goal_hash>`, and is the natural basis. It is **not reusable as it
stands**, and must be extracted rather than cross-called:

- **The duplication is not hypothetical — a byte-identical copy already exists.**
  `plugins/agent/plan/tests/plan-test.sh:482-484` defines `_spec_goal_hash` with the same body as
  `plan_context_goal_hash`, character for character. A test that re-implements the formula it is
  testing cannot detect a change to it.
- `scope_key` is not a function at all — it is an inline expression at
  `plugins/agent/plan/plugin.sh:500`, whose input is computed inline five lines earlier and whose
  value is then threaded through eleven call sites in that one file.
- The names claim a scope they do not have: `plan_context_repo_id` identifies a *repository*.
- `plan-context.sh:33` sources `llm-agent.sh`, so reusing a sha256 pulls in LLM machinery.

KEEPERS §I already records the underlying problem — *"Multiple repo-hash schemes — unify on one"*
(`docs/KEEPERS.md:184`). Reading the four sites shows the problem is **not** four copies of one
formula. It is **two different things derived from one input**, one of them three times with three
different parsers:

| site | derives | how |
|---|---|---|
| `scripts/lib/plan-context.sh:42` | a **hash id** | sha256 of the normalised URL — credentials stripped, `.git` trimmed, lowercased, toplevel-path fallback |
| `scripts/lib/release-tarball.sh:194` | an **`owner/repo` slug** | `${slug#*github.com[:/]}` after trimming `.git`, with a shape check |
| `plugins/agent/design/plugin.sh:142` | an **`owner/repo` slug** | a `case` on two literal prefixes (`git@github.com:`, `https://github.com/`); anything else returns empty |
| `scripts/lib/doc-publish.sh:35` | a **remote URL**, not an identity | `${origin%.git}.wiki.git` |

This sharpens the decision rather than weakening it. §6 and #141 propose **one derivation with two
renderings** — a hash for flat keys, `{owner}/{repo}` for directories. The table shows the slug
rendering **already exists and is already duplicated**, with the two copies disagreeing about which
remote forms they accept: one handles any host with `github.com` in it, the other only two exact
prefixes. A repository reachable by a form one parser accepts and the other does not gets a release
tarball and no design blob URL, silently.

`doc-publish.sh` is listed for completeness and is **not** in scope: it constructs a wiki remote,
which is a different job that happens to start from the same string.

**The test for whether the extraction succeeded:** the module must be sourceable by
`scripts/lib/cleanup.sh` and `scripts/lib/worktree.sh` without pulling in anything from the plan
stage. Today that is impossible. If it remains awkward afterwards, the boundary is in the wrong
place.

Precedent is one day old: #1809 extracted `core/plugin-registry/output-paths.sh` from
`scan_plugin_outputs` rather than cross-calling, on the grounds that *"a boundary whose two
halves disagree about where a declared output lives is not a boundary."* **A layout whose
consumers disagree about how a run is keyed is not a layout.**

## Consequences

**Positive**

- The collision behind #1658 and #1869 cannot occur; `zbuild_worktree_reclaim_dead`'s sequential
  case becomes unreachable rather than handled.
- Prior work is on disk beside the run that needs it, and on a remote rather than one laptop.
- One base directory: one `.gitignore` entry, one place to look for an issue's work.
- `--goal` runs gain an identity they have never had.
- One hash derivation and two divergent `owner/repo` slug parsers collapse to one derivation with two renderings; KEEPERS §I is dischargeable.
- `legacy/` is materialised once per issue instead of once per run (#1802).

**Negative / costs**

- **Concurrent runs of one issue become impossible.** Measured as unused (35/35 sequential), but
  it is a capability being removed, and the daemon plus a local operator is exactly how #1664
  produced two at once. §4 converts that from silent corruption into an explicit refusal, which
  is the trade being made.
- **~17 call sites assume the flat shape, and six fail silently** — worst is
  `_cleanup_is_active_run`, whose glob would match nothing and report *no run is live*,
  un-gating three destructive scanners against running jobs.
- **Origin starts accumulating state branches.** Today it has zero, so *"state branches have no
  pruner"* (#1632) costs nothing. After §3 it is a branch per issue per machine, forever. #1632
  must land before or with the persist stage — #749 reached 1,261 directories and ~13GB before
  anyone noticed the equivalent locally.
- ADR-035's *"shared dirs that cannot be torn down with a single run, accumulating cruft"* is a
  real objection to a per-issue tree, and is answered by retention rather than refuted.
- A nested run now writes into the parent's **durable** issue directory, so #1214 and #1127's
  fencing must widen before the layout moves, not after.

## Implementation Notes (#141, and the five-phase build)

**Prerequisite: #1831 lands first, before Phase 1.** §3 gives release and persist the
**always-run** stage attribute, and #1831 is where that attribute is built — it is the same
mechanism the template-driven `clean_*` stages need, and it must exist once, not twice. #1831 is
otherwise independent of this ADR: it changes *how* cleanup is invoked, not *where* things live,
and Phase 5 touches its scanners only as path constants. Building the attribute in #1831 also
gives it a **second real consumer** here, which is what makes it a mechanism rather than a
one-off.

Phases, each independently landable, ordered so none depends on a later one:

1. **Extract the identity module** (§6). Provable alone: the sourceability test above.
2. **Key hierarchy + the three stages** (§1, §3). Re-scopes #142 to nest rather than compete.
3. **Per-issue lock** (§4), *before* anything shares a tree.
4. **`--goal` identity** (§5).
5. **Move the layout and fix the ~17 call sites.**

Verification for the silent sites is **observation, not assertion** — with a run live:

```bash
zbuild cleanup --state-dirs   # must report the live run as skipped, not prune it
zbuild cleanup --worktrees    # must list candidates, not silently report none
```

Ablate with `git checkout <merge-base> -- <file>`, never `git stash push`: once a change is
committed, stash ablates nothing and reports a false pass.

**Build Mode: By-hand** — ADR-057 gate 3b. The layout change edits
`.github/workflows/zbuild-pipeline.yml`, which the App token cannot push (#1780); #1761 lost
2h50m to exactly that.

## References

- `scripts/lib/plan-context.sh` — the existing `<repo_id>/<scope_key>/<goal_hash>` scheme (§6)
- `core/state/artifact-persist.sh` — the store, missing its push (§3)
- `core/pipeline/runner.sh:146,1813` — the two engine call sites that become plugins (§3)
- `scripts/lib/worktree.sh` — `zbuild_worktree_reclaim_dead`, kept for liveness only (§2, §4)
- `docs/KEEPERS.md:184` — "Multiple repo-hash schemes — unify on one"
- #887, #888 (what run-keying was chosen for), #1658, #1869 (what it cost), #1640 (wrong-tree
  defect class), #1664, #1688, #1764 (the concurrency this creates), #1921 (zero on origin),
  #1878 (the snapshot was never called), #1632 (retention), #1802, #34, #141, #142
