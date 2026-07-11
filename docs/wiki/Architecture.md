# Architecture

zBuild is a pipeline engine: you give it a GitHub issue, and it works through a sequence of steps — planning, designing, coding, testing, reviewing — and opens a pull request. The engine itself is intentionally small; every step is handled by a **plugin** (a self-contained module) that the engine loads at startup. This page explains how those pieces fit together.

The authoritative deep-dive is [`docs/ARCHITECTURE.md`](https://github.com/ezigus/zBuild/blob/main/docs/ARCHITECTURE.md). This page is an orientation.

## System view

```
CLI (scripts/zbuild)
      │
      ▼
core engine ── event bus (SQLite + JSONL)
      │        redaction chokepoint
      │        router (models as data)
      │        state / resume
      ▼
plugins  (agent · tool · recovery · orchestrator · claim-coordinator · daemon)
```

- **CLI** — the `zbuild` command you type. It parses your request and hands it to the runner.
- **Core engine** — a small set of shared services every plugin depends on (event bus, redaction, model router, state storage, scope enforcement, and locks). It does not implement any pipeline logic itself.
- **Plugins** — where all the work happens. Each pipeline stage is a plugin. Templates compose plugins into a run.

## Where things live

| Directory | What's in it |
|---|---|
| `core/` | Engine primitives (event bus, redaction, router, state, locks). |
| `plugins/` | One subdirectory per plugin. |
| `config/` | `models.json`, `event-schema.json`, `templates/`. |
| `scripts/` | The `zbuild` CLI and shared bash libraries. |
| `docs/` | VISION, ARCHITECTURE, KEEPERS, ADRs. |
| `legacy/` | Frozen upstream reference — do not run. |

## How a run flows

```
zbuild pipeline start --issue 42
  → load template
  → for each stage:
      resolve plugin (role-then-id)
      → assemble prompt (through redaction)
      → run plugin
      → emit events + write artifacts
      → gate verdict: advance / loop / route-back
  → pr
```

---

## Advanced — engine internals and ADR references (newcomers can skip)

This section is for contributors and operators who need to understand or modify the engine. It assumes familiarity with the plugin contract and pipeline mechanics.

### Core services

- **[[mechanics/event-bus]]** — all engine activity is recorded as events in a SQLite-backed JSONL file. Plugins emit events; the engine reacts to them. Every `pipeline.*`, `stage.*`, `plugin.*`, `model.*`, `cycle.*`, and `redaction.*` event is here.
- **[[mechanics/redaction-chokepoint]]** — all text sent to a model passes through a single chokepoint that applies scope redaction (ADR-004). A plugin that calls a model directly is a contract violation.
- **[[mechanics/router-models-as-data|router]]** — model selection is data, not code. The router reads `config/models.json` and selects a model by tier (T0–T4). Code never references model names. (ADR-003.)
- **[[mechanics/state-and-resume]]** — run state is written atomically per stage. A `latest` symlink always points at the newest run. Interrupted runs are resumable from the last completed stage. (ADR-006.)
- **Scope + locks** — scope governance (ADR-030) controls which files a plugin may touch. The locked-state guard (SPEC-G) prevents two live runs from overwriting each other's state.

### Plugin resolution

Templates bind stages to **roles**, not plugin ids. At resolution time the engine finds the plugin whose `provides.role` matches; if none matches it falls back to the plugin `id`. This role-then-id protocol (ADR-042/047) means you can swap implementations without editing the template.

### Gates and convergence

Mechanical [[mechanics/gates]] produce pass/fail verdicts. Cycles are bounded and converge via [[mechanics/convergence]] (`exit_when`, `on_max`). The [[mechanics/aggregators|gate-aggregator]] is the sole merge-blocker. Review lenses are advisory. The [[mechanics/route_back]] primitive (rc=11, ADR-045) lets a cycle send work back to an earlier stage.

### Formal decisions

All architectural decisions are recorded in [`docs/adr/`](https://github.com/ezigus/zBuild/tree/main/docs/adr).

User-relevant ADRs:

| ADR | Topic |
|---|---|
| ADR-001 | Plugin contract |
| ADR-003 | Models as data |
| ADR-004 | Redaction chokepoint |
| ADR-005 | Claim coordinator |
| ADR-006 | Resume / atomic state |
| ADR-009 | Platform support |
| ADR-016, ADR-032 | Per-repo overrides |
| ADR-023 | Install isolation |
| ADR-030 | Scope governance |
| ADR-040, ADR-045 | Gates and route-back |
| ADR-047 | Stage-agnostic mechanics |
