# Architecture

The engine is intentionally small; all behavior is plugin-delivered. The authoritative source is [`docs/ARCHITECTURE.md`](https://github.com/ezigus/zBuild/blob/main/docs/ARCHITECTURE.md) — this page is an orientation.

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

- **CLI** parses commands and hands off to the runner.
- **Core** provides the primitives every plugin relies on — the [[mechanics/event-bus]], the [[mechanics/redaction-chokepoint]], the [[mechanics/router-models-as-data|router]], [[mechanics/state-and-resume|state]], scope, and locks.
- **Plugins** deliver stages; templates compose them over the [[Mechanics]] operators.

## Data flow (a run)
`zbuild pipeline start --issue 42` → load template → for each stage: resolve plugin (role-then-id) → assemble prompt (through redaction) → run → emit events + write artifacts → gate verdict advances/loops/routes-back → … → `pr`.

## Where things live
- `core/` — engine primitives. `plugins/` — one dir per plugin. `config/` — `models.json`, `event-schema.json`, `templates/`. `scripts/` — CLI + libs. `docs/` — VISION, ARCHITECTURE, KEEPERS, ADRs. `legacy/` — frozen upstream reference (do not run).

## Decisions (ADRs)
Formal decisions live in [`docs/adr/`](https://github.com/ezigus/zBuild/tree/main/docs/adr). User-relevant: ADR-001 (plugin contract), ADR-003 (models as data), ADR-004 (redaction), ADR-005 (claim coordinator), ADR-006 (resume), ADR-009 (platforms), ADR-016/032 (per-repo overrides), ADR-023 (install isolation), ADR-030 (scope governance), ADR-040/045 (gates, route-back), ADR-047 (stage-agnostic mechanics).
