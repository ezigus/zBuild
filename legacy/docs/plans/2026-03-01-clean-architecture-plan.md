# Stream 1: Clean Architecture Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Decompose 5 Skipper Rust god-files into domain-oriented module trees without changing any behavior.

**Architecture:** Pure structural refactoring. Each god-file becomes a module directory. Functions move to domain-grouped files. The original file becomes a thin re-export module. All 2,190+ tests must continue to pass after every task.

**Tech Stack:** Rust modules, `pub use` re-exports, `mod` declarations.

**Important:** All file paths are relative to `skipper/`. Run all commands from the `skipper/` directory.

---

### Task 1: Decompose routes.rs — Create Module Structure

**Files:**

- Create: `crates/skipper-api/src/routes/mod.rs`
- Create: `crates/skipper-api/src/routes/health.rs`
- Modify: `crates/skipper-api/src/server.rs` (update `mod routes` to `mod routes` pointing to directory)

**Step 1: Create the routes directory and mod.rs**

```bash
mkdir -p crates/skipper-api/src/routes
```

**Step 2: Copy routes.rs to routes/mod.rs**

```bash
cp crates/skipper-api/src/routes.rs crates/skipper-api/src/routes/mod.rs
```

**Step 3: Delete the original routes.rs**

```bash
rm crates/skipper-api/src/routes.rs
```

Rust's module system will automatically resolve `mod routes` to `routes/mod.rs`.

**Step 4: Verify everything compiles and tests pass**

```bash
cargo build --workspace --lib
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: All pass. This is a no-op restructure — `routes/mod.rs` has identical content to the old `routes.rs`.

**Step 5: Commit**

```bash
git add -A crates/skipper-api/src/routes/ crates/skipper-api/src/routes.rs
git commit -m "refactor(api): convert routes.rs to routes/ module directory"
```

---

### Task 2: Extract Health & Status Routes

**Files:**

- Create: `crates/skipper-api/src/routes/health.rs`
- Modify: `crates/skipper-api/src/routes/mod.rs`

**Step 1: Create health.rs with the health/status functions**

Move these functions from `mod.rs` to `health.rs`:

- `health` (line ~2490)
- `health_detail` (line ~2510)
- `status` (line ~454)
- `shutdown` (line ~488)
- `version` (line ~867)
- `prometheus_metrics` (line ~2550)

At the top of `health.rs`, add the imports these functions need:

```rust
use crate::types::*;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use std::sync::Arc;
use std::time::Instant;

use super::AppState;
```

**Step 2: In mod.rs, add the module declaration and re-export**

At the top of `mod.rs`, add:

```rust
mod health;
pub use health::*;
```

Then delete the moved functions from `mod.rs`.

**Step 3: Verify**

```bash
cargo build --workspace --lib
cargo test --workspace
```

**Step 4: Commit**

```bash
git add crates/skipper-api/src/routes/
git commit -m "refactor(api): extract health & status routes to routes/health.rs"
```

---

### Task 3: Extract Budget & Usage Routes

**Files:**

- Create: `crates/skipper-api/src/routes/budget.rs`
- Modify: `crates/skipper-api/src/routes/mod.rs`

**Step 1: Create budget.rs**

Move these functions:

- `budget_status` (~4154)
- `update_budget` (~4163)
- `agent_budget_status` (~4196)
- `agent_budget_ranking` (~4251)
- `usage_stats` (~4055)
- `usage_summary` (~4080)
- `usage_by_model` (~4100)
- `usage_daily` (~4122)

Add imports and `use super::AppState;`.

**Step 2: In mod.rs, add `mod budget; pub use budget::*;`**

Delete moved functions from `mod.rs`.

**Step 3: Verify**

```bash
cargo build --workspace --lib && cargo test --workspace
```

**Step 4: Commit**

```bash
git add crates/skipper-api/src/routes/
git commit -m "refactor(api): extract budget & usage routes to routes/budget.rs"
```

---

### Task 4: Extract Workflow & Trigger Routes

**Files:**

- Create: `crates/skipper-api/src/routes/workflows.rs`
- Modify: `crates/skipper-api/src/routes/mod.rs`

**Step 1: Create workflows.rs**

Move these functions:

- `create_workflow` (~508)
- `list_workflows` (~591)
- `run_workflow` (~609)
- `list_workflow_runs` (~646)
- `create_trigger` (~672)
- `list_triggers` (~745)
- `delete_trigger` (~773)
- `update_trigger` (~4408)
- `list_cron_jobs` (~8292)
- `create_cron_job` (~8324)
- `delete_cron_job` (~8342)
- `toggle_cron_job` (~8371)
- `cron_job_status` (~8402)

**Step 2: Add module declaration, re-export, delete from mod.rs**

**Step 3: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
git add crates/skipper-api/src/routes/
git commit -m "refactor(api): extract workflow & trigger routes to routes/workflows.rs"
```

