# zBuild Architecture

System view, plugin contract, data flow, state model, glossary. Complements [KEEPERS.md](KEEPERS.md), which catalogs what we preserve from shipwright. This document is the new system zBuild is building.

---

## 1. System diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                              zbuild CLI                              │
│  zbuild pipeline start | zbuild plugin list | zbuild status --json  │
└────────────────────────────┬─────────────────────────────────────────┘
                             │
┌────────────────────────────▼─────────────────────────────────────────┐
│                          core/ (engine)                              │
│                                                                      │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────────────┐  │
│  │ plugin-        │  │   event-bus    │  │      redaction         │  │
│  │ registry       │◀▶│ (SQLite+JSONL) │  │   (chokepoint helper)  │  │
│  │ (manifest,     │  │                │  │                        │  │
│  │  discovery,    │  └────────────────┘  └────────────────────────┘  │
│  │  lifecycle)    │  ┌────────────────┐  ┌────────────────────────┐  │
│  └───────┬────────┘  │     state      │  │       locks            │  │
│          │           │ (atomic, flock,│  │ (admission gate,       │  │
│          │           │  resume, .bak) │  │  in-process, per-host) │  │
│          │           └────────────────┘  └────────────────────────┘  │
│          │           ┌────────────────┐                              │
│          │           │     github     │                              │
│          │           │ (label contract,│                             │
│          │           │  live comment) │                              │
│          │           └────────────────┘                              │
└──────────┼──────────────────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────────────────┐
│                            plugins/                                 │
│                                                                     │
│   kind: agent         kind: tool         kind: recovery             │
│   (LLM-driven:        (non-LLM:          (error → action:           │
│    7 audit lenses,    git, gh, CLI       retry policies,            │
│    stage handlers)    integrations)      self-heal strategies)      │
│                                                                     │
│   kind: orchestrator  kind: claim-       kind: daemon               │
│   (compound_quality   coordinator        (poll, triage, patrol,     │
│    4-phase, patrol)   (github-labels     fleet-failover)            │
│                       default,                                      │
│                       ttl-leases later)                             │
└─────────────────────────────────────────────────────────────────────┘
```

The engine is intentionally small. All behavior is plugin-delivered. The seams between engine and plugins are: the **manifest contract** (what a plugin declares), the **lifecycle hooks** (what the engine calls), and the **event bus** (what plugins emit).

---

## 2. Plugin contract

Every plugin lives in `plugins/<kind>/<name>/` and contains at minimum:

```
plugins/agent/security-lens/
├── manifest.yaml
├── plugin.sh        # implements lifecycle hooks
├── prompts/         # (for kind: agent) prompt templates
└── README.md
```

### Manifest schema (`manifest.yaml`)

```yaml
id: security-lens                 # globally unique; lowercase-kebab
name: Security Audit Lens         # human-readable
kind: agent                       # agent | tool | recovery | orchestrator | claim-coordinator | daemon
version: 0.1.0
description: |
  Detects auth, injection, secret leakage, and unsafe defaults in
  changed code. One of the 7 compound-audit lenses.

# Lifecycle entry points (function names in plugin.sh)
hooks:
  init: security_lens_init        # called once per pipeline run
  run: security_lens_run          # called by orchestrator with input artifact
  finalize: security_lens_finalize # called after all cycles complete
  cleanup: security_lens_cleanup  # called on abnormal exit (kill, abort)

# Dependencies on core subsystems
requires:
  core:
    - redaction         # I emit LLM-bound text
    - event-bus         # I emit events
    - state             # I persist findings
  plugins: []           # other plugins I depend on (cross-plugin contracts)

# Capabilities I provide (consumed by orchestrators)
provides:
  artifact_type: findings.json
  schema_version: 1

# Configuration surface (env vars, config keys)
config:
  tier_default: T3      # T0–T4 routing tier; resolved by core router
  max_findings: 50

# I/O contract (declared, not enforced — useful for compatibility checks)
inputs:
  - name: changed_files
    type: file_list
outputs:
  - name: findings
    path: ${artifact_dir}/security-findings.json
    type: findings.json
