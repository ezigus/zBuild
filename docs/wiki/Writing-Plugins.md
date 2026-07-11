# Writing Plugins

All behavior in zBuild is plugin-delivered. A plugin is a directory `plugins/<kind>/<name>/` with a `manifest.yaml` and a `plugin.sh` implementing its hooks. The contract is ADR-001.

## Kinds
| Kind | Required hook(s) | Purpose |
|---|---|---|
| `agent` | `run` | LLM-driven, redaction-governed work. |
| `tool` | `run` | Non-LLM integration (git, gh, gates, caches). |
| `recovery` | `classify`, `act` | Error handling (retry/backtrack/escalate/abort). |
| `orchestrator` | `run` | Runs sub-plugins and aggregates. |
| `claim-coordinator` | `claim`, `release`, `heartbeat`, `list_claims` | Cross-machine claim mechanism. |
| `daemon` | `tick` | Long-running background process. |

All kinds may implement optional `init` / `finalize` / `cleanup`.

## Manifest (shape)
```yaml
id: <kebab-case-unique>
name: <human-readable>
kind: agent | tool | recovery | orchestrator | claim-coordinator | daemon
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

## Key rules
- **`id` is globally unique**; `role` is what templates bind to (role-then-id, ADR-042/047).
- **Agents never call a model directly** — all model-bound text goes through the [[mechanics/redaction-chokepoint]] (ADR-004).
- New emitted events must be added to `config/event-schema.json` (see [[mechanics/event-bus]]).
- Discovery: manifests are globbed at startup; `zbuild plugin list` shows what's registered.

## Worked example
See **[[plugins/security-lens]]** (an `agent` lens: manifest + hooks + envelope-validated LLM output) and **[[plugins/claim-coordinator-github-labels]]** (a `claim-coordinator`). The full per-plugin reference is under [[Plugins]].