---

### Task 5: Extract Channel Routes

**Files:**

- Create: `crates/skipper-api/src/routes/channels.rs`
- Modify: `crates/skipper-api/src/routes/mod.rs`

**Step 1: Create channels.rs**

Move these functions AND the channel registry data:

- `list_channels` (~1782)
- `configure_channel` (~1834)
- `remove_channel` (~1934)
- `test_channel` (~1997)
- `reload_channels` (~2040)
- `whatsapp_qr_start` (~2068)
- `whatsapp_qr_status` (~2121)
- `list_templates` (~2263)
- `get_template` (~2301)
- `FieldType` enum (~1047)
- `ChannelField` struct (~1067)
- `ChannelMeta` struct (~1079)
- `CHANNEL_REGISTRY` const (~1096-1780)

This is the biggest extraction — ~750 lines of functions + ~700 lines of channel registry data.

**Step 2: Add module declaration, re-export, delete from mod.rs**

**Step 3: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
git add crates/skipper-api/src/routes/
git commit -m "refactor(api): extract channel routes & registry to routes/channels.rs"
```

---

### Task 6: Extract Hands Routes

**Files:**

- Create: `crates/skipper-api/src/routes/hands.rs`
- Modify: `crates/skipper-api/src/routes/mod.rs`

**Step 1: Create hands.rs**

Move:

- `list_hands` (~3038)
- `list_active_hands` (~3073)
- `get_hand` (~3094)
- `check_hand_deps` (~3165)
- `install_hand_deps` (~3210)
- `activate_hand` (~3446)
- `pause_hand` (~3473)
- `resume_hand` (~3490)
- `deactivate_hand` (~3507)
- `hand_stats` (~3524)
- `hand_instance_browser` (~3594)

**Step 2: Add module declaration, re-export, delete from mod.rs**

**Step 3: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
git add crates/skipper-api/src/routes/
git commit -m "refactor(api): extract hands routes to routes/hands.rs"
```

---

### Task 7: Extract Skills Routes

**Files:**

- Create: `crates/skipper-api/src/routes/skills.rs`
- Modify: `crates/skipper-api/src/routes/mod.rs`

**Step 1: Create skills.rs**

Move:

- `list_skills` (~2627)
- `install_skill` (~2669)
- `uninstall_skill` (~2701)
- `marketplace_search` (~2726)
- `clawhub_search` (~2768)
- `clawhub_browse` (~2830)
- `clawhub_skill_detail` (~2880)
- `clawhub_install` (~2943)
- `create_skill` (~6160)
- `get_agent_skills` (~5653)
- `set_agent_skills` (~5697)

**Step 2: Add module declaration, re-export, delete from mod.rs**

**Step 3: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
git add crates/skipper-api/src/routes/
git commit -m "refactor(api): extract skills routes to routes/skills.rs"
```

---

### Task 8: Extract Agent Routes

**Files:**

- Create: `crates/skipper-api/src/routes/agents.rs`
- Modify: `crates/skipper-api/src/routes/mod.rs`

**Step 1: Create agents.rs**

Move all agent lifecycle + messaging + session functions:

- `spawn_agent` (~39)
- `list_agents` (~114)
- `resolve_attachments` (~146)
- `inject_attachments_into_session` (~197)
- `send_message` (~231)
- `get_agent_session` (~303)
- `kill_agent` (~424)
- `get_agent` (~884)
- `set_agent_mode` (~831)
- `send_message_stream` (~942) — this is the 839-line function
- `update_agent` (~4450)
- `update_agent_identity` (~6979)
- `patch_agent_config` (~7058)
- `clone_agent` (~7227)
- `list_agent_files` (~7331)
- `get_agent_file` (~7385)
- `set_agent_file` (~7482)
- `upload_file` (~7636)
- `serve_upload` (~7764)
- All session management: `list_agent_sessions`, `create_agent_session`, `switch_agent_session`, `reset_session`, `compact_session`, `stop_agent`
- All related request/response structs

**Step 2: Add module declaration, re-export, delete from mod.rs**

**Step 3: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
git add crates/skipper-api/src/routes/
git commit -m "refactor(api): extract agent routes to routes/agents.rs"
```

