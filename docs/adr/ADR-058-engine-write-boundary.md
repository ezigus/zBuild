# ADR-058: The engine defines where a stage may write

**Status:** Accepted (2026-08-22)
**Date:** 2026-08-22
**Issue:** #1918
**Related:** ADR-052 (engine-owned run worktree), ADR-011 (pluggable backends — the cache and memory stores), ADR-024 (subprocess env isolation), ADR-004 (redaction chokepoint), ADR-054 §3 (the dispatch identity seam this reuses), ADR-056 (cleanup-only lifecycle — why nothing here deletes)

## Context

#1809 makes a stage's declared outputs a **write boundary**: writing outside them is a violation. That boundary cannot be enforced until the engine first says which areas a stage is *allowed* to write into — and one of them did not exist.

A stage needing a throwaway working file took one from the system temp directory, because nobody had given it anywhere better. Roughly twenty sites did this, including the largest single writer in the pipeline — `plugins/tool/test/plugin.sh`, whose rsync'd staging tree is a full copy of the repository under test. None of it was inside anything the engine owned, so:

- **Nothing could be enforced.** "Did this stage write outside its declared outputs?" has no answer when a legitimate scratch write can land anywhere on the filesystem.
- **Nothing could be reclaimed.** An operator cleaning up after a failed run had no directory to name.
- **The model wrote wherever it liked.** `scripts/lib/env-scrub.sh` wildcard-unsets every `ZBUILD_*` before each model spawn — with an unset-until-gone loop added by #1873 *specifically* to defeat `local -x` layering at the dispatch seam. `TMPDIR` is explicitly preserved. So no `ZBUILD_*` variable can tell a spawned model anything, and `TMPDIR` is the only channel that reaches it at all.

A fourth thing was true and made the fix look impossible: `scripts/lib/worktree.sh` carried a note claiming CI pins `ZBUILD_STATE_DIR` to `${{ github.workspace }}/state`, i.e. inside the repository under change. #1638 moved it to `$RUNNER_TEMP/zbuild-state` and the note was never updated. A scratch dir inside the job folder reads as "scratch inside the repo you are editing" only while that note is believed.

## Decision

### 1. Four areas, and only four

A stage may write into:

| Area | Env var | Purpose | Lifetime |
|---|---|---|---|
| the job's state dir | `ZBUILD_STATE_DIR` | state, artifacts, events, stage I/O | the run, then kept as evidence |
| the run's worktree | `ZBUILD_REPO_ROOT` (ADR-052) | the code under change | the run |
| **a per-stage scratch dir** | `ZBUILD_STAGE_SCRATCH` | throwaway working files | the run; reused across cycle iterations |
| the cache and memory stores | ADR-011 | the two stores that outlive a run | across runs |

Three already existed. The third is what this ADR adds.

### 2. The per-stage scratch dir

```
ZBUILD_STAGE_SCRATCH = ${ZBUILD_SCRATCH_ROOT:-$ZBUILD_STATE_DIR}/scratch/<stage>[-<map_element>]
```

Resolved by `core/pipeline/stage-scratch.sh`; `mkdir -p` + `chmod 700`, copied from the per-run orch scratch precedent in `core/pipeline/strategies/common.sh`. 0700 because scratch holds raw prompts and raw model output on a shared CI runner.

**One dir per stage, reused across cycle iterations.** Build re-runs up to eight times; the key carries no iteration counter, so iteration 8 finds iteration 7's working files where it left them. That is the property that rules out `$TMPDIR` as a base — see §4.

**Keyed on `<stage>[-<map_element>]`, not the stage alone.** Under `map:` all six lens members receive the same stage name concurrently (ADR-047 §2), so a stage-only key would hand six parallel members one directory.

**The key is sanitised to a single path component.** Everything outside `[A-Za-z0-9_-]` collapses to `_` — `.` included, so `..` cannot survive and no key can climb out of the job folder.

**Fail-open.** An unnameable stage or an uncreatable directory leaves the variables unset and every consumer on the `${TMPDIR:-/tmp}` fallback it has today. A stage is never refused dispatch because scratch was unavailable; that would turn a diagnostic convenience into a new way for a run to die.

### 3. Exported at the dispatch chokepoint, with `TMPDIR`

`plugin_hook_call` (`core/plugin-registry/lifecycle.sh`) exports three variables for exactly the span of one dispatch, all guarded on the state_file argument being an **absolute** path:

- `ZBUILD_STAGE_SCRATCH` — the new area.
- `TMPDIR` — pointed at the same directory.
- `ZBUILD_ARTIFACT_DIR` — `<state_dir>/artifacts`.

**The guard is "absolute", not "non-empty", and the difference is load-bearing.** `dirname` of a bare relative name is `.`, and by the time a stage dispatches, the runner has `cd`'d into the run's worktree (ADR-052) — so a relative state_file would put `scratch/` and `artifacts/` *inside the repository under change*. That is the exact leak this ADR exists to close, reintroduced by this ADR's own block. It cannot arise from the engine: `runner.sh` absolutizes `state_dir` "BEFORE anything derives a path from state_dir" precisely so no caller has to think about it (ADR-052, #1640). A relative or empty argument therefore means an ad-hoc caller, which is handled the same way as any other unnameable dispatch — fail-open, no exports.

