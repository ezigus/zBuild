# Unified Platform Strategy — Shipwright + Skipper

March 2026

---

## Vision

Skipper subsumes Shipwright. Long-term, Skipper's Rust kernel becomes the execution engine. Shipwright bash scripts become the reference implementation that Skipper agents call. Pipeline, daemon, fleet, memory all run through Skipper eventually.

## Strategy: Parallel Streams

Three concurrent workstreams, each owning distinct files to avoid merge conflicts:

| Stream                    | Scope                            | File Ownership                                                                                                     |
| ------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| 1. Clean Architecture     | Skipper Rust refactoring         | `crates/skipper-api/src/`, `skipper-kernel/src/`, `skipper-cli/src/`, `skipper-types/src/`, `skipper-runtime/src/` |
| 2. Deep Integration       | Shipwright → Skipper wiring      | `crates/skipper-shipwright/`, `crates/skipper-hands/bundled/shipwright/`, new route files only                     |
| 3. Capabilities + Cleanup | Claude Code, bash cleanup, brand | `.claude/`, `scripts/`, `dashboard/`, `website/`, docs                                                             |

Each stream runs in its own worktree. Merge order: Stream 1 first (foundation), then Stream 2 (integration into clean modules), then Stream 3 (no Rust conflicts).

---

## Stream 1: Clean Architecture

### Problem

Five god-files concentrate too much logic:

| File             | Lines | Issue                                |
| ---------------- | ----- | ------------------------------------ |
| `routes.rs`      | 8,983 | Every API endpoint in one file       |
| `main.rs` (CLI)  | 5,671 | Every CLI command in one file        |
| `kernel.rs`      | 5,177 | All kernel operations in one file    |
| `tool_runner.rs` | 3,625 | All tool implementations in one file |
| `config.rs`      | 3,579 | All config types in one file         |

### Solution

Decompose each into domain-oriented module trees.

#### routes.rs → routes/

```
crates/skipper-api/src/routes/
├── mod.rs          (~100 lines — router builder, re-exports)
├── agents.rs       (~1,200 lines — CRUD, messaging, lifecycle)
├── budget.rs       (~400 lines — budget, cost, per-agent spend)
├── channels.rs     (~1,500 lines — channel CRUD, templates, bridge)
├── hands.rs        (~800 lines — hand registry, install, config)
├── network.rs      (~600 lines — OFP peers, A2A, federation)
├── security.rs     (~500 lines — security dashboard, audit)
├── settings.rs     (~400 lines — config read/write)
├── triggers.rs     (~600 lines — trigger CRUD, webhooks)
├── skills.rs       (~400 lines — skill registry)
├── static_files.rs (~200 lines — HTML/asset serving)
└── health.rs       (~100 lines — health, status)
```

#### kernel.rs → kernel/

```
crates/skipper-kernel/src/kernel/
├── mod.rs          (~500 lines — KernelBuilder, startup, shutdown)
├── agents.rs       (~1,200 lines — spawn, kill, list, lifecycle)
├── workflows.rs    (~1,000 lines — workflow engine, triggers)
├── channels.rs     (~800 lines — channel management)
├── config.rs       (~600 lines — runtime config management)
└── budget.rs       (~400 lines — budget tracking, enforcement)
```

#### main.rs → commands/

```
crates/skipper-cli/src/
├── main.rs         (~200 lines — arg parsing, dispatcher)
├── commands/
│   ├── mod.rs      (~50 lines — re-exports)
│   ├── agent.rs    (~800 lines — agent lifecycle)
│   ├── hand.rs     (~600 lines — hand management)
│   ├── skill.rs    (~400 lines — skill management)
│   ├── config.rs   (~500 lines — config management)
│   ├── channel.rs  (~400 lines — channel management)
│   ├── auth.rs     (~300 lines — auth/login)
│   └── daemon.rs   (~400 lines — daemon start/stop)
```

#### tool_runner.rs → tools/

```
crates/skipper-runtime/src/tools/
├── mod.rs          (~300 lines — dispatcher, tool definition registry)
├── filesystem.rs   (~500 lines — read, write, glob, grep)
├── web.rs          (~400 lines — web search, fetch)
├── shell.rs        (~400 lines — bash execution, sandbox)
├── agents.rs       (~300 lines — agent spawn/management)
├── notebook.rs     (~200 lines — jupyter tools)
└── shipwright.rs   (~400 lines — feature-gated shipwright tools)
```

#### config.rs → config/

```
crates/skipper-types/src/config/
├── mod.rs          (~500 lines — core KernelConfig, top-level types)
├── channels.rs     (~1,000 lines — channel configs per provider)
├── models.rs       (~800 lines — model/provider configs)
├── budget.rs       (~400 lines — budget/cost config)
└── display.rs      (~300 lines — Display impls, formatting)
```

### Principles

- **Thin routes:** Max ~20 lines per handler. Extract, validate, delegate, format.
- **Domain grouping:** Group by domain (agents, channels, budget), not by HTTP verb.
- **Error types:** One `ApiError` enum with `impl IntoResponse`. No `.unwrap()` in handlers.
- **No behavior changes:** Pure structural refactoring. Every test must continue to pass.

### Verification

After each decomposition:

```bash
cargo build --workspace --lib
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

---

## Stream 2: Deep Integration

### Current State

The `skipper-shipwright` crate has 8 tools that manage pipeline state in-memory via `ShipwrightState`. The real Shipwright capabilities (bash scripts, daemon, memory, fleet) are not wired.

### Target State

Skipper agents can do everything Shipwright CLI can, natively.

### Tool Enhancements

| Tool                             | Current           | Target                                                                                            |
| -------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------- |
| `shipwright_pipeline_start`      | In-memory state   | Spawns `sw-pipeline.sh` subprocess, streams stage progress, writes events to Skipper event store  |
| `shipwright_pipeline_status`     | In-memory read    | Reads `.claude/pipeline-state.md` + subprocess status. Stage timing, iteration, test results      |
| `shipwright_decision`            | Stub scoring      | Calls `sw-decide.sh` for template selection, risk scoring. Falls back to in-memory if unavailable |
| `shipwright_memory_store/recall` | In-memory HashMap | Reads/writes `~/.shipwright/memory/`. Syncs with Skipper memory store                             |
| `shipwright_fleet_status`        | Stub              | Reads `~/.shipwright/fleet-config.json`, daemon state, worker pool                                |
| `shipwright_intelligence`        | Stub              | Calls `sw-intelligence.sh analyze` with caching                                                   |
| `shipwright_cost`                | Stub              | Reads `~/.shipwright/costs.json` and `budget.json`                                                |
| `shipwright_daemon`              | Stub              | Start/stop/configure daemon. Read daemon metrics                                                  |

### New Files

```
crates/skipper-shipwright/src/subprocess.rs    (~300 lines — spawn/monitor bash scripts)
crates/skipper-shipwright/src/memory_bridge.rs (~200 lines — bridge to real memory files)
crates/skipper-shipwright/src/fleet_bridge.rs  (~200 lines — read fleet/daemon state)
crates/skipper-api/src/routes/pipelines.rs     (~400 lines — pipeline status API)
```

### Dashboard Integration

- **Pipelines tab:** Active/completed pipelines with stage progress bars
- **Fleet view:** Multi-repo fleet status, worker pool, per-repo queue depth
- **Unified memory:** Shipwright memory readable through Skipper dashboard

---

## Stream 3: Claude Code Capabilities + Bash Cleanup

### Bash Cleanup

#### Decompose pipeline-stages.sh (3,225 lines)

```
scripts/lib/
├── pipeline-stages-intake.sh    (~400 lines — intake, plan, design)
├── pipeline-stages-build.sh     (~800 lines — build, test)
├── pipeline-stages-review.sh    (~600 lines — review, compound_quality)
├── pipeline-stages-delivery.sh  (~500 lines — pr, merge, deploy)
├── pipeline-stages-monitor.sh   (~400 lines — validate, monitor)
└── pipeline-stages.sh           (~100 lines — sources sub-files, exports stage list)
```

#### Adopt shared test harness

Update 108 test scripts to `source "$SCRIPT_DIR/lib/test-helpers.sh"` instead of defining own helper functions. Estimated 15-20% code reduction.

#### Decompose sw-loop.sh (3,366 lines)

```
scripts/lib/
├── loop-iteration.sh     (~600 lines — single iteration logic)
├── loop-convergence.sh   (~400 lines — convergence detection)
├── loop-restart.sh       (~300 lines — session restart logic)
├── loop-progress.sh      (~200 lines — progress.md management)
```

### Claude Code Capabilities

#### 1. Skipper MCP Server

Register Skipper's API as an MCP server for Claude Code:

```json
{
  "mcpServers": {
    "skipper": {
      "command": "curl",
      "args": ["-s", "http://127.0.0.1:4200/mcp"],
      "description": "Skipper Agent OS"
    }
  }
}
```

Tools: `skipper_spawn_agent`, `skipper_list_agents`, `skipper_send_message`, `skipper_pipeline_status`, `skipper_fleet_status`.

#### 2. New Skills

```
.claude/skills/
├── pipeline-monitor.md    — Check pipeline progress, surface blockers
├── fleet-overview.md      — Multi-repo fleet status
├── agent-debug.md         — Debug a stuck/failing Skipper agent
├── cost-report.md         — Token usage and cost analysis
```

#### 3. Enhanced Hooks

Add a hook that detects Skipper agent crashes and auto-captures diagnostics to memory.

#### 4. Brand Implementation

Execute the Refined Depths plan (`docs/plans/2026-03-01-refined-depths-implementation.md`). Touches only dashboard CSS, HTML, docs.

---

## Merge Strategy

1. **Stream 1 merges first** — Pure structural refactoring, no behavior changes
2. **Stream 2 merges second** — Integration code lands in the newly clean module structure
3. **Stream 3 merges last** — No Rust file conflicts, only bash/CSS/docs

If streams finish at different times, merge as they complete in this priority order. Stream 3 can merge independently at any time since it touches no Rust.

---

## Success Criteria

- All 5 god-files decomposed to <1,000 lines per module
- All 2,190+ existing tests pass
- Zero clippy warnings
- 8 Shipwright tools call real scripts (not stubs)
- Pipeline status visible in Skipper dashboard
- Shared test harness adopted by >90% of test scripts
- MCP server functional for Claude Code integration
- Refined Depths brand applied to both dashboards

---

## Risk Mitigations

| Risk                                                    | Mitigation                                                                          |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Merge conflicts between streams                         | Strict file ownership boundaries. No stream touches another's files.                |
| Decomposition breaks behavior                           | Pure structural moves, no logic changes. Run full test suite after every file move. |
| Integration subprocess spawning fails on some platforms | Graceful fallback to in-memory stubs when bash unavailable                          |
| Large PR size for Stream 1                              | Decompose one god-file per PR (5 PRs total)                                         |