---

### Task 9: Extract Network & A2A Routes

**Files:**

- Create: `crates/skipper-api/src/routes/network.rs`
- Modify: `crates/skipper-api/src/routes/mod.rs`

**Step 1: Create network.rs**

Move:

- `list_peers` (~3939)
- `network_status` (~3969)
- `a2a_agent_card` (~5018)
- `a2a_list_agents` (~5044)
- `a2a_send_task` (~5067)
- `a2a_get_task` (~5160)
- `a2a_cancel_task` (~5177)
- `a2a_list_external_agents` (~5203)
- `a2a_discover_external` (~5225)
- `a2a_send_external` (~5273)
- `a2a_external_task_status` (~5311)
- `mcp_http` (~5345)

**Step 2: Add module declaration, re-export, delete from mod.rs**

**Step 3: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
git add crates/skipper-api/src/routes/
git commit -m "refactor(api): extract network & A2A routes to routes/network.rs"
```

---

### Task 10: Extract Remaining Routes

**Files:**

- Create: `crates/skipper-api/src/routes/settings.rs`
- Create: `crates/skipper-api/src/routes/security.rs`
- Modify: `crates/skipper-api/src/routes/mod.rs`

**Step 1: Create settings.rs**

Move:

- `get_config` (~4032)
- `config_set` (~8107)
- `config_reload` (~7982)
- `config_schema` (~8023)
- `list_models` (~4688)
- `list_aliases` (~4764)
- `get_model` (~4792)
- `list_providers` (~4837)
- `add_custom_model` (~4891)
- `remove_custom_model` (~4987)
- `set_model` (~5615)
- `set_provider_key` (~5825)
- `delete_provider_key` (~5901)
- `test_provider` (~5956)
- `set_provider_url` (~6044)
- `list_profiles` (~805)
- `get_agent_mcp_servers`, `set_agent_mcp_servers`, `list_mcp_servers`

**Step 2: Create security.rs**

Move:

- `security_status` (~4503)
- `audit_recent` (~3761)
- `audit_verify` (~3797)
- `logs_stream` (~3837)

**Step 3: Move remaining into appropriate files or a misc.rs**

Move all remaining functions (integrations, schedules, approvals, webhooks, device pairing, commands, copilot OAuth, KV store, migrations, deliveries) into:

- Create: `crates/skipper-api/src/routes/integrations.rs`
- Create: `crates/skipper-api/src/routes/misc.rs` (for smaller domains like approvals, pairing, commands, copilot)

**Step 4: mod.rs should now be ~50 lines**

```rust
// crates/skipper-api/src/routes/mod.rs
mod agents;
mod budget;
mod channels;
mod hands;
mod health;
mod integrations;
mod misc;
mod network;
mod security;
mod settings;
mod skills;
mod workflows;

pub use agents::*;
pub use budget::*;
pub use channels::*;
pub use hands::*;
pub use health::*;
pub use integrations::*;
pub use misc::*;
pub use network::*;
pub use security::*;
pub use settings::*;
pub use skills::*;
pub use workflows::*;

// Shared types used across route modules
pub struct AppState { /* ... stays here ... */ }
```

**Step 5: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
git add crates/skipper-api/src/routes/
git commit -m "refactor(api): extract remaining routes, mod.rs is now ~50 lines"
```

---

### Task 11: Decompose kernel.rs — Create Module Structure

**Files:**

- Create: `crates/skipper-kernel/src/kernel/mod.rs`
- Modify: existing kernel references

**Step 1: Create the kernel directory and copy**

```bash
mkdir -p crates/skipper-kernel/src/kernel
cp crates/skipper-kernel/src/kernel.rs crates/skipper-kernel/src/kernel/mod.rs
rm crates/skipper-kernel/src/kernel.rs
```

**Step 2: Verify**

```bash
cargo build --workspace --lib && cargo test --workspace
```

**Step 3: Commit**

```bash
git add -A crates/skipper-kernel/src/kernel/ crates/skipper-kernel/src/kernel.rs
git commit -m "refactor(kernel): convert kernel.rs to kernel/ module directory"
```

---

### Task 12: Extract Kernel Agent Lifecycle

**Files:**

