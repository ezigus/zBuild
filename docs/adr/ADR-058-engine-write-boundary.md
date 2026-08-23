# ADR-058: The engine defines where a stage may write

**Status:** Accepted (2026-08-22)
**Date:** 2026-08-22
**Issue:** #1918
**Amended:** 2026-08-23 (#1809) — a fifth area, `runtime/`, for live run bookkeeping
**Amended:** 2026-08-23 (#1920) — the job folder is reclaimable; §1's "kept as evidence" gains a retention clock
**Related:** ADR-052 (engine-owned run worktree), ADR-011 (pluggable backends — the cache and memory stores), ADR-024 (subprocess env isolation), ADR-004 (redaction chokepoint), ADR-054 §3 (the dispatch identity seam this reuses), ADR-054 §7 (release/purge — why nothing here deletes), ADR-056 (cleanup-only lifecycle)

## Context

#1809 makes a stage's declared outputs a **write boundary**: writing outside them is a violation. That boundary cannot be enforced until the engine first says which areas a stage is *allowed* to write into — and one of them did not exist.

A stage needing a throwaway working file took one from the system temp directory, because nobody had given it anywhere better. Roughly twenty sites did this, including the largest single writer in the pipeline — `plugins/tool/test/plugin.sh`, whose rsync'd staging tree is a full copy of the repository under test. None of it was inside anything the engine owned, so:

- **Nothing could be enforced.** "Did this stage write outside its declared outputs?" has no answer when a legitimate scratch write can land anywhere on the filesystem.
- **Nothing could be reclaimed.** An operator cleaning up after a failed run had no directory to name.
- **The model wrote wherever it liked.** `scripts/lib/env-scrub.sh` wildcard-unsets every `ZBUILD_*` before each model spawn — with an unset-until-gone loop added by #1873 *specifically* to defeat `local -x` layering at the dispatch seam. `TMPDIR` is explicitly preserved. So no `ZBUILD_*` variable can tell a spawned model anything, and `TMPDIR` is the only channel that reaches it at all.

A fourth thing was true and made the fix look impossible: `scripts/lib/worktree.sh` carried a note claiming CI pins `ZBUILD_STATE_DIR` to `${{ github.workspace }}/state`, i.e. inside the repository under change. #1638 moved it to `$RUNNER_TEMP/zbuild-state` and the note was never updated. A scratch dir inside the job folder reads as "scratch inside the repo you are editing" only while that note is believed.

## Decision

### 1. Five areas, and only five

A stage may write into:

| Area | Env var | Purpose | Lifetime |
|---|---|---|---|
| the job's state dir | `ZBUILD_STATE_DIR` | state, artifacts, events, stage I/O | the run, then kept as evidence for a retention window (§6) |
| the run's worktree | `ZBUILD_REPO_ROOT` (ADR-052) | the code under change | the run |
| **a per-stage scratch dir** | `ZBUILD_STAGE_SCRATCH` | throwaway working files | the run; reused across cycle iterations |
| **live run bookkeeping** | `<state_dir>/runtime/` | PIDs, process groups, staging paths, engine markers | the run |
| the cache and memory stores | ADR-011 | the two stores that outlive a run | across runs |

Three already existed. The per-stage scratch dir is what this ADR added; the
`runtime/` area was named by the 2026-08-23 amendment (§2b).

### 2b. `runtime/` — live run bookkeeping (amended 2026-08-23, #1809)

**As accepted, this ADR listed four areas and `runtime/` was not among them.**
It existed, but only as one plugin's private directory: `plugins/tool/test`
invented it in #1829 to hold `test-stage.pgid`, `test-stage.pid` and
`test-staging-path`, derived its location by hand, and no ADR named it. #1809
then needed the same kind of storage for engine-owned files — a write-boundary
marker and two violation flags — and had nothing to point at but that plugin's
convention. Naming the area is what stops the second user copying the first
user's private arrangement.

```
<state_dir>/runtime/
```

**Why not `scratch/`**, which this ADR already defines and which is superficially
the same idea (not an output, machine-specific, excluded from the CI upload and
the parity walk):

- **Run-scoped and element-agnostic.** Scratch keys on
  `<stage>[-<map_element>]`. A `map:` stage has six concurrent members and
  `core/pipeline/verdict.sh` reads a violation flag cross-process *without*
  knowing the element, so a scratch-keyed flag is unfindable for every member of
  a mapped stage. `runtime/` has one location per run and needs no key.
- **Not throwaway.** §2 defines scratch as throwaway working files reused across
  cycle iterations. A flag that resolves `disposition: broken` is not throwaway,
  and a `.pgid` that outlives its own iteration is a hazard rather than a
  convenience.

**Properties a writer may rely on.** `runtime/` is engine-owned; run-scoped;
**not on the write-boundary watch list**, so a marker written there cannot
trigger a violation by finding itself; excluded from the CI artifact upload and
from the local-vs-CI parity walk, for the same volume and machine-specificity
reasons as scratch; and reclaimed with the job folder rather than on its own
schedule.

**Consequence, deliberately accepted.** Nothing clears a `runtime/` file
mid-run. A `.pgid` written in cycle iteration 1 is still present at iteration 5
and at exit, and neither `_cycle_pre_iter_cleanup` (which deletes only
manifest-declared primary outputs) nor anything else removes it. A reader must
therefore verify liveness before acting on a recorded PID or process group —
PID reuse is real and this ADR does not prevent it.

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

### 6. Evidence has a retention window (added 2026-08-23, #1920)

§1 says the state dir is "kept as evidence". As accepted that meant *kept forever*, because no command could remove one — and the areas this ADR added are the largest thing in it. `zbuild cleanup --state-dirs` now reclaims the whole job folder, so the promise needs a number.

**Seven days, from last touch, and no second number.** #1927 established one retention across every category and two clocks to apply it on: targets keyed to an ISSUE age from that issue's close, because they are live work while it is open; everything else ages from its own last touch. A job folder takes the last-touch clock, deliberately:

- The issue clock exists for what the **next run reads back** — a work branch's unmerged code, ADR-050's state branch, the plan-context cache. Nothing reads a terminal run's job folder to start the next run of that issue.
- A job folder is read by a **human diagnosing one failure**, days at most after it happens, and by `zbuild resume` for a run that stopped mid-flight. Retention serves the first; the scanner's `interrupted` guard serves the second by refusing a resumable run outright unless `--force` is passed (ADR-018).
- Keying it to the issue would cost one `gh` call per run dir — ~190 on the machine where this was measured — and buy no safety the two guards above do not already give.

**What the reclaimer will not touch**, decided in the scanner rather than in a caller: a run whose status is `in_progress` (never, not even under `--force`); the run named by `$ZBUILD_RUN_ID`; a run inside the retention window; a resumable `interrupted` run; a run whose status is present but unrecognised; and a run whose mtime cannot be read, which fails **closed** here rather than defaulting to the epoch the way the #1927 scanners do — an epoch fallback reads as "infinitely old" and would turn a degraded filesystem into an unconditional `rm -rf`. The last four release under `--force`; the first two never do.

**The clock is the run's event log, not the folder's mtime.** A directory's mtime records the last entry added or removed from it, which is not the same thing as the run's age — and removing `pipeline-state.json` is exactly what produced the folders described below. Measured against the real store, a dir-mtime clock reported 92 job folders whose contents are six weeks old as newer than the retention window. `events.jsonl` is written while the run is alive and never touched afterwards, so it dates the run. The chain is: the state file, then `events.jsonl`, then the directory. Both the prune line and the age skip name which one decided.

**A MISSING state file is not an unknown state, and is reclaimed by default.** It is the signature of the bug this fixes: the old `--state-dirs` deleted `pipeline-state.json{,.bak,.lock}` out of a job folder it had already judged prunable and left the folder standing. 112 of the 189 folders measured for #1920 look exactly like that — `artifacts/`, `events.db`, `intake.md`, no state file above them — so putting them behind `--force` would have shipped a reclaimer that reclaimed nothing on the machine the issue was filed about. A run that died before writing its first state file lands in the same shape and is equally finished. The live case this leaves — a run still starting up — is held by the retention window, not by a status: its directory mtime is seconds old.

`runtime/` (§2b) and `scratch/` (§2) are reclaimed *with* the folder and need no schedule of their own.

## Consequences

**Positive**
- #1809 can now state a write boundary that has something to be a boundary *of*.
- The model's temp writes are inside the job folder, reachable by one variable the scrub cannot remove.
- ~20 `${TMPDIR:-/tmp}` sites relocate with no plugin edits, so no plugin can drift back.
- A failed run's scratch is evidence in a known place, next to the state that explains it.

**Negative / costs**
- **The job folder grows.** Scratch made an existing leak materially worse — the test stage alone stages a full repo copy per stage — and when this ADR was accepted nothing reclaimed a job folder at all. Reclamation was **deliberately out of scope here** and was delivered separately: #1927 for the scratch inside a folder, #1920 for the folder itself. See §6 for the retention that resulted. Nothing in the run's own lifecycle deletes: ADR-054 §7's `cleanup(release)` frees live resources and deletes nothing, so a failed run still ends owning its complete evidence. (This bullet previously cited ADR-056 for that rule; it lives in ADR-054 §7. ADR-056 deletes `init`/`finalize` and defines how an absent hook is recorded.)
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

---

## C9: Post-dispatch write-boundary enforcement (#1809)

### The sweep

After each successful `run` dispatch, `write_boundary_check` (`core/pipeline/write-boundary.sh`) runs a depth-bounded sweep of the filesystem for files written during that dispatch:

1. Before sourcing `plugin.sh`, `write_boundary_mark` touches `${state_dir}/runtime/write-boundary.marker`.
2. After the dispatch returns rc=0, `write_boundary_check` runs `find -newer marker` across the six watch locations (configured in `config/write-boundary-watch.txt`; operator-overridable via `ZBUILD_WRITE_BOUNDARY_WATCH` env or `~/.zbuild/write-boundary-watch.txt`).
3. Each candidate file is passed to `write_boundary_classify`, which returns `declared` (matches a manifest output), `allowed` (under an engine-owned root or the additive allow list), or `violation`.
4. On the first `violation`, `write_boundary_violation_recorded` touches `${state_dir}/runtime/write-boundary-violated` and emits `stage.write_boundary.violated`. `write_boundary_check` returns 1 and `plugin_hook_call` returns 1 to the dispatch boundary.

Both `write_boundary_mark` and `write_boundary_check` are guarded `[[ -z "$state_file" ]] && return 0` (and absolute-path-guarded), so ad-hoc callers with no job folder are unaffected.

### Verdict precedence

`runner_read_stage_disposition` (`core/pipeline/verdict.sh`) gains a precedence branch between the existing `_d_viol` block and the `_d_disp` block: if either `${state_dir}/runtime/write-boundary-violated` **or** `${state_dir}/runtime/artifact-contract-violated` exists, the function returns `broken` immediately, overriding any declared `disposition` (including `complete`).

**Why file-backed markers, not shell globals.** The `map:` arm runs a generated standalone script in a separate process (`core/pipeline/strategies/common.sh`). A global assigned inside that process never reaches `runner_read_stage_disposition`, which runs in the runner's own process after all map members finish. File markers are the only channel between the two processes.

**SPEC-3 fix.** `scan_plugin_outputs` already touched `${state_dir}/artifacts/` for findings and emitted `plugin.contract.violated`. The change adds a `touch ${state_dir}/runtime/artifact-contract-violated` in the same violation block. The new verdict precedence branch then catches this marker — making a missing declared output resolve to `broken` even when the stage wrote a v2 result declaring `disposition: complete`.

### The asymmetric watch/allow contract

**Watch list** uses three-tier override (env > `~/.zbuild/` > shipped default): a single override replaces the list. This lets an operator narrow the sweep in a constrained environment without fighting the engine.

**Allow list** is additive: the engine hardcodes the four owned roots in code and loads every config tier additively. No override file can remove `ZBUILD_STATE_DIR`, `ZBUILD_REPO_ROOT`, or the scratch base.

### Two golden-safety rules

1. `stage.write_boundary.violated` is **never emitted on a clean dispatch** — the only emission site is `write_boundary_violation_recorded`, which is only called when `write_boundary_classify` returns `violation`.
2. `config/event-schema.json` is the **sole shape-change-path file** in this diff. `shape-floor.sh` yields `SHAPE_FLOOR SKIP schema_append_only` because the entry is append-only.

## Implementation Notes (#1809, Phase 0 C9)

`core/pipeline/write-boundary.sh` owns the six functions. `config/write-boundary-watch.txt` and `config/write-boundary-allow.txt` ship the operator-facing defaults. `config/mechanics.yaml`'s `write-boundary.defined_in` is repointed from `core/pipeline/stage-scratch.sh` to `core/pipeline/write-boundary.sh` — the resolver now lives in the new file.

**One resolver, two consumers.** `core/plugin-registry/output-paths.sh` is extracted from `scan_plugin_outputs` and carries both halves of "where does this declared output live?" — `_registry_output_path_rows` (the manifest parser, including the `required: false` omission from #511 F2) and `_registry_resolve_output_path` (the `${state_dir}` / `${artifact_dir}` substitutions plus the bounded indirect `${VAR}` expansion). `scan_plugin_outputs` and `write_boundary_classify` both source it. The two copies were byte-equivalent when first written, so this fixes no live defect; it removes the drift hazard. A boundary whose two halves disagree about where a declared output lives is not a boundary.

**A directory containing an allowed root is not a violation.** The sweep uses `find`, which reports directories, and a directory's mtime changes when a child is created inside it. So the state dir's own parent surfaces in the sweep whenever the state dir lives under a watched root — the normal shape on Linux, where `TMPDIR` is unset and everything lands under `/tmp`. Classifying that parent as a violation halts the run on a write that landed *inside* an allowed area. The classifier therefore matches a candidate that is a strict **ancestor** of an allowed root as well as one under it. This is not a blanket pass: a file can never be an ancestor, and a stray directory holding no allowed root still classifies as a violation (`write-boundary-sweep-test.sh` SPEC-4c pins both arms). macOS hid this — its test temp sits under `$TMPDIR`, which §3 redirects to scratch mid-dispatch, so the enclosing directory is never swept. All three ubuntu CI jobs were red while every macOS job was green.

**Canonicalise with `pwd -P`, never bare `pwd`.** The classifier compares a sweep candidate against the allow roots by prefix. The roots arrive already canonicalised — the `ZBUILD_REPO_ROOT` fallback is `git rev-parse --show-toplevel`, which returns `/private/var/...` on macOS — while `find` hands back candidates on the logical `/var/...` path. Bare `pwd` preserves the logical path, so the two never match and **every in-place dispatch (`ZBUILD_NO_WORKTREE=1`) reports a false violation on the repository it is supposed to be working in**. The first stage to touch `.git` fails, and the run halts before `build`. Caught by `tests/integration/worktree-run-isolation-test.sh` SPEC-6; pinned directly by `write-boundary-sweep-test.sh` SPEC-4b. `scripts/lib/cleanup.sh:534-537` paid for the same `/private` asymmetry once already.

### Two harness defects fixed here, because C9 cannot be verified past them

Both were found by the #1809 dogfood (run `20260822155737-9554`), which spent 3h44m failing on them without ever reaching a real finding. Neither is write-boundary logic; both block any run that would exercise it.

**`_sf_is_schema_append_only` could never fire for a real append** (`scripts/lib/shape-floor.sh`). The predicate rejected on *any* removed content line. Appending an element to the END of a JSON array forces a separator comma onto the previous last element, which git reports as a removed line — so the exemption was reachable only for a mid-array insert. `tests/unit/shape-floor-test.sh` SPEC-5 used exactly that shape and passed, hiding it. C9 must append `stage.write_boundary.violated` to `config/event-schema.json` and depends on the resulting `SHAPE_FLOOR SKIP schema_append_only` (golden-safety rule 2), so the bug is on C9's critical path. The fix tolerates a removed line only when the identical text plus a trailing comma is among the added lines — the sole edit was the separator. SPEC-5b pins the end-of-array shape; SPEC-6b guards that an outright deletion is still gated.

**`tests/unit/test-stage-banner-golden-test.sh` regressed on #1918.** Its sanitizer normalised `/var/folders/…` and `/tmp/…` to `<TMP>`. §3 of this ADR points `TMPDIR` at `${state_dir}/scratch/<stage>/` for the span of a dispatch, which matches neither shape, so the mock script's absolute path leaked into the golden comparison. It passes standalone and fails inside any run — i.e. it reds the test stage of every dogfood, on every issue. The sanitizer now normalises `TEST_TEMP_DIR` itself, which is location-independent; the two path-shape rules remain as a fallback.

Verification:

```bash
bash tests/unit/write-boundary-sweep-test.sh
bash tests/integration/write-boundary-dispatch-test.sh
bash tests/unit/dispatch-rc-guard-test.sh        # SPEC-7: lifecycle.sh rc count unchanged
bash tests/unit/plugin-lifecycle-event-balance-test.sh   # ad-hoc caller guard
bash tests/unit/stage-scratch-test.sh            # SPEC-3 guard: no TMPDIR read
bash tests/integration/stage-scratch-dispatch-test.sh
bash tests/integration/artifact-contract-test.sh
bash tests/unit/shape-floor-test.sh              # SPEC-5b end-of-array append, SPEC-6b deletion still gated
bash tests/unit/test-stage-banner-golden-test.sh # passes with TMPDIR inside and outside a run
```

## References

- `core/pipeline/stage-scratch.sh` — the resolver (§2)
- `core/pipeline/write-boundary.sh` — the enforcement sweep (C9)
- `core/plugin-registry/lifecycle.sh` — `plugin_hook_call`, the dispatch chokepoint (§3, C9)
- `core/plugin-registry/output-paths.sh` — the shared declared-output resolver (C9)
- `scripts/lib/shape-floor.sh` — `_sf_is_schema_append_only`, the exemption C9's schema append depends on
- `core/pipeline/verdict.sh` — `runner_read_stage_disposition`, the verdict precedence branch (C9)
- `config/write-boundary-watch.txt` — watch locations (C9)
- `config/write-boundary-allow.txt` — allowed roots (C9)
- `core/pipeline/strategies/common.sh` — `_strategy_orch_scratch_dir`, the per-run precedent §2 copies
- `scripts/lib/env-scrub.sh` — the `ZBUILD_*` scrub that makes `TMPDIR` the only channel to the model (§3)
- `scripts/lib/worktree.sh` — the `/var/folders` hazard (§4) and the stale CI note #1918 corrected
- `.github/workflows/zbuild-pipeline.yml` — the artifact upload (§5)
- #1809 (declared outputs as a write boundary), #1920 (C11, operator-invoked reclamation), #1780 (the unpushable workflow diff), #1638 (state moved outside the workspace), #1873 (the unset-until-gone scrub loop)
