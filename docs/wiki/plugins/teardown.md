# teardown

The teardown plugin iterates over all stages that executed in the current pipeline run and dispatches `cleanup` with `scope=release` to each stage's plugin. It always returns 0 — cleanup failures are recorded as `stage.cleanup.release.failed` events, never propagated as verdict changes.

**Teardown Plugin**

- **Kind:** `tool`
- **Role:** `teardown`
- **Manifest:** `plugins/tool/teardown/manifest.yaml`

## Manifest

```yaml
id: teardown
name: Teardown Stage
kind: tool
version: 0.1.0
hooks:
  run: teardown_run
```

## Behavior

`teardown_run` reads the `stage_statuses` map in `pipeline-state.json`, collects every stage recorded as `complete` or `failed`, resolves each stage's plugin directory, and calls `plugin_hook_call cleanup <stage> <state_file> <scope>` for each.

- `ZBUILD_HOOK_ABSENT` (rc=3) — plugin has no `cleanup` hook; treated as a supported no-op, no error emitted.
- Any other non-zero rc — emits `stage.cleanup.release.failed` event and continues; teardown still returns 0.
- The teardown stage itself is skipped to prevent circular dispatch.

## Scope contract (ADR-054 §7)

| Scope | Trigger | Effect |
|-------|---------|--------|
| `release` | Automatic — the runner, on every exit path from a run | Kill spawned process groups, release locks and handles. **Deletes nothing.** |
| `purge` | Operator-invoked only, via `clean.yaml` (#E5) | Delete staging directories and persisted artifacts |

The discriminator is *can this be done tomorrow?* No → `release`. Yes → `purge`.

**No run path can select `purge`.** The runner exports `ZBUILD_TEARDOWN_SCOPE=release` for its own dispatch, which overrides any ambient value, so a `purge` in the environment cannot turn a run destructive. `teardown_run` additionally degrades an unrecognised scope to `release` — the scope that deletes nothing is always the fallback.

Consequence, by construction: **a failed run leaves all of its evidence on disk.**

## Events emitted

| Event | When |
|-------|------|
| `teardown.start` | At the start of `teardown_run` |
| `teardown.complete` | After all stages have been processed |
| `teardown.scope.invalid` | An unrecognised scope was requested; `release` used instead |
| `stage.cleanup.release.failed` | When a plugin's `cleanup` hook returns non-zero |

## Wiring

Two entry points, one code path:

- **Automatic (`release`)** — `core/pipeline/runner.sh` dispatches this plugin from its `EXIT` trap, which is the single funnel for success, non-zero rc, `SIGINT`, `SIGTERM` and timeout. It does **not** go through `clean.yaml`. Depends on #1759 for the re-armed signal traps.
- **Operator (`release` or `purge`)** — `config/templates/clean.yaml` runs this plugin as its sole stage.

A cleanup failure never changes a stage's verdict or the run's exit status; it is recorded as an event.