- Create: `crates/skipper-kernel/src/kernel/agents.rs`
- Modify: `crates/skipper-kernel/src/kernel/mod.rs`

**Step 1: Create agents.rs**

Move from the `impl SkipperKernel` block:

- `spawn_agent` (~971)
- `spawn_agent_with_parent` (~976)
- `verify_signed_manifest` (~1109)
- `kill_agent` (~2553)
- Agent-related helpers: `manifest_to_capabilities` (~4205), `infer_provider_from_model` (~4279)

These methods stay as `impl SkipperKernel` methods but in the new file:

```rust
// crates/skipper-kernel/src/kernel/agents.rs
use super::*;

impl SkipperKernel {
    // moved methods here
}
```

**Step 2: In mod.rs, add `mod agents;`**

No `pub use` needed — the methods are on `SkipperKernel` which is defined in mod.rs.

**Step 3: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
git add crates/skipper-kernel/src/kernel/
git commit -m "refactor(kernel): extract agent lifecycle to kernel/agents.rs"
```

---

### Task 13: Extract Kernel Messaging

**Files:**

- Create: `crates/skipper-kernel/src/kernel/messaging.rs`
- Modify: `crates/skipper-kernel/src/kernel/mod.rs`

**Step 1: Create messaging.rs**

Move from `impl SkipperKernel`:

- `send_message` (~1130)
- `send_message_with_handle` (~1145)
- `send_message_streaming` (~1218) — 401 lines, the largest method
- `execute_wasm_agent` (~1619)
- `execute_python_agent` (~1700)
- `execute_llm_agent` (~1758) — 311 lines

**Step 2: Add `mod messaging;` to mod.rs**

**Step 3: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
git add crates/skipper-kernel/src/kernel/
git commit -m "refactor(kernel): extract messaging to kernel/messaging.rs"
```

---

### Task 14: Extract Kernel Sessions, Config, Hands

**Files:**

- Create: `crates/skipper-kernel/src/kernel/sessions.rs`
- Create: `crates/skipper-kernel/src/kernel/config.rs`
- Create: `crates/skipper-kernel/src/kernel/hands.rs`
- Modify: `crates/skipper-kernel/src/kernel/mod.rs`

**Step 1: Create sessions.rs**

Move: `reset_session`, `list_agent_sessions`, `create_agent_session`, `switch_agent_session`, `save_session_summary`, `compact_agent_session`, `context_report`, `stop_agent_run`

**Step 2: Create config.rs**

Move: `set_agent_model`, `set_agent_skills`, `set_agent_mcp_servers`, `session_usage_cost`, `reload_config`, `apply_hot_actions`, `list_bindings`, `add_binding`, `remove_binding`

**Step 3: Create hands.rs**

Move: `activate_hand`, `deactivate_hand`, `pause_hand`, `resume_hand`

**Step 4: Add module declarations to mod.rs**

**Step 5: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
git add crates/skipper-kernel/src/kernel/
git commit -m "refactor(kernel): extract sessions, config, hands to separate modules"
```

---

### Task 15: Extract Kernel Background, Networking, Tools

**Files:**

- Create: `crates/skipper-kernel/src/kernel/background.rs`
- Create: `crates/skipper-kernel/src/kernel/networking.rs`
- Create: `crates/skipper-kernel/src/kernel/tools.rs`
- Modify: `crates/skipper-kernel/src/kernel/mod.rs`

**Step 1: Create background.rs**

Move: `start_background_agents`, `start_heartbeat_monitor`, `start_background_for_agent`

**Step 2: Create networking.rs**

Move: `start_ofp_node`, `connect_mcp_servers`, `reload_extension_mcps`, `reconnect_extension_mcp`, `run_extension_health_loop`, `resolve_driver`

Also move the `impl PeerHandle for SkipperKernel` block (~4898-4964).

**Step 3: Create tools.rs**

Move: `available_tools`, `reload_skills`, `build_skill_summary`, `build_mcp_summary`, `collect_prompt_context`

**Step 4: Extract KernelHandle trait impl**

Create: `crates/skipper-kernel/src/kernel/handle_impl.rs`

Move the entire `impl KernelHandle for SkipperKernel` block (~4409-4893, 28 methods).

**Step 5: mod.rs should now contain only**

- `SkipperKernel` struct definition (~100 lines)
- `DeliveryTracker` struct + impl (~90 lines)
- `boot()` and `boot_with_config()` methods (~490 lines)
- `shutdown()` method (~40 lines)
- `set_self_handle()` and `self_arc()` helpers
- Free functions: `ensure_workspace`, `generate_identity_files`, `read_identity_file`, `gethostname`, `append_daily_memory_log`, `shared_memory_agent_id`
- Module declarations
- Tests

Total: ~800-900 lines. Down from 5,177.

**Step 6: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
git add crates/skipper-kernel/src/kernel/
git commit -m "refactor(kernel): extract background, networking, tools, KernelHandle impl"
```

