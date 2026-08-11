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

`teardown_run` reads `pipeline-state.json`, collects every stage with `status=complete` or `status=failed`, resolves each stage's plugin directory, and calls `plugin_hook_call cleanup <stage> <state_file> release` for each.

- `ZBUILD_HOOK_ABSENT` (rc=3) — plugin has no `cleanup` hook; treated as a supported no-op, no error emitted.
- Any other non-zero rc — emits `stage.cleanup.release.failed` event and continues; teardown still returns 0.
- The teardown stage itself is skipped to prevent circular dispatch.

## Scope contract (ADR-054 §7)

| Scope | Dispatcher | Effect |
|-------|-----------|--------|
| `release` | teardown plugin (this plugin) | Kill spawned process groups; leave artifacts intact |
| `purge` | Future operator CLI subcommand | Delete staging directories and temporary state |

`teardown_run` **never** dispatches `scope=purge`. Purge is reserved for an operator-invoked CLI subcommand (#E5).

## Events emitted

| Event | When |
|-------|------|
| `teardown.start` | At the start of `teardown_run` |
| `teardown.complete` | After all stages have been processed |
| `stage.cleanup.release.failed` | When a plugin's `cleanup` hook returns non-zero |

## Template wiring

Dispatched as the sole stage in `config/templates/clean.yaml`, which the runner activates at every pipeline exit path.
