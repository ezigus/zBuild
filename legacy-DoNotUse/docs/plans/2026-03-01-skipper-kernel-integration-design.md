# Skipper Kernel Integration Design — Hand-as-Toolbox

**Date:** 2026-03-01
**Status:** Approved
**Approach:** A — Hand-as-Toolbox (bundled Hand + custom Rust tools)

## Context

The `skipper-shipwright` Rust crate (9 modules, 356 tests, zero clippy warnings) implements Shipwright's pipeline engine, decision engine, memory, fleet management, and intelligence layer. It needs to be wired into the Skipper kernel as a first-class Hand so that:

- Shipwright activates via `POST /api/hands/shipwright/activate`
- The Hand agent calls custom tools that delegate to the Rust crate
- Pipeline state, failure patterns, and decisions persist via kernel memory
- Events flow through the kernel event bus
- The whole system is proven working end-to-end

## Architecture

```
User / API
    │
    ▼
Skipper Kernel
    │
    ├── HandRegistry.activate("shipwright")
    │       │
    │       ▼
    │   AgentManifest (from HAND.toml)
    │       │
    │       ▼
    │   spawn_agent() → Shipwright Agent
    │       │
    │       ▼
    │   Agent Loop (LLM ↔ Tools)
    │       │
    │       ▼
    │   tool_runner::execute_tool()
    │       │
    │       ├── "shipwright_pipeline_start" → skipper_shipwright::tools::pipeline_start()
    │       ├── "shipwright_pipeline_status" → skipper_shipwright::tools::pipeline_status()
    │       ├── "shipwright_stage_advance"   → skipper_shipwright::tools::stage_advance()
    │       ├── "shipwright_decision_run"    → skipper_shipwright::tools::decision_run()
    │       ├── "shipwright_memory_search"   → skipper_shipwright::tools::memory_search()
    │       ├── "shipwright_memory_store"    → skipper_shipwright::tools::memory_store_pattern()
    │       ├── "shipwright_fleet_status"    → skipper_shipwright::tools::fleet_status()
    │       └── "shipwright_intelligence"    → skipper_shipwright::tools::intelligence()
    │               │
    │               ▼
    │       skipper-shipwright crate
    │       (Pipeline, Decision, Memory, Fleet, Intelligence)
    │               │
    │               ▼
    │       KernelHandle (memory_store, task_post, publish_event, spawn_agent)
    │
    └── MemorySubstrate (SQLite + vector search)
```

## Custom Tools

8 tools registered as built-in (not MCP/skill) because Shipwright is a first-class bundled Hand:

| Tool Name                    | Purpose                         | Key Inputs                                      |
| ---------------------------- | ------------------------------- | ----------------------------------------------- |
| `shipwright_pipeline_start`  | Start a delivery pipeline       | `goal` or `issue_number`, `template`            |
| `shipwright_pipeline_status` | Get current pipeline state      | `pipeline_id` (optional)                        |
| `shipwright_stage_advance`   | Advance stage or report failure | `pipeline_id`, `outcome`                        |
| `shipwright_decision_run`    | Run autonomous decision cycle   | `dry_run`, `signal_filter`                      |
| `shipwright_memory_search`   | Search failure patterns         | `query`, `repo`, `limit`                        |
| `shipwright_memory_store`    | Record a failure pattern        | `error_class`, `signature`, `root_cause`, `fix` |
| `shipwright_fleet_status`    | Fleet overview across repos     | (none)                                          |
| `shipwright_intelligence`    | Run intelligence analysis       | `repo_path`, `analysis_type`                    |

### Tool Implementation Pattern

```rust
// skipper-shipwright/src/tools.rs

pub fn tool_definitions() -> Vec<ToolDefinition> { /* 8 definitions */ }

pub async fn pipeline_start(
    input: &serde_json::Value,
    kernel: Option<&Arc<dyn KernelHandle>>,
) -> ToolResult { /* ... */ }
```

### Dispatch Wiring

In `skipper-runtime/src/tool_runner.rs`:

```rust
// In execute_tool() match block:
name if name.starts_with("shipwright_") => {
    skipper_shipwright::tools::dispatch(tool_use_id, name, input, kernel).await
}

// In builtin_tool_definitions():
defs.extend(skipper_shipwright::tools::tool_definitions());
```

## HAND.toml

```toml
id = "shipwright"
name = "Shipwright Hand"
description = "Autonomous delivery pipeline — turns issues into tested, reviewed PRs"
category = "engineering"
icon = "⚓"

tools = [
    "shipwright_pipeline_start", "shipwright_pipeline_status",
    "shipwright_stage_advance", "shipwright_decision_run",
    "shipwright_memory_search", "shipwright_memory_store",
    "shipwright_fleet_status", "shipwright_intelligence",
    "shell_exec", "file_read", "file_write", "file_list",
    "web_fetch", "memory_store", "memory_recall",
    "knowledge_add_entity", "knowledge_add_relation",
    "event_publish", "agent_spawn", "agent_send", "schedule_create",
]

[[settings]]
key = "pipeline_template"
label = "Default Pipeline Template"
type = "select"
options = ["fast", "standard", "full", "hotfix", "autonomous", "cost-aware"]
default = "standard"

[[settings]]
key = "max_parallel"
label = "Max Parallel Pipelines"
type = "number"
default = "2"

[[settings]]
key = "auto_decide"
label = "Autonomous Decision Engine"
type = "boolean"
default = "false"

[agent]
name = "shipwright-hand"
module = "builtin:chat"
provider = "default"
model = "default"
max_iterations = 200
system_prompt = """You are Shipwright..."""

[dashboard]
title = "Shipwright Pipeline"

[[dashboard.metrics]]
key = "active_pipelines"
label = "Active Pipelines"
type = "gauge"

[[dashboard.metrics]]
key = "stages_completed"
label = "Stages Completed"
type = "counter"

[[dashboard.metrics]]
key = "success_rate"
label = "Success Rate"
type = "percentage"
```

## Memory Wiring

Adapter pattern — `KernelMemoryAdapter` wraps `KernelHandle` for the shipwright crate:

- **With kernel** (production): delegates to `KernelHandle::memory_store` / `memory_recall` (persistent SQLite + vector search)
- **Without kernel** (tests/standalone): uses existing in-memory `ShipwrightMemory`

Stored data:

- Pipeline state: `pipeline:{id}`
- Failure patterns: `failure:{repo}:{error_class}`
- Decision logs: `decision:{date}:{id}`
- Scoring weights: `weights:current`

## Files to Create/Modify

| File                                                      | Action | Purpose                                  |
| --------------------------------------------------------- | ------ | ---------------------------------------- |
| `crates/skipper-hands/bundled/shipwright/HAND.toml`      | Create | Hand definition                          |
| `crates/skipper-hands/bundled/shipwright/SKILL.md`       | Create | Domain knowledge (from fork)             |
| `crates/skipper-shipwright/src/tools.rs`                 | Create | 8 tool handlers + definitions + dispatch |
| `crates/skipper-shipwright/src/memory/kernel_adapter.rs` | Create | KernelHandle memory bridge               |
| `crates/skipper-shipwright/src/lib.rs`                   | Modify | Export tools module                      |
| `crates/skipper-hands/src/bundled.rs`                    | Modify | Register Shipwright in bundled_hands()   |
| `crates/skipper-runtime/src/tool_runner.rs`              | Modify | Wire dispatch + definitions              |
| `crates/skipper-runtime/Cargo.toml`                      | Modify | Add skipper-shipwright dep              |
| `crates/skipper-shipwright/Cargo.toml`                   | Modify | Add skipper-types dep                   |
| `crates/skipper-shipwright/tests/tool_tests.rs`          | Create | Tool handler unit tests                  |

## E2E Verification

1. `cargo build --workspace --lib` — compiles
2. `cargo test --workspace` — all tests pass
3. `cargo clippy --workspace --all-targets -- -D warnings` — zero warnings
4. Hand activation: `POST /api/hands/shipwright/activate` spawns agent
5. Pipeline via agent: send message, agent calls `shipwright_pipeline_start`
6. Memory persistence: store failure pattern, search it back
7. Fleet status: `shipwright_fleet_status` returns data