---

### Task 16: Decompose tool_runner.rs — Create Module Structure

**Files:**

- Create: `crates/skipper-runtime/src/tools/mod.rs`
- Modify: `crates/skipper-runtime/src/lib.rs` or parent module

**Step 1: Create the tools directory and copy**

```bash
mkdir -p crates/skipper-runtime/src/tools
cp crates/skipper-runtime/src/tool_runner.rs crates/skipper-runtime/src/tools/mod.rs
rm crates/skipper-runtime/src/tool_runner.rs
```

**Step 2: Update any `mod tool_runner` to `mod tools`**

Check `crates/skipper-runtime/src/lib.rs` for `pub mod tool_runner;` and change to `pub mod tools;`. Also update the re-export path.

Search for `use skipper_runtime::tool_runner::` across the workspace and update to `use skipper_runtime::tools::`.

**Step 3: Verify**

```bash
cargo build --workspace --lib && cargo test --workspace
```

**Step 4: Commit**

```bash
git add -A crates/skipper-runtime/src/tools/ crates/skipper-runtime/src/tool_runner.rs crates/skipper-runtime/src/lib.rs
git add -A crates/  # catch any import path updates
git commit -m "refactor(runtime): convert tool_runner.rs to tools/ module directory"
```

**Note:** If the module rename causes too many import changes across the workspace, an alternative is to keep the file as `tool_runner.rs` but create a `tool_runner/` directory instead. The key is creating the module structure, not the name.

---

### Task 17: Extract Tool Implementations by Category

**Files:**

- Create: `crates/skipper-runtime/src/tools/filesystem.rs`
- Create: `crates/skipper-runtime/src/tools/web.rs`
- Create: `crates/skipper-runtime/src/tools/shell.rs`
- Create: `crates/skipper-runtime/src/tools/agents.rs`
- Create: `crates/skipper-runtime/src/tools/media.rs`
- Create: `crates/skipper-runtime/src/tools/browser.rs`
- Create: `crates/skipper-runtime/src/tools/collaboration.rs`
- Modify: `crates/skipper-runtime/src/tools/mod.rs`

**Step 1: Create filesystem.rs**

Move: `validate_path`, `resolve_file_path`, `tool_file_read`, `tool_file_write`, `tool_file_list`, `tool_apply_patch`

**Step 2: Create web.rs**

Move: `tool_web_fetch_legacy`, `tool_web_search_legacy`

**Step 3: Create shell.rs**

Move: `tool_shell_exec`

**Step 4: Create agents.rs**

Move: `require_kernel`, `tool_agent_send`, `tool_agent_spawn`, `tool_agent_list`, `tool_agent_kill`, `tool_memory_store`, `tool_memory_recall`, `tool_agent_find`

**Step 5: Create media.rs**

Move: `tool_image_analyze`, `detect_image_format`, `extract_image_dimensions`, `extract_jpeg_dimensions`, `format_file_size`, `tool_media_describe`, `tool_media_transcribe`, `tool_image_generate`, `tool_text_to_speech`, `tool_speech_to_text`

**Step 6: Create browser.rs**

Move: all `browser_*` tool functions + `tool_canvas_present`, `sanitize_canvas_html`

**Step 7: Create collaboration.rs**

Move: `tool_task_post`, `tool_task_claim`, `tool_task_complete`, `tool_task_list`, `tool_event_publish`, knowledge graph tools, scheduling tools, cron tools, channel tools, hand tools, A2A tools, process management tools, docker tool, location tool

**Step 8: mod.rs should now contain only**

- `execute_tool()` dispatch function (~350 lines)
- `builtin_tool_definitions()` (~670 lines)
- Security helpers: `check_taint_shell_exec`, `check_taint_net_fetch`
- Task-local state: `AGENT_CALL_DEPTH`, `CANVAS_MAX_BYTES`
- Module declarations + `pub use`

Total: ~1,100 lines. Down from 3,625.

