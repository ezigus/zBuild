# write boundary

The **write boundary** is the engine's answer to a plain question: when a stage runs, where is it allowed to put files? Five places, and the engine hands each one to the stage by name. You'd look here when a stage is writing somewhere surprising, when you want to know what a failed run left behind and where, or when you're writing a plugin that needs a temporary file.

## The five areas

| Area | How a stage finds it | What belongs there |
|---|---|---|
| The job's state dir | `$ZBUILD_STATE_DIR` | state, artifacts, events, stage I/O — the run's records |
| The run's worktree | `$ZBUILD_REPO_ROOT` (ADR-052) | the code under change |
| The per-stage scratch dir | `$ZBUILD_STAGE_SCRATCH`, and `$TMPDIR` points at it too | throwaway working files |
| Live run bookkeeping | `<state_dir>/runtime/` | PIDs, process groups, staging paths, engine markers — things a later stage or the engine must read back |
| The cache and memory stores | ADR-011 backends | the two stores that outlive a run |

Anywhere else is out of bounds. That is what makes a declared output enforceable: a stage that writes outside its declared outputs is doing something the engine can name, rather than something indistinguishable from a legitimate temp file.

## The per-stage scratch dir

```
$ZBUILD_STATE_DIR/scratch/<stage>[-<map_element>]
```

Created 0700 at dispatch, one per stage. Three properties matter:

- **It is reused across cycle iterations.** The build stage re-runs up to eight times; the key carries no iteration counter, so iteration 8 finds iteration 7's files where it left them.
- **It is keyed on the map element as well as the stage.** Under `map:`, all six review lenses receive the same stage name at the same time, so a stage-only key would hand six concurrent members one directory.
- **It is never under the system `$TMPDIR`.** On macOS that resolves into `/var/folders/...`, where entries can vanish mid-run (#1571). Scratch holds live work between iterations, so it must not live where a reaper may collect it.

## `runtime/` vs scratch — which one do I want?

Both are engine-defined, both are machine-specific, and neither is a stage output. The difference is who reads the file back:

- **Scratch** is *yours*, and it is per-stage. Use it for working files only your own stage cares about. It is keyed on the stage (and the map element, if any), so nothing outside your stage can reliably find it.
- **`runtime/`** is *shared within the run*. Use it when the engine, or a later stage in a different process, has to read what you wrote — a process group to reap, a staging path to reclaim, a marker. It has one location per run and needs no key.

A rule of thumb: if the answer to "who reads this?" is anything other than "me, later in this same stage", it belongs in `runtime/`.

Nothing clears a `runtime/` file mid-run, so a recorded PID or process group can outlive the thing it names. Verify it is still alive before acting on it.

## `TMPDIR` is the channel to the model

Before every model spawn, `scripts/lib/env-scrub.sh` unsets every `ZBUILD_*` variable — the subprocess is meant to look like a fresh user shell (ADR-024). `TMPDIR` is deliberately preserved, which makes it the *only* variable that reaches a spawned model at all.

So the engine points `TMPDIR` at the scratch dir. Two things follow with no plugin edits at all: the model's own temporary writes land inside the job folder, and every `${TMPDIR:-/tmp}` call site in the engine and the plugins — about twenty, including the test stage's staging copy of the repository — relocates with it.

## Writing a plugin that needs a temp file

Keep using `${TMPDIR:-/tmp}`. That is the point of the redirect — it is already in bounds:

```bash
scratch="$(mktemp -d "${TMPDIR:-/tmp}/my-plugin.XXXXXX")"
```

Use `$ZBUILD_STAGE_SCRATCH` directly only when you need a **stable** path across cycle iterations — a cache of work the next iteration should find rather than redo:

```bash
cache="${ZBUILD_STAGE_SCRATCH:-${TMPDIR:-/tmp}}/parsed-manifests"
```

Always keep the fallback. The engine sets these variables only when the stage was dispatched with a state file; an ad-hoc invocation gets neither.

Hardcoded `/tmp` is the one thing that does not work — it is out of bounds and nothing relocates it.

## What CI does and does not keep

The pipeline workflow uploads the whole state dir as an artifact, on success and failure alike, so a failed run is debuggable from the run page. It **excludes scratch**, for two reasons: the volume is gigabytes per run, and scratch holds raw, unredacted prompts and model output. Uploading it would carry that off the machine, around the redaction chokepoint that exists to prevent it.

## Nothing here is deleted automatically

A run's scratch survives the run. That is deliberate: automatic cleanup frees live resources and deletes nothing (ADR-056), so a failed run keeps its evidence. Reclaiming job folders is operator-invoked, not part of the stage lifecycle.

## Related

- ADR-058 — the formal decision defining the boundary
- ADR-052 — the engine-owned run worktree, the second area
- [[mechanics/redaction-chokepoint]] — why raw scratch content never leaves the machine
- [[mechanics/scope-governance]] — the *read/write scope* of the code under change, which is a different question from this one
- [[mechanics/state-and-resume]] — what lives in the job's state dir