**Same site and same `local -x` as the ADR-054 §3 identity block**, for the same reasons: it is the only site reaching all four dispatch arms (the `map:` arm runs a generated standalone script the runner cannot export into, and this call is that script's last line), and `local -x` restores the prior value *and* the prior export attribute on return — so stage N's scratch cannot bleed into stage N+1, and a test harness's sandboxed `ZBUILD_ARTIFACT_DIR` comes back intact.

**Setting `TMPDIR` is the load-bearing part.** It is the only channel that reaches the model (§Context). Redirecting it puts the model's own temp writes in bounds *and* relocates every `${TMPDIR:-/tmp}` consumer in the engine and the plugins — roughly twenty sites, including the test stage's staging tree — **with zero plugin edits**.

**`ZBUILD_ARTIFACT_DIR` is a definition, not a leak fix.** The seven gate plugins test for a live state file first and only fall back to temp when invoked ad-hoc, so their outputs land correctly today. Nothing in `core/` or `scripts/lib/` ever set the variable, while eleven plugins read it. What changes is that the plugin's own fallback and `scan_plugin_outputs`' `${artifact_dir}` substitution become the same directory **by construction**, instead of two independent derivations a caller can silently split.

### 4. Scratch is not under `$TMPDIR`, and the resolver may not read it

`scripts/lib/worktree.sh` already gives the reason for the worktree: on macOS `$TMPDIR` resolves into `/var/folders/...`, where entries can vanish mid-run (#1571, and the empty-state aborts #1609/#1611 chased). Scratch holds live work *across* iterations, so the same reaper hazard applies.

There is a second, sharper reason the resolver itself must never read `$TMPDIR`: the dispatch seam sets `TMPDIR` **to** the scratch dir. A resolver that read it back would nest scratch inside scratch on every re-resolution. `tests/unit/stage-scratch-test.sh` pins this statically as well as behaviourally.

### 5. CI does not upload scratch

`.github/workflows/zbuild-pipeline.yml` uploads `$ZBUILD_STATE_DIR` wholesale on `if: always()`, and scratch is now inside it. The upload excludes `scratch/**` and `**/scratch/**` for two reasons:

- **Volume** — gigabytes per run, for files nothing diagnoses from.
- **Disclosure** — scratch holds **raw, unredacted** prompts and model output. Uploading it would carry them off the machine, routing around the redaction chokepoint (ADR-004) that exists to prevent exactly that.

`artifacts/` and `stage-io/` are untouched, so CI-5's diagnostic purpose survives intact.

## Consequences

**Positive**
- #1809 can now state a write boundary that has something to be a boundary *of*.
- The model's temp writes are inside the job folder, reachable by one variable the scrub cannot remove.
- ~20 `${TMPDIR:-/tmp}` sites relocate with no plugin edits, so no plugin can drift back.
- A failed run's scratch is evidence in a known place, next to the state that explains it.

**Negative / costs**
- **The job folder grows, and nothing reclaims it.** Job folders are never reclaimed today (`scripts/lib/cleanup.sh` deletes only `pipeline-state.json{,.bak,.lock}`) and scratch makes that materially worse — the test stage alone stages a full repo copy per stage. Reclamation is **deliberately out of scope**: ADR-056/#1829 settled that automatic `cleanup(release)` frees live resources and deletes nothing, so a failed run keeps its evidence. Operator-invoked reclamation is #1920 (C11).
- The state dir must live on a filesystem with room for a full working set, not just for JSON. On CI that is `$RUNNER_TEMP`, which has it.
- A plugin that hardcodes `/tmp` rather than `${TMPDIR:-/tmp}` is unaffected and stays out of bounds. Nothing here detects that; #1809's boundary check is what will.

## Implementation Notes (#1918, Phase 0 C8)

`core/pipeline/stage-scratch.sh` is a sourced library — `stage_scratch_dir` resolves, `stage_scratch_ensure` resolves and creates. Both take `[<state_dir>] [<stage>] [<map_element>]` and fall back to the ambient dispatch identity, so a caller already inside `plugin_hook_call` can call them with no arguments.

The exports deliberately live in `core/plugin-registry/lifecycle.sh` and **not** in `core/pipeline/runner.sh`. Moving them makes the change gate-3 `By-hand` under ADR-057 *and* trips the shape floor: `config/shape-change-paths.txt` demands that any diff touching `runner.sh` also carry every `event-sequence.golden` and every `_TPL_STAGES[N]` order test.

Verification:

```bash
bash tests/unit/stage-scratch-test.sh
bash tests/integration/stage-scratch-dispatch-test.sh
bash tests/unit/ci-state-isolation-test.sh
bash tests/unit/plugin-lifecycle-event-balance-test.sh   # the ad-hoc `… ""` caller must still reach the plugin
```

This issue is itself gate 3b's worked example under ADR-057 as amended: it edits `.github/workflows/**`, which the App token cannot push (#1780), so it was built by hand.

## References

- `core/pipeline/stage-scratch.sh` — the resolver (§2)
- `core/plugin-registry/lifecycle.sh` — `plugin_hook_call`, the dispatch chokepoint (§3)
- `core/pipeline/strategies/common.sh` — `_strategy_orch_scratch_dir`, the per-run precedent §2 copies
- `scripts/lib/env-scrub.sh` — the `ZBUILD_*` scrub that makes `TMPDIR` the only channel to the model (§3)
- `scripts/lib/worktree.sh` — the `/var/folders` hazard (§4) and the stale CI note #1918 corrected
- `.github/workflows/zbuild-pipeline.yml` — the artifact upload (§5)
- #1809 (declared outputs as a write boundary), #1920 (C11, operator-invoked reclamation), #1780 (the unpushable workflow diff), #1638 (state moved outside the workspace), #1873 (the unset-until-gone scrub loop)