```

### Required interfaces per `kind`

| Kind | Required hook | Inputs | Output |
|---|---|---|---|
| `agent` | `run` | scope manifest, input artifact, tier | structured artifact (typed) |
| `tool` | `run` | typed args | exit code + structured stdout/stderr |
| `recovery` | `classify`, `act` | error context | action verb (`retry`, `backtrack`, `escalate`, `abort`) |
| `orchestrator` | `run` | upstream artifacts | downstream artifact(s) + verdict |
| `claim-coordinator` | `claim`, `release`, `heartbeat`, `list_claims` | issue id | acquired flag + lease id |
| `daemon` | `tick` | poll interval | events to bus |

### Lifecycle ordering

For each plugin discovered in a run, the engine calls in this order:

1. `init` — once per pipeline run, before any `run`. Reserve resources, validate config.
2. `run` (or kind-specific entry: `classify`/`claim`/`tick`) — possibly many times.
3. `finalize` — once at end-of-run; flush state, emit summary event.
4. `cleanup` — on abnormal exit only; release locks, write tombstone event.

The engine is responsible for: discovery, manifest validation, lifecycle ordering, redaction enforcement, event emission. It does not call business logic directly.

### Error semantics

- Plugins return exit codes: `0` success, `1` recoverable error, `2` fatal (escalate).
- Plugins MAY emit `recovery.suggestion` events; the engine routes them to `kind: recovery` plugins for classification.
- The engine MUST emit a synthetic blocking finding if a plugin declares `provides.artifact_type` but no artifact exists at `outputs[].path` after `run` completes. (Fail-closed scanner from Keepers §C.4.)

### Discovery + lockfile

- `plugins/<kind>/<name>/manifest.yaml` is discovered via filesystem glob at engine startup.
- A discovered set is captured in `~/.zbuild/state/plugins.lock` (manifest hashes + paths) on first successful run.
- Subsequent runs validate against the lockfile; checksum mismatch → warn (config flag determines block-vs-warn).
- Plugins can be disabled per-run via `config/plugins.disabled` (line-delimited plugin IDs).

---

## 3. Data flow: a `zbuild pipeline start` traversal

```
zbuild pipeline start --issue 42
   │
   ▼
[CLI parses → pipeline-state.json created → atomic_write]
   │
   ▼
[plugin-registry.discover() → load all manifests, validate against lockfile]
   │
   ▼
[locks.admission_gate() → reap → count → memcheck → write → release-on-exit]
   │
   ▼
[github.claim(42) → claim-coordinator plugin returns {acquired:true, lease_id}]
   │
   ▼
[event-bus.emit("pipeline.start", {issue:42, ...})]
   │
   ▼
[engine traverses stages from template; per stage:]
   │
   ├─▶ [redaction.apply(prompt_text, scope_manifest) → wrapped text]
   ├─▶ [router.route(tier, complexity) → model selection]
   ├─▶ [plugin.run(wrapped_text, model) → artifact]
   ├─▶ [event-bus.emit("stage.complete", {stage, plugin, artifact_path})]
   ├─▶ [state.update(stage_status, CURRENT_ITERATION) → atomic_write + .bak]
   │
   ▼
[compound_quality orchestrator runs (4-phase: preflight → plan → cycle → backtrack)]
   │
   ▼
[github.update_live_comment(pipeline-progress-marker, new_status)]
   │
   ▼
[finalize all plugins → emit "pipeline.end" → release claim]
```

Every box that emits LLM-bound text passes through `redaction.apply()`. There is no other path. If a plugin tries to call an LLM directly, the engine refuses to start it (lockfile check).

---

## 4. State model

### Persisted (survives crash, kill -9, host restart)

- `state/pipeline-state.json` — stage statuses, SELF_HEAL_COUNT, scope manifest hash, **CURRENT_ITERATION**, cost ledger pointer.
- `state/events.db` (SQLite) — durable copy of all events.
- `state/events.jsonl` — single-writer append-only log (truncated atomically during rotation).
- `state/artifacts/` — per-stage output artifacts (findings, plans, reviews).
- `state/scope-manifest.md` — fenced markdown contract (artifact-as-contract).
- `state/locks/` — admission gate locks, plugin runtime locks.
- `state/plugins.lock` — discovered plugin set + checksums.

### Reconstructed on resume

- `CURRENT_ITERATION`: read from `pipeline-state.json` if present; if absent (legacy resume), reconstructed from `events.jsonl` tail (last `iteration.start` event).
- Runtime caches (git diff, env-var snapshots, computed model recommendations).
- `loop-state.md` (debugging-only; gitignored; regenerated each iteration).

### Resume best-effort contract

Plugins declare in their manifest whether they require persisted state across resume:

```yaml
state:
  persisted: [findings, last_cycle_score]
  reconstructed: [git_diff, repo_hash]
