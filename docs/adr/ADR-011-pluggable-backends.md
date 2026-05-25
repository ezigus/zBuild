# ADR-011: Pluggable Backends (Memory, Orchestrator, Cache)

**Status:** Accepted
**Date:** 2026-05-24

> **Memory split:** The "memory backend" in this ADR is **learning memory** —
> patterns extracted from past runs, vector embeddings of source code,
> architectural decisions, skill-success scores. It accumulates over time and
> spans pipelines.
>
> It is **NOT** pipeline-resume memory (which is defined by
> [ADR-006](ADR-006-resume-contract.md) and transported by
> [ADR-010](ADR-010-ci-cli-parity.md) cache backends). Resume state is
> operational ("continue at stage X iteration Y"); learning memory is
> educational ("similar issues in the past took 3 cycles to converge").
>
> The two memory models share no storage and have independent failure modes:
> learning memory can be totally unavailable and pipelines still resume
> correctly; resume memory can be wiped and pipelines still benefit from
> learned patterns on the next fresh run.

## Context

Three cross-cutting capabilities can be implemented multiple ways, and zBuild should not pick one implementation in core:

1. **Memory backend** — where learned patterns, embeddings, and decisions live. Could be local SQLite, ruflo's HNSW vector store via MCP, a future cloud KV, etc.
2. **Orchestrator backend** — how parallel agents are spawned and coordinated. Could be plain bash subshells, ruflo's hive-mind, a future job-queue worker pool, etc.
3. **Cache backend** — where durable state persists across CI runs (covered in ADR-010); same pattern.

User requirement: "I want the option to use ruflo memory and ruflo swarming/hive abilities — those are not hard dependencies early on but they need to be able to do it in the future, so the architecture needs to be set to handle that."

Translation: ship working defaults that need zero external services; let ruflo (or anything else) drop in via the plugin contract.

## Decision

Each capability gets a **backend contract** (a fixed set of function names + I/O shapes). A "backend" is just a plugin (`kind: tool`, with `provides.role: memory-backend` etc.) that implements the contract. zBuild ships defaults; users select alternates via `.zbuild/config.yaml`.

### Memory backend contract

```bash
memory_put <namespace> <key> <value>                 # store
memory_get <namespace> <key>                          # → value or empty
memory_search <namespace> <query> [--limit N]         # → list of matches
memory_list_namespaces                                # → list of strings
memory_namespace_exists <namespace>                   # exit 0/1
memory_namespace_clear <namespace>                    # destructive cleanup
```

Optional (backends MAY implement; callers MUST handle absence):
```bash
memory_search_vector <namespace> <embedding>          # vector similarity search
memory_capabilities                                   # → JSON of declared capabilities
```

**Default implementation**: `plugins/tool/memory-sqlite/` — local SQLite at `~/.zbuild/state/memory.db`, TF-IDF text search via `LIKE %query%`, no vector support. Always works, no external deps.

**Optional implementation**: `plugins/tool/memory-ruflo/` — proxies to ruflo MCP for HNSW vector search. Requires `ruflo` binary on PATH; `memory_capabilities` declares `["vector_search", "hnsw"]`.

### Orchestrator backend contract

```bash
orch_spawn <pool_id> <count> <role_arg>               # spawn N workers
orch_dispatch <pool_id> <task_json>                   # send work to pool
orch_collect <pool_id> [--timeout S]                  # gather results; exit 0=all pass, 1=all fail, 2=partial
orch_shutdown <pool_id>                               # cleanup
orch_capabilities                                     # → JSON
```

**`orch_collect` exit code convention (all implementations must honour this):**
- `0` — all dispatched work units exited 0 (success); pool dir removed.
- `1` — all dispatched work units exited non-zero (complete failure).
- `2` — mixed results: at least one unit passed and at least one failed (partial).

Work-unit exit codes are normalised — individual codes are not passed through. Strategies use `2` to emit `stage.fail reason=partial` via the runner.

**Phase 0.5 default implementation**: `plugins/tool/orch-sequential/` — single-process, in-order dispatch. Chosen as the default for Phase 0.5 because it has zero coordination surface and the smallest reference impl of the 0/1/2 normalisation contract. The `bash-parallel` example in `.zbuild/config.yaml` below shows the most common opt-in.

**Parallel implementation**: `plugins/tool/orch-bash-parallel/` — uses bash subshells + `wait -n` for parallelism, no coordination beyond independent execution. Implements `fanout` and `sequential` strategies trivially; `composite` works via a single subshell.

