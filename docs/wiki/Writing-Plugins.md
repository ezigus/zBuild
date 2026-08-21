# Writing Plugins

In zBuild, a **plugin** is the unit of behavior — every stage in a pipeline (planning, building, reviewing, and so on) is delivered by a plugin. If you want to add a new stage, change how an existing one works, or integrate an external tool, you write a plugin.

A plugin is a directory under `plugins/<kind>/<name>/` containing two files: a `manifest.yaml` that describes what the plugin does, and a `plugin.sh` that implements it.

## Before you write one

Check what already exists:

```bash
zbuild plugin list
```

You may find a plugin that already does what you need, or one close enough to copy as a starting point. The full per-plugin reference is under [[Plugins]].

## The five kinds of plugin

Choose the kind that matches what your plugin does:

| Kind | What it does |
|---|---|
| `agent` | LLM-driven work (writing code, drafting a plan). |
| `tool` | Non-LLM integration — git, GitHub, gates, caches. |
| `orchestrator` | Runs other plugins and aggregates their results. |
| `claim-coordinator` | Coordinates work across machines (lock / release / list). |
| `daemon` | Long-running background process. |

All kinds may also implement optional `init`, `finalize`, and `cleanup` hooks.

## A minimal manifest

```yaml
id: my-linter          # globally unique kebab-case id
name: My Linter
kind: tool
version: 0.1.0
description: |
  Runs the project linter and emits a pass/fail verdict.
hooks:
  run: run_my_linter   # name of the bash function in plugin.sh
requires:
  core: [event-bus, state]
provides:
  role: lint           # templates bind to role names, not ids
outputs:
  - id: lint-report
    path: ${artifact_dir}/lint-report.json
    type: json
    required: true
    primary: true
```

Save this as `plugins/tool/my-linter/manifest.yaml`. Then implement `run_my_linter` in `plugins/tool/my-linter/plugin.sh`.

## Two worked examples

- **[[plugins/security-lens]]** — an `agent` kind plugin: shows the full manifest, how to write the `run` hook, and how to validate LLM output using the envelope mechanism.
- **[[plugins/claim-coordinator-github-labels]]** — a `claim-coordinator` kind plugin: shows all four required hooks (`claim`, `release`, `heartbeat`, `list_claims`).

## Three rules every plugin must follow

1. **Agent plugins never call a model directly.** All text sent to a model must go through the [[mechanics/redaction-chokepoint]]. A plugin that bypasses this is a bug.
2. **New event names must be registered.** If your plugin emits a new event, add it to `config/event-schema.json` first. See [[mechanics/event-bus]].
3. **The `id` must be globally unique.** Templates bind to the plugin's `role`, not its `id`, but duplicate ids will cause a startup error.

---

## Advanced — full manifest schema and contract (newcomers can skip)

This section documents every manifest field and the complete plugin contract. You need it only when building a plugin for production use or reviewing ADR compliance.

### Complete manifest shape

```yaml
id: <kebab-case-unique>
name: <human-readable>
kind: agent | tool | orchestrator | claim-coordinator | daemon
version: <semver>
description: | <one paragraph>
hooks:      { init: <fn>, run: <fn>, finalize: <fn>, cleanup: <fn> }
requires:   { core: [redaction, event-bus, state, ...], plugins: [...] }
provides:   { role: <role-id>, artifact_type: <type>, schema_version: <int>, alias: <opt> }
config:     { <key>: <default> }
inputs:     [ { id, type, source: stage:<s>|role:<r>, required } ]
outputs:    [ { id, path: ${artifact_dir}/<file>, type, required, primary } ]
state:      { persisted: [...], reconstructed: [...] }
```

### Role-then-id resolution

Templates bind to `role`, not `id`. At stage resolution time the engine finds the plugin whose `provides.role` matches the stage name; if no role matches it falls back to the `id`. This is the role-then-id protocol from ADR-042/047.

### `required: true` on inputs

An input marked `required: true` with `source: stage:<s>` means the named stage must have run and produced that output before this plugin starts. The lint-contract enforces this at pipeline preflight — if the producer stage is not wired in the template, the run will refuse to start. This is intentional: wire the producer or mark the input `required: false`.

### Discovery

Manifests are globbed at startup from `plugins/`. `zbuild plugin list` shows everything registered and whether it passed manifest validation.

### Authoritative contract

The full plugin contract is ADR-001. The redaction requirement is ADR-004.