```

Engine validates: every key in `persisted` must be written via `core/state/atomic_write`; every key in `reconstructed` MUST have a regeneration path or the plugin's `init` MUST refuse to run on resume.

### Redaction chokepoint

`core/redaction/apply_scope_redaction(text, scope_manifest, allowlist, cycle_id)` is the single function any plugin uses to emit LLM-bound text. It:
1. Refuses to emit if `scope_manifest` is unset (synthetic blocking finding).
2. Strips paths outside scope (allowlist + path-token regex).
3. Adds `<out-of-scope-context>` markers around stripped sections.
4. Records redaction stats to the event bus.
5. Idempotent — running twice produces identical output.

No other entry point may emit LLM-bound text. This is enforced by code review + a test that greps for raw model invocations outside `core/redaction/`.

---

## 5. GitHub label contract (external API)

The shipwright innovation we preserve verbatim: **GitHub labels are the entire control plane.** No SDK, no API tokens, no dashboard required. Operators can pause / retry / redirect from the web UI.

- `zbuild` — input: "process this issue."
- `pipeline/in-progress` — claim-coordinator owns this issue.
- `pipeline/complete` — pipeline succeeded.
- `pipeline/failed` — pipeline gave up (after retries).
- `claimed:<machine>` — which host is running it.
- `priority:high` / `priority:low` — affects triage scoring.
- Other labels emit events but don't change control flow.

Polling is canonical; webhooks (when configured) only emit observability events.

---

## 6. Event bus schema

Events are written atomically to **both** SQLite (durable) and JSONL (streamable). Schema:

```json
{
  "ts": "2026-05-24T12:34:56.789Z",
  "run_id": "uuid",
  "issue": 42,
  "type": "stage.complete",
  "plugin": "security-lens",
  "kind": "agent",
  "data": { /* type-specific */ },
  "schema_version": 1
}
```

Required event types (from shipwright; carry forward):

- `pipeline.{start,end,abort}`
- `stage.{start,complete,fail,skip}`
- `plugin.{init,run,finalize,cleanup,error}`
- `redaction.{applied,refused}`
- `model.{route,outcome}`
- `recovery.{suggestion,action,exhausted}`
- `claim.{acquire,renew,release,expire}`
- `cycle.{start,complete,plateau,divergence}`

Schema-as-warn: unknown event types are logged with a warning but never block the pipeline.

---

## 7. Glossary

- **Keeper** — a behavior we preserve from shipwright (catalog in [KEEPERS.md](KEEPERS.md)). Each keeper has a citation and a 5-test trial.
- **Plugin kind** — the type discriminator on a manifest: `agent | tool | recovery | orchestrator | claim-coordinator | daemon`. Determines required lifecycle hooks.
- **Chokepoint** — a single function/seam through which all data of a certain kind must pass (e.g., redaction). Enforced by code review + test, not by language-level access control.
- **Tier (T0–T4)** — model routing ordinal. T0 = no LLM (Agent Booster / WASM); T1 = micro / haiku; T2 = sonnet; T3 = opus; T4 = experimental. Models are data in `config/models.json`; tier numbers are stable, model names are not referenced in code.
- **Scope manifest** — fenced markdown block in `design.md` (or runtime equivalent) listing allowed paths. Artifact-as-contract: humans edit visually, engine parses with awk.
- **Atomic write** — `tmp file + mv + fsync + .bak rotation`. Every state write goes through this.
- **Legacy citation** — a `legacy/path/file:line` reference in a KEEPERS section or issue body. Resolves until that file is `git rm`'d during the pruning protocol.
- **5-test trial** — the keeper acceptance gate: (1) behavior preserved, (2) regression test exists, (3) citation discoverable, (4) mapping matches, (5) removal reproduces symptom.
- **Tombstone** — `legacy/migrated/<keeper-id>.md` written when a keeper passes its trial and its legacy source is removed.
- **Admission gate** — sequence of checks before a pipeline starts: reap stale locks → count actives → memory floor → write lock → (eventually) release. Sequentially dependent, not parallel.

---

## 8. What lives where (file-system tour)

| Path | Purpose |
|---|---|
| `core/state/` | atomic writes, flock, resume contract |
| `core/redaction/` | the single chokepoint for LLM-bound text |
| `core/plugin-registry/` | manifest schema, discovery, lifecycle, lockfile |
| `core/event-bus/` | SQLite + JSONL emit + schema validation |
| `core/locks/` | admission gate, in-process, per-host |
| `core/github/` | label contract, live-updating comment, claim coordination glue |
| `plugins/<kind>/<name>/` | one plugin per directory, manifest-driven |
| `config/models.json` | T0–T4 ordinal + model details (data, not code) |
| `config/event-schema.json` | event types + payload schemas |
| `scripts/` | CLI entry (`zbuild`, `zb`) + shared lib |
| `scripts/lib/` | `helpers.sh`, `compat.sh`, `test-helpers.sh` |
| `tests/` | migrated + new tests; `tests/golden/` for snapshot diffs |
| `docs/adr/` | architecture decision records |
| `legacy/` | frozen shipwright import; shrinks to zero as keepers verify out |
| `legacy/migrated/` | tombstones, one per migrated keeper |
| `.github/issues/` | `keepers-manifest.yaml` (source of truth for issue generation) |
| `.github/workflows/` | CI/CD |
| `.claude/` | hook settings, conventions for AI agents |

---

## 9. Out of scope for this document

- Specific plugin implementations — see `plugins/<name>/README.md`.
- Phase-by-phase migration plan — see [KEEPERS.md §O Phase 0 Sequence](KEEPERS.md#phase-0--final-sequence).
- Individual ADRs — see `docs/adr/`.