**Optional implementation**: `plugins/tool/orch-ruflo-hive/` — proxies to `ruflo hive-mind init/spawn/orchestrate`. Implements all three strategies natively; provides queen-collapse synthesis and shared-memory namespacing. `orch_capabilities` declares `["hive_mind", "queen_collapse", "shared_memory"]`.

### Cache backend contract (covered in ADR-010)

```bash
cache_pull <slot_id>                                  # restore state from cache
cache_push <slot_id>                                  # snapshot state to cache
cache_capabilities                                    # → JSON
```

Defaults: `local` (no-op). Optionals: `gh-actions-cache`, `s3`, `gist`.

### Backend selection: `.zbuild/config.yaml`

> **Scope note:** backend pluggability covers **memory, orchestrator, and cache only**. Model routing is core per ADR-003 — `core/router/route.sh` is not a backend and is not selectable via this config.

```yaml
backends:
  memory: sqlite                    # default; or "ruflo"
  orchestrator: sequential          # default; or "bash-parallel", "ruflo-hive"
  cache: local                      # default; or "gh-actions-cache", "s3"

# Optional per-backend config
memory_ruflo:
  mcp_server: "ruflo"
  namespace_prefix: "zbuild"
  fallback_to_default_on_error: true

orchestrator_ruflo:
  topology: hierarchical
  max_agents: 8
  hive_timeout_sec: 300
```

Resolution at startup: read config, look up the named backend in the plugin registry, verify it implements the contract. If a backend is selected but missing, `zbuild doctor` flags it. **Critical**: when a non-default backend is selected, callers MUST handle `_capabilities` differences (e.g., don't request `memory_search_vector` from the SQLite default).

### Graceful degradation rules

1. **Default backend always works.** Out-of-box experience requires nothing more than `npm install -g zbuild`.
2. **Optional backend can be configured but unavailable at runtime** (e.g., ruflo daemon crashed). Each backend declares `fallback_to_default_on_error: true|false`. If true, runtime falls back to default with a `backend.degraded` event; if false, hard-fails with a clear error.
3. **Backend capabilities are declarative.** Callers query `<backend>_capabilities` and choose a code path based on what's available. Example: pipeline-intelligence might do vector search if `vector_search` is in capabilities, TF-IDF otherwise.

### Plugin manifest extension

Memory and orchestrator backends are `kind: tool` plugins with a special `provides.role`:

```yaml
# plugins/tool/memory-sqlite/manifest.yaml
id: memory-sqlite
kind: tool
provides:
  role: memory-backend                  # marks as backend implementation
  capabilities: [text_search, namespacing, persistence]

# plugins/tool/memory-ruflo/manifest.yaml
id: memory-ruflo
kind: tool
provides:
  role: memory-backend
  capabilities: [text_search, vector_search, hnsw, namespacing, persistence, distributed]
requires:
  bin: [ruflo]                          # NEW manifest field: required binaries
```

The plugin registry can list all backends of a role: `zbuild plugin list --role memory-backend`.

## Consequences

**Good:**
- Zero external dependencies for the out-of-box experience.
- Adding a new backend (e.g., Pinecone, Redis, Dragonfly) = drop a plugin, declare capabilities, done.
- Tests for the engine never need ruflo running.
- Users opt in to advanced features (HNSW, hive-mind) by config, not by code change.
- Failure modes are explicit: missing backend → doctor warns; runtime backend crash → graceful fallback if configured.

**Bad:**
- More plugins to maintain (defaults + ruflo + future variants).
- Callers must check `_capabilities` before using optional features; easy to forget.
- Backend selection lives in config; users with broken configs may not realize a feature is silently using the default.

**Open questions:**
- Should backends be per-namespace? (e.g., "use SQLite for cost ledger, ruflo HNSW for embeddings"). Initial design: per-capability is the unit (memory backend is one choice; can't split). Revisit if real demand.
- Should `_capabilities` results be cached or queried every run? Initial: queried once at backend init.

## References

- [ADR-001 — Plugin Contract](ADR-001-plugin-contract.md) — backends are plugins
- [ADR-010 — CI / CLI Parity](ADR-010-ci-cli-parity.md) — cache backends follow same pattern
- ruf-1..5 issues (#102-#106) — implement the ruflo memory backend as ONE of multiple options, not the only one
- db-1..6 issues (#125-#130) — implement the SQLite default memory backend's tables