**Step 9: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
git add crates/skipper-runtime/src/tools/
git commit -m "refactor(runtime): extract tool implementations into domain modules"
```

---

### Task 18: Decompose config.rs — Create Module Structure

**Files:**

- Create: `crates/skipper-types/src/config/mod.rs`
- Modify: `crates/skipper-types/src/lib.rs`

**Step 1: Create the config directory and copy**

```bash
mkdir -p crates/skipper-types/src/config
cp crates/skipper-types/src/config.rs crates/skipper-types/src/config/mod.rs
rm crates/skipper-types/src/config.rs
```

**Step 2: Verify**

```bash
cargo build --workspace --lib && cargo test --workspace
```

**Step 3: Commit**

```bash
git add -A crates/skipper-types/src/config/ crates/skipper-types/src/config.rs
git commit -m "refactor(types): convert config.rs to config/ module directory"
```

---

### Task 19: Extract Config Types by Domain

**Files:**

- Create: `crates/skipper-types/src/config/channels.rs`
- Create: `crates/skipper-types/src/config/models.rs`
- Create: `crates/skipper-types/src/config/budget.rs`
- Modify: `crates/skipper-types/src/config/mod.rs`

**Step 1: Identify the domain boundaries**

Read through config/mod.rs and identify:

- Channel-specific config structs (per-provider configs for Telegram, Discord, Slack, etc.)
- Model/provider config structs
- Budget/cost config structs
- Core `KernelConfig` struct and shared types stay in mod.rs

**Step 2: Extract channel configs to channels.rs**

Move all channel-specific structs (e.g., `TelegramConfig`, `DiscordConfig`, `SlackConfig`, `ChannelsConfig`, etc.) to `channels.rs`.

**Step 3: Extract model configs to models.rs**

Move model/provider structs to `models.rs`.

**Step 4: Extract budget configs to budget.rs**

Move budget-related structs to `budget.rs`.

**Step 5: mod.rs keeps core types**

`KernelConfig`, shared enums, `Default` impl. Re-exports sub-module types.

**Step 6: Verify and commit**

```bash
cargo build --workspace --lib && cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
git add crates/skipper-types/src/config/
git commit -m "refactor(types): extract config types into domain modules"
```

---

### Task 20: Decompose main.rs (CLI) — Create Module Structure

**Files:**

- Create: `crates/skipper-cli/src/commands/mod.rs`
- Modify: `crates/skipper-cli/src/main.rs`

**Step 1: Create commands directory**

```bash
mkdir -p crates/skipper-cli/src/commands
```

**Step 2: Identify command groups in main.rs**

Read through main.rs and identify the match arms in the main dispatch function. Group by:

- Agent commands (spawn, list, kill, message)
- Hand commands (install, list, activate)
- Skill commands (create, list, install)
- Config commands (get, set, show)
- Channel commands (list, configure, test)
- Auth commands (login, register)
- Daemon commands (start, stop)
- Other commands

**Step 3: Extract each command group**

For each group, create a file (e.g., `commands/agent.rs`) and move the command handler functions there. Keep `main()` as a thin dispatcher.

**Step 4: Verify after each extraction**

```bash
cargo build --workspace --lib && cargo test --workspace
```

**Step 5: Final commit**

```bash
git add crates/skipper-cli/src/commands/ crates/skipper-cli/src/main.rs
git commit -m "refactor(cli): extract command handlers into commands/ module"
```

---

### Task 21: Final Verification & Cleanup

**Step 1: Full build and test**

```bash
cargo build --workspace --lib
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

**Step 2: Verify no god-files remain**

Check that no file exceeds ~1,500 lines:

```bash
find crates -name "*.rs" | xargs wc -l | sort -rn | head -20
```

Expected: The top files should be under 1,500 lines (except test files and `builtin_tool_definitions` which is a large data function).

**Step 3: Verify line count reduction**

| File           | Before | After (mod.rs) | Extracted To    |
| -------------- | ------ | -------------- | --------------- |
| routes.rs      | 8,983  | ~50            | 12 domain files |
| kernel.rs      | 5,177  | ~900           | 7 domain files  |
| tool_runner.rs | 3,625  | ~1,100         | 7 domain files  |
| config.rs      | 3,579  | ~1,000         | 3 domain files  |
| main.rs        | 5,671  | ~200           | 8 command files |

**Step 4: Commit if any cleanup needed**

```bash
git add -A crates/
git commit -m "refactor: final cleanup after clean architecture decomposition"
```
