# ADR-062: The engine reclaims; stages stop declaring cleanup hooks

**Status:** Accepted (2026-08-31)
**Date:** 2026-08-31
**Supersedes:** ADR-054 §7's per-stage `cleanup(scope)` dispatch, and the `plugins/tool/teardown` stage that invokes it
**Amends:** ADR-056 (the lifecycle becomes `run` only), ADR-058 §1 (`runtime/` gains the writer its definition already promised)
**Related:** ADR-059 (issue-vs-run keying — the path is the keying), ADR-011 (the two stores, which this does not reclaim), ADR-052 (engine-owned run worktree)

## Context

`cleanup(scope)` was made a per-stage hook because of one claim, stated when the teardown stage was introduced:

> `plugin.cleanup(scope)` ← **only the stage knows what it spawned**

That claim is false, and one plugin in this repository already disproves it.

**`tool/test` records what it spawned to disk, and reclaims from the record.** At dispatch it writes `test-stage.pid` and `test-stage.pgid` into `runtime/`, and its cleanup hook reads those files and calls `zbuild_pg_kill`. The stage does not need to *remember* anything: the process group is on disk, and anyone holding the path can act on it.

That is the whole mechanism, implemented once, privately, by the only plugin that needed it.

### What the other twenty-one hooks do

Nothing. Literally:

```bash
monitor_stage_cleanup() { return 0; }
```

Of 22 declared `cleanup:` hooks, **21 are `return 0`**. Six carry a comment explaining why they do not emit an event; the rest are three lines. The contract exists, is declared across 22 manifests, is dispatched by a stage plugin, and does nothing 21 times out of 22.

### The bug the hook shape guarantees

Teardown iterates stages recorded in `.stage_statuses`, and `_update_stage_status` writes that map only with `complete` or `failed` — **after a stage returns**. A stage killed mid-flight is never recorded, so its cleanup never runs.

Measured on `runner-release-exit-paths-test.sh`:

| Exit path | cleanup dispatched for |
|---|---|
| success | `intake build test` |
| stage rc≠0 | `intake build` |
| SIGINT (rc 130) | `intake build` |
| **external SIGTERM** | **`intake` only** |
| **external hard kill** | **`intake` only** |

On the last two, `build` had demonstrably started — it wrote its own marker — and its cleanup never fired. This is the failure #1748 describes: suites observed alive 15+ minutes after a run exited.

**A hook cannot fix this, because a hook needs the stage to still be alive to run it.** A record written at spawn survives the stage's death; a hook does not.

## Decision

### 1. The engine records the process group at dispatch

At the dispatch chokepoint the engine writes the spawned process group to `runs/<run_id>/runtime/stages/<stage_id>.pgid`. This is the writer [ADR-058](ADR-058-engine-write-boundary.md) §1 already promised when it defined `runtime/` as holding "PIDs, process groups, staging paths, engine markers" — the definition existed; nothing wrote to it.

`runtime/` sits under the run's area, so per [ADR-059](ADR-059-issue-vs-run-keying.md) §1 the record is reclaimable by path like everything else: a reclaimer deletes a `runs/<id>/` and the scope follows from where it sits.

### 2. Reclamation reads the record, not the status map

`release` kills every recorded process group and drops locks. It **deletes nothing** — ADR-054 §7's rule is unchanged and load-bearing: a failed run keeps its complete evidence.

Because the record is written at spawn rather than at completion, a stage killed mid-flight is reclaimable. That is the entire point, and it is what the status-map approach could not do.

### 3. Declared no-op hooks leave the contract; the last real one follows

**Now.** The 21 `cleanup:` hooks whose entire body is `return 0` are deleted, along with their manifest declarations. Nothing observable changes, which is the point: they were contract surface with no behaviour behind them, and they made `cleanup` look like a live per-stage responsibility when 21 times out of 22 it was not.

**`tool/test` keeps its hook for now, and the reason is worth stating rather than hiding.** Its `release` arm is genuinely superseded by §2 — the engine now kills the process group it used to kill. Its `purge` arm is not: it deletes the staging tree, which is a **path** operation, not a process one, and belongs with `zbuild clean --purge`. Retiring the hook before that move would delete the deletion.

**Then.** Once `purge`'s staging-tree deletion is a path operation in `zbuild clean`, the last `cleanup:` declaration, the hook name in the plugin contract, `plugins/tool/teardown`'s per-stage dispatch loop, and the `plugin.cleanup.*` event pair retire together, and the lifecycle becomes `run` only.

Splitting it this way keeps §4's ordering intact at every step: nothing is removed before the thing that replaces it exists.

### 4. Ordering is not negotiable

The engine must reclaim **correctly and demonstrably** before a single hook is removed. Retiring first would delete `tool/test`'s working implementation and leave nothing in its place — the one hook that actually frees something.

Concretely: §1 and §2 land and are proven equivalent to today's behaviour *including* the SIGTERM/hard-kill cases that currently free nothing; only then does §3 delete anything.

## Consequences

- **`tool/test`'s private mechanism becomes the engine's.** Its `test-stage.pgid` write and `_test_kill_staging_pg` reader move to the dispatch seam and apply to every stage.
- **21 no-op hooks and their manifest declarations disappear.** Nothing observable changes for them, which is the point: they were contract surface with no behaviour behind it.
- **The staging-tree deletion in `test_cleanup(purge)` is not a process concern** and moves with `zbuild clean --purge` as a path operation.
- **A SIGKILLed runner still leaves orphans.** Dispatch runs from an `EXIT` trap and `SIGKILL` cannot be trapped. Persisting the pgid is what makes an *operator-run* sweep possible afterwards — an in-process trap never could, under either design.
- **Reclamation stays bounded.** `ZBUILD_RELEASE_TIMEOUT` (default 30s) still applies; an unbounded reclaim turns Ctrl-C into a hang, which is the failure the bound exists for.
- **Writes outside the data root remain unreclaimable** (#2004). Path-based reclamation cannot reach `${TMPDIR}`; that is fixed by putting writes in bounds, not here.

## Implementation Notes

The pattern to hoist, from `plugins/tool/test/plugin.sh`:

```bash
_runtime_dir="$(_test_runtime_dir "$(dirname "$(dirname "$output_json")")")"
printf '%s' "$tmp" > "$_runtime_dir/test-staging-path"
# writes test-stage.pid and test-stage.pgid, then:
trap "_test_kill_staging_pg '$_pid_file' '$_pgid_file'" RETURN
```

and its reader, which is already generic:

```bash
_test_kill_staging_pg() {
    _pgid="$(cat "$_gf")" ; zbuild_pg_kill "$_pgid"
}
```

`zbuild_pg_kill` and `_zbuild_pg_term_then_kill` (`scripts/lib/proc-group.sh`) are the existing kill mechanism and need no change — only a caller that reads from disk rather than from a shell variable. `zbuild_pg_resolve` already derives a child's pgid at spawn time; today the result lives in a shell variable and dies with the process (`core/router/route.sh`, `core/pipeline/runner.sh:2159-2194`).

Verification:

```bash
bash tests/integration/runner-release-exit-paths-test.sh   # SPEC-4/5 must free build, not just intake
bash tests/unit/core-pipeline-lifecycle-test.sh
npm run test:unit && npm test && npm run lint
```

The discriminating case is the external hard kill: today it frees `intake` only. If it still frees `intake` only after §1 and §2, the record is not being written at spawn and nothing else in this ADR works.
