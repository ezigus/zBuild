# Stream 2: Deep Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task.

**Goal:** Wire 8 skipper-shipwright tools to call real Shipwright bash scripts instead of in-memory stubs. Enable Skipper agents to execute full delivery pipelines, access persistent memory, read fleet/daemon state, and leverage intelligence analysis.

**Architecture:** Tools spawn subprocess calls to Shipwright bash scripts (`sw-pipeline.sh`, `sw-decide.sh`, `sw-intelligence.sh`, etc.) using `tokio::process::Command`. Results are parsed as JSON and cached. Graceful fallback to in-memory stubs if bash is unavailable.

**Tech Stack:** Rust (tokio, serde_json), bash scripts (existing), feature gates (`shipwright-integration`), subprocess monitoring, file I/O for memory/fleet state.

---

## Phase 1: Foundation — Subprocess & File Bridges (Tasks 1–7)

### Task 1: Create subprocess.rs — Bash script spawning harness

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/subprocess.rs`

- [ ] Create empty file with module doc comment
- [ ] Import: `tokio::process::Command`, `std::time::Duration`, `Result<String, String>`, `tracing`
- [ ] Define `pub struct BashRunner`:
  - `shipwright_scripts_dir: PathBuf` (from env var or config, default `~/.shipwright/scripts`)
  - `timeout_seconds: u64` (default 300)
  - `enable_caching: bool`
  - `cache_dir: PathBuf` (default `~/.shipwright/subprocess-cache`)
- [ ] Define `pub enum BashError`:
  - `ScriptNotFound(String)` — script file missing
  - `ExecutionFailed(i32, String)` — non-zero exit with stderr
  - `Timeout` — exceeded timeout_seconds
  - `JsonParse(String)` — invalid JSON in stdout
  - `IoError(String)`
- [ ] Implement `impl BashRunner`:
  - `pub fn new() -> Self` — use defaults
  - `pub fn with_dir(dir: PathBuf) -> Self` — explicit script dir
  - `pub fn with_timeout(mut self, seconds: u64) -> Self` — fluent builder
  - `pub async fn run(&self, script_name: &str, args: Vec<&str>) -> Result<String, BashError>` — spawn subprocess
    - Check script exists at `scripts_dir/{script_name}`
    - Build Command with script path and args
    - Set timeout via `tokio::time::timeout`
    - Capture stdout + stderr
    - Parse stdout as JSON (validate with `serde_json::from_str`)
    - Return `Ok(stdout_json_string)` or `Err(BashError)`
  - `async fn run_with_cache(...)` — check cache dir for hash(script+args), use cached result if fresh (<1hr)
  - `pub async fn run_json<T: DeserializeOwned>(&self, script: &str, args: Vec<&str>) -> Result<T, BashError>` — deserialize result directly

**Tests:**

```bash
# Unit test: BashRunner::new() constructs defaults
# Unit test: run() fails if script not found
# Unit test: run() fails with ExecutionFailed on non-zero exit
# Unit test: run() parses JSON from stdout
```

**Commit:** `git add src/subprocess.rs && git commit -m "feat(subprocess): bash script spawning harness"`

---

### Task 2: Create memory_bridge.rs — Real memory file I/O

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/memory_bridge.rs`

- [ ] Create file with module doc
- [ ] Import: `std::fs`, `std::path::{Path, PathBuf}`, `serde_json::{json, Value}`, `tokio::fs::{File, read_to_string, write}`, `Result<T, String>`
- [ ] Define `pub struct MemoryBridge`:
  - `memory_root: PathBuf` (default `~/.shipwright/memory`)
  - `repo_hash: String` (repo name or hash for scoped storage)
- [ ] Implement `impl MemoryBridge`:
  - `pub fn new(repo: &str) -> Self` — compute repo_hash and set paths
  - `pub async fn store_failure(&self, pattern: FailurePattern) -> Result<(), String>`
    - Create `memory_root/{repo_hash}/failures/` if not exists
    - Write pattern as JSON to `failures/{error_class}_{timestamp}.json`
    - Return `Ok(())`
  - `pub async fn search_failures(&self, query: &str, limit: usize) -> Result<Vec<FailurePattern>, String>`
    - Scan `memory_root/{repo_hash}/failures/` for all JSON files
    - Deserialize each to FailurePattern
    - Filter by query substring (error_signature or root_cause contains query)
    - Return top `limit` by recency
  - `pub async fn load_learning_metadata(&self) -> Result<Value, String>`
    - Read `memory_root/{repo_hash}/learning.json` if exists
    - Return empty object `{}` if not found
  - `pub async fn store_learning_metadata(&self, metadata: &Value) -> Result<(), String>`
    - Write to `memory_root/{repo_hash}/learning.json`
    - Atomic write: temp file + rename

**Tests:**

```bash
# Unit test: store_failure() creates directories
# Unit test: search_failures() returns sorted by recency
# Unit test: search_failures() filters by query
# Unit test: concurrent reads don't block writes
```

**Commit:** `git add src/memory_bridge.rs && git commit -m "feat(memory): real filesystem memory bridge"`

---

### Task 3: Create fleet_bridge.rs — Read daemon/fleet state

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/fleet_bridge.rs`

- [ ] Create file with module doc
- [ ] Import: `std::fs`, `serde_json::{json, Value}`, `tokio::fs::read_to_string`, `Result<T, String>`
- [ ] Define `pub struct FleetBridge`:
  - `config_path: PathBuf` (default `~/.shipwright/fleet-config.json`)
  - `daemon_state_path: PathBuf` (default `.claude/daemon-state.json` in repo)
  - `costs_path: PathBuf` (default `~/.shipwright/costs.json`)
- [ ] Implement `impl FleetBridge`:
  - `pub fn new() -> Self` — set defaults
  - `pub async fn load_fleet_config(&self) -> Result<Value, String>`
    - Read `config_path` if exists
    - Return `{}` if missing (daemon not configured)
  - `pub async fn load_daemon_state(&self) -> Result<Value, String>`
    - Read `daemon_state_path` if exists in current repo
    - Return `{"status": "not_running"}` if missing
  - `pub async fn load_costs(&self) -> Result<Value, String>`
    - Read `costs_path` if exists (dict of {repo: cost_usd})
    - Return `{}` if missing
  - `pub async fn get_fleet_status(&self) -> Result<Value, String>` — aggregate:
    - Load fleet config, daemon state, costs
    - Return object: `{active_pipelines, queued_issues, workers, repos: [{name, status, cost}]}`

**Tests:**

```bash
# Unit test: load_fleet_config() returns empty object if missing
# Unit test: get_fleet_status() aggregates config + state + costs
```

**Commit:** `git add src/fleet_bridge.rs && git commit -m "feat(fleet): read real daemon and fleet state"`

---

### Task 4: Wire subprocess.rs into tools.rs — dispatch_subprocess()

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

- [ ] Add `mod subprocess;` and `mod memory_bridge;` and `mod fleet_bridge;` to top
- [ ] Add imports: `use crate::subprocess::{BashRunner, BashError};`
- [ ] Update `ShipwrightState` struct to include:
  - `bash_runner: Arc<BashRunner>` — spawned once at kernel boot
  - `memory_bridge: Arc<MemoryBridge>` — one per repo
- [ ] Implement `ShipwrightState::new_with_bridges(repo: &str) -> Self` constructor
  - Initialize `bash_runner = Arc::new(BashRunner::new())`
  - Initialize `memory_bridge = Arc::new(MemoryBridge::new(repo))`
- [ ] Add helper: `pub async fn dispatch_subprocess(&self, script: &str, args: Vec<&str>) -> Result<String, BashError>`
  - Call `self.bash_runner.run_json(script, args).await`
  - Return result as JSON string or error

**Tests:**

```bash
# Unit test: ShipwrightState::new_with_bridges() initializes bridges
# Integration test: dispatch_subprocess() calls bash runner
```

**Commit:** `git add src/tools.rs && git commit -m "feat(tools): wire subprocess bridges into ShipwrightState"`

---

### Task 5: Implement pipeline_start tool — spawn real sw-pipeline.sh

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

Replace stub `fn pipeline_start(input, state) -> Result<String, String>`:

- [ ] Extract params: `goal`, `issue_number`, `template`, `repo_path`
- [ ] Build bash args: `["--goal", goal, "--template", template]` (or `--issue` variant)
- [ ] Call: `state.dispatch_subprocess("sw-pipeline.sh", args).await`
- [ ] On success:
  - Parse JSON result
  - Extract pipeline_id from stdout
  - Store pipeline record in `state.pipelines` (in-memory for quick status checks)
  - Return JSON with `pipeline_id`, `status: "started"`, `created_at`
- [ ] On error:
  - If `BashError::ScriptNotFound`, fall back to in-memory stub
  - If `BashError::Timeout`, return `{"error": "pipeline_startup_timeout"}`
  - Otherwise return bash error message

**Note:** Make this async by changing dispatch signature.

**Tests:**

```bash
# Mock test: succeeds when sw-pipeline.sh returns valid JSON
# Mock test: falls back to in-memory stub when script not found
# Mock test: returns timeout error on subprocess timeout
```

**Commit:** `git add src/tools.rs && git commit -m "feat(tools): pipeline_start calls real sw-pipeline.sh"`

---

### Task 6: Implement pipeline_status tool — read .claude/pipeline-state.md + subprocess

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

Replace stub `fn pipeline_status(input, state)`:

- [ ] Extract: `pipeline_id` (or use most recent)
- [ ] Check `state.pipelines` in-memory cache first (fast path)
- [ ] If not cached, call: `state.dispatch_subprocess("sw-pipeline.sh", ["status", "--id", pipeline_id]).await`
- [ ] Parse result and return:
  - `pipeline_id`, `goal`, `template`, `current_stage`, `stage_progress`, `iteration_count`, `test_status`
  - If available: `created_at`, `started_at`, `estimated_completion`
- [ ] On error: return best-effort result from in-memory cache

**Tests:**

```bash
# Unit test: returns cached pipeline status if in memory
# Mock test: calls subprocess for live status
```

**Commit:** `git add src/tools.rs && git commit -m "feat(tools): pipeline_status reads real pipeline state"`

---

### Task 7: Implement decision_run tool — call real sw-decide.sh

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

Replace stub `fn decision_run(input)`:

- [ ] Extract: `dry_run`, `signal_filter` (optional)
- [ ] Build bash args: `["--dry-run"]` (if dry_run=true) or `[]`
- [ ] If signal_filter provided, add: `["--signal", signal_filter]`
- [ ] Call: `state.dispatch_subprocess("sw-decide.sh", args).await`
- [ ] Parse and return:
  - `dry_run`, `candidates: [{issue, score, signals}]`, `recommended_template`, `confidence`
- [ ] On error: return `{"dry_run": true, "candidates": [], "message": "decision engine unavailable"}`

**Tests:**

```bash
# Mock test: calls sw-decide.sh and returns candidates
# Mock test: falls back to empty candidates if script unavailable
```

**Commit:** `git add src/tools.rs && git commit -m "feat(tools): decision_run calls real sw-decide.sh"`

---

## Phase 2: Memory & Intelligence (Tasks 8–11)

### Task 8: Implement memory_search tool — use MemoryBridge

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

Replace stub `fn memory_search(input, state)`:

- [ ] Extract: `query`, `repo`, `limit` (default 10)
- [ ] Call: `state.memory_bridge.search_failures(&query, limit).await`
- [ ] Format and return:
  - `query`, `repo`, `results_count`, `results: [{error_class, error_signature, root_cause, fix_applied, stage}]`
- [ ] On error: return `{"results": [], "error": "memory store unavailable"}`

**Tests:**

```bash
# Unit test: searches memory bridge and returns results
# Unit test: returns empty results if no matches
```

**Commit:** `git add src/tools.rs && git commit -m "feat(tools): memory_search uses real memory bridge"`

---

### Task 9: Implement memory_store tool — use MemoryBridge

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

Replace stub `fn memory_store_pattern(input, state)`:

- [ ] Extract: `repo`, `error_class`, `error_signature`, `root_cause`, `fix_applied`, `stage` (optional)
- [ ] Convert to `FailurePattern` struct
- [ ] Call: `state.memory_bridge.store_failure(pattern).await`
- [ ] Return: `{"stored": true, "repo": repo, "error_class": error_class}`
- [ ] On error: return `{"stored": false, "error": "..."}`

**Tests:**

```bash
# Unit test: stores pattern in memory bridge
# Unit test: returns error if pattern invalid
```

**Commit:** `git add src/tools.rs && git commit -m "feat(tools): memory_store uses real memory bridge"`

---

### Task 10: Implement intelligence tool — call real sw-intelligence.sh

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

Replace stub `fn intelligence(input)`:

- [ ] Extract: `analysis_type` (dora, risk, optimize), `repo_path` (optional)
- [ ] Build bash args: `["analyze", "--type", analysis_type]`
- [ ] Call: `state.dispatch_subprocess("sw-intelligence.sh", args).await`
- [ ] Parse and return:
  - For `dora`: `{lead_time_hours, deploy_frequency, change_failure_rate, mttr_hours, classification}`
  - For `risk`: `{hotspots: [{file, churn_count, risk_score}]}`
  - For `optimize`: `{suggestions: [{type, rationale}]}`
- [ ] On error: return stub metrics

**Tests:**

```bash
# Mock test: calls sw-intelligence.sh for dora analysis
# Mock test: returns hotspots for risk analysis
# Mock test: falls back to defaults if script unavailable
```

**Commit:** `git add src/tools.rs && git commit -m "feat(tools): intelligence calls real sw-intelligence.sh"`

---

### Task 11: Implement fleet_status tool — use FleetBridge

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

Replace stub `fn fleet_status(state)`:

- [ ] Create: `fleet_bridge = FleetBridge::new()`
- [ ] Call: `fleet_bridge.get_fleet_status().await`
- [ ] Return aggregated JSON:
  - `active_pipelines`, `queued_issues`, `total_workers`, `available_workers`, `total_cost_usd`
  - `repos: [{name, active_pipelines, queued_issues, workers_allocated, cost_usd}]`
- [ ] On error: return minimal valid status with zeros

**Tests:**

```bash
# Unit test: aggregates fleet config + state + costs
# Unit test: returns empty repos list if no fleet config
```

**Commit:** `git add src/tools.rs && git commit -m "feat(tools): fleet_status reads real fleet state"`

---

## Phase 3: Async & Testing (Tasks 12–16)

### Task 12: Make dispatch() async — convert tool handlers

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

- [ ] Change dispatch signature: `pub async fn dispatch(tool_name: &str, input: &Value, state: &ShipwrightState) -> Result<String, String>`
- [ ] Convert all tool handler functions to async:
  - Add `pub async fn pipeline_start(...)`
  - Add `pub async fn pipeline_status(...)`
  - Add `pub async fn decision_run(...)`
  - Add `pub async fn memory_search(...)`
  - Add `pub async fn memory_store_pattern(...)`
  - Add `pub async fn fleet_status(...)`
  - Add `pub async fn intelligence(...)`
- [ ] Add `.await` calls to all subprocess/bridge calls
- [ ] Update dispatch() match statement to `.await` each handler

**Tests:**

```bash
# Integration test: dispatch() correctly awaits async handlers
```

**Commit:** `git add src/tools.rs && git commit -m "feat(tools): make all handlers async for subprocess calls"`

---

### Task 13: Update tool_runner integration — async dispatch in skipper-runtime

**File:** `crates/skipper-runtime/src/tools/shipwright.rs` (or appropriate location)

- [ ] Check if feature gate `shipwright-integration` exists (add to Cargo.toml if not)
- [ ] Find where `dispatch()` is called from tool_runner
- [ ] Wrap dispatch in `tokio::spawn_blocking()` or update handler to be async
- [ ] If runtime is async (likely), change tool handler to:
  ```rust
  pub async fn handle_tool(name: &str, input: &Value, state: &Arc<ShipwrightState>) -> ToolResult {
      match dispatch(name, input, state).await {
          Ok(result) => ToolResult::success(result),
          Err(e) => ToolResult::error(e),
      }
  }
  ```

**Tests:**

```bash
# Integration test: tool_runner calls async dispatch and gets result
```

**Commit:** `git add crates/skipper-runtime && git commit -m "feat(runtime): wire async dispatch to tool_runner"`

---

### Task 14: Create unit tests for subprocess.rs

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/subprocess.rs` (bottom)

- [ ] Test module: `#[cfg(test)] mod tests`
- [ ] Test: `new()` initializes with defaults
- [ ] Test: `with_timeout()` builder sets timeout
- [ ] Test: `run()` fails if script not found → `BashError::ScriptNotFound`
- [ ] Test: `run()` captures stdout and parses JSON
- [ ] Test: `run()` on non-zero exit → `BashError::ExecutionFailed`
- [ ] Test: timeout behavior with slow script

Run:

```bash
cargo test --lib skipper-shipwright::subprocess -- --nocapture
```

**Commit:** `git add src/subprocess.rs && git commit -m "test(subprocess): add unit tests"`

---

### Task 15: Create unit tests for memory_bridge.rs

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/memory_bridge.rs` (bottom)

- [ ] Test module: `#[cfg(test)] mod tests`
- [ ] Test: `store_failure()` creates directories
- [ ] Test: `search_failures()` returns sorted by recency
- [ ] Test: `search_failures()` filters by query
- [ ] Test: `load_learning_metadata()` returns empty object if missing
- [ ] Test: `store_learning_metadata()` persists to disk

Run:

```bash
cargo test --lib skipper-shipwright::memory_bridge -- --nocapture
```

**Commit:** `git add src/memory_bridge.rs && git commit -m "test(memory): add unit tests"`

---

### Task 16: Create unit tests for fleet_bridge.rs

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/fleet_bridge.rs` (bottom)

- [ ] Test module: `#[cfg(test)] mod tests`
- [ ] Test: `load_fleet_config()` returns empty object if missing
- [ ] Test: `load_daemon_state()` returns empty object if missing
- [ ] Test: `load_costs()` reads costs.json
- [ ] Test: `get_fleet_status()` aggregates all three

Run:

```bash
cargo test --lib skipper-shipwright::fleet_bridge -- --nocapture
```

**Commit:** `git add src/fleet_bridge.rs && git commit -m "test(fleet): add unit tests"`

---

## Phase 4: Integration & API Routes (Tasks 17–20)

### Task 17: Create crates/skipper-api/src/routes/pipelines.rs

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-api/src/routes/pipelines.rs`

- [ ] Create file with route handlers
- [ ] Import: `axum::{extract::*, response::IntoResponse, Router}`, `AppState`, `ShipwrightState`
- [ ] Define routes:
  - `POST /api/pipelines/start` → `start_pipeline_handler()`
    - Extract: `goal`, `issue_number`, `template`
    - Call: `dispatch("shipwright_pipeline_start", input, state).await`
    - Return: `Json(response)`
  - `GET /api/pipelines/:id/status` → `get_pipeline_status_handler()`
    - Extract: `id` path param
    - Call: `dispatch("shipwright_pipeline_status", input, state).await`
    - Return: `Json(response)`
  - `POST /api/pipelines/:id/advance` → `advance_pipeline_handler()`
    - Call: `dispatch("shipwright_stage_advance", input, state).await`
- [ ] Export: `pub fn pipeline_routes() -> Router`

**Tests:**

```bash
# Integration test: POST /api/pipelines/start returns pipeline_id
# Integration test: GET /api/pipelines/{id}/status returns status
```

**Commit:** `git add crates/skipper-api/src/routes/pipelines.rs && git commit -m "feat(api): add pipeline status routes"`

---

### Task 18: Register pipelines routes in skipper-api/src/routes/mod.rs

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-api/src/routes/mod.rs`

- [ ] Add: `mod pipelines;`
- [ ] Add: `pub use pipelines::pipeline_routes;`
- [ ] In the router builder function, add: `.nest("/api", pipeline_routes())`
      (or merge with existing route tree)

**Commit:** `git add crates/skipper-api && git commit -m "feat(api): register pipeline routes"`

---

### Task 19: Add feature gate for shipwright-integration

**File:** `/Users/sethford/Documents/shipwright/skipper/Cargo.toml`

- [ ] In workspace config (if exists) or crate config, add:
  ```toml
  [features]
  shipwright-integration = ["skipper-shipwright"]
  ```
- [ ] In build script or documentation, note that:
  - Feature `shipwright-integration` enables Shipwright tools
  - Default: disabled (uses in-memory stubs)
  - Enable with: `cargo build --features shipwright-integration`
  - For daemon: `CARGO_FEATURES=shipwright-integration cargo build --release`

**Commit:** `git add Cargo.toml && git commit -m "feat: add shipwright-integration feature gate"`

---

### Task 20: Create integration test — test all tools end-to-end

**File:** `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/tests/integration_test.rs`

- [ ] Create file
- [ ] Test: `pipeline_start_and_status()`
  - Call dispatch("shipwright_pipeline_start", {"goal": "test"}, state)
  - Verify response has pipeline_id
  - Call dispatch("shipwright_pipeline_status", {"pipeline_id": id}, state)
  - Verify status includes current_stage
- [ ] Test: `decision_run()`
  - Call dispatch("shipwright_decision_run", {}, state)
  - Verify response has candidates or recommendation
- [ ] Test: `memory_store_and_search()`
  - Call dispatch("shipwright_memory_store", {repo, error_class, ...}, state)
  - Verify stored: true
  - Call dispatch("shipwright_memory_search", {repo, query}, state)
  - Verify results_count > 0
- [ ] Test: `fleet_status()`
  - Call dispatch("shipwright_fleet_status", {}, state)
  - Verify has active_pipelines, repos list
- [ ] Test: `intelligence()`
  - Call dispatch("shipwright_intelligence", {analysis_type: "dora"}, state)
  - Verify has metrics

Run:

```bash
cargo test --test integration_test -- --nocapture
```

**Commit:** `git add tests/integration_test.rs && git commit -m "test(integration): end-to-end tool tests"`

---

## Phase 5: Verification & Documentation (Tasks 21–24)

### Task 21: Build and test all changes

**No file changes** — just run verification commands

- [ ] Run: `cargo build --workspace --lib`
  - Should compile with no errors
  - Note: may need to update Cargo.toml dependencies if needed
- [ ] Run: `cargo test --workspace`
  - All existing tests should pass (2190+)
  - New tests added in Tasks 14–20 should pass
- [ ] Run: `cargo clippy --workspace --all-targets -- -D warnings`
  - Zero clippy warnings

If any test fails:

1. Read the error message carefully
2. Check if it's due to missing async `.await`
3. Check if subprocess/bridge logic has a bug
4. Fix and re-test

**Commit:** `git add . && git commit -m "build: verify all tests pass, no clippy warnings"`

---

### Task 22: Live integration test against real Shipwright bash scripts

**Manual testing** — run daemon and test tools against actual scripts

- [ ] Start Skipper daemon:
  ```bash
  cargo build --release -p skipper-cli --features shipwright-integration
  GROQ_API_KEY=<key> target/release/skipper.exe start &
  sleep 6
  ```
- [ ] Check health:
  ```bash
  curl http://127.0.0.1:4200/api/health
  ```
- [ ] Test pipeline_start:
  ```bash
  curl -X POST http://127.0.0.1:4200/api/pipelines/start \
    -H "Content-Type: application/json" \
    -d '{"goal": "Add login validation"}'
  ```

  - Should return `{"pipeline_id": "...", "status": "started"}`
- [ ] Test pipeline_status:
  ```bash
  curl http://127.0.0.1:4200/api/pipelines/{id}/status
  ```

  - Should return current stage, progress, etc.
- [ ] Test decision_run:
  ```bash
  curl -X POST http://127.0.0.1:4200/api/decisions/run \
    -H "Content-Type: application/json" \
    -d '{"dry_run": true}'
  ```

  - Should return candidates with scores
- [ ] Test memory_search:
  ```bash
  curl -X POST http://127.0.0.1:4200/api/memory/search \
    -H "Content-Type: application/json" \
    -d '{"repo": "myrepo", "query": "timeout"}'
  ```

  - Should return matching failure patterns
- [ ] Test fleet_status:
  ```bash
  curl http://127.0.0.1:4200/api/fleet/status
  ```

  - Should return worker allocation, repos, costs
- [ ] Verify subprocess.rs properly invokes bash scripts by watching Shipwright logs:
  ```bash
  tail -f ~/.shipwright/events.jsonl
  ```

If any test fails:

- [ ] Check that sw-\*.sh scripts exist in `~/.shipwright/scripts/`
- [ ] Check script permissions: `chmod +x ~/.shipwright/scripts/sw-*.sh`
- [ ] Manually run the script to verify it works: `~/.shipwright/scripts/sw-pipeline.sh --goal "test"`
- [ ] Check subprocess.rs error handling and logging

**Document:** Findings in a test report (informal, for reference)

**Commit:** `git add . && git commit -m "test(integration): verified tools against real Shipwright scripts"`

---

### Task 23: Update module docs

**Files:**

- `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/lib.rs`
- `/Users/sethford/Documents/shipwright/skipper/crates/skipper-shipwright/src/tools.rs`

- [ ] In `lib.rs`, update module-level doc comment to reflect:
  - Tools now call real bash scripts (subprocess)
  - Memory system reads real filesystem (memory_bridge)
  - Fleet status reads real daemon config (fleet_bridge)
  - Example: "Tools spawn `sw-pipeline.sh` subprocess for autonomous delivery"
- [ ] In `tools.rs`, add doc comments to each tool handler explaining:
  - Which bash script it calls
  - Parameters and return format
  - Fallback behavior if script unavailable
- [ ] Example snippet for `pipeline_start`:
  ```rust
  /// Starts a Shipwright delivery pipeline by spawning `sw-pipeline.sh`.
  ///
  /// Calls `$SHIPWRIGHT_SCRIPTS_DIR/sw-pipeline.sh --goal "..." --template "standard"`.
  /// Returns pipeline ID and initial status. Falls back to in-memory stub if script unavailable.
  async fn pipeline_start(input: &Value, state: &ShipwrightState) -> Result<String, String>
  ```

**Commit:** `git add src/lib.rs src/tools.rs && git commit -m "docs: update module docs for subprocess integration"`

---

### Task 24: Create IMPLEMENTATION_NOTES.md

**File:** `/Users/sethford/Documents/shipwright/docs/plans/STREAM-2-IMPLEMENTATION-NOTES.md`

Document for future reference:

````markdown
# Stream 2 Implementation Notes

## What Was Implemented

- **subprocess.rs**: Bash script spawning harness with timeout and caching
- **memory_bridge.rs**: Real filesystem memory I/O (read/write failure patterns)
- **fleet_bridge.rs**: Fleet config and daemon state aggregator
- **Async tools**: All 8 tools converted to async and wired to subprocess calls
- **API routes**: POST /pipelines/start, GET /pipelines/{id}/status, etc.
- **Feature gate**: `shipwright-integration` to toggle real vs in-memory

## How Tools Work

### pipeline_start

- Spawns: `sw-pipeline.sh --goal "..." --template "..."`
- Returns: `{pipeline_id, status: "started", created_at}`

### pipeline_status

- Spawns: `sw-pipeline.sh status --id {pipeline_id}`
- Returns: `{current_stage, progress, iteration, test_status}`

### decision_run

- Spawns: `sw-decide.sh --dry-run`
- Returns: `{candidates: [{issue, score, signals}], recommended_template}`

### memory_search

- Reads: `~/.shipwright/memory/{repo}/failures/`
- Returns: `{results: [{error_class, fix_applied, ...}]}`

### memory_store

- Writes: `~/.shipwright/memory/{repo}/failures/{error_class}_{timestamp}.json`
- Returns: `{stored: true}`

### fleet_status

- Reads: `~/.shipwright/fleet-config.json`, `.claude/daemon-state.json`, `~/.shipwright/costs.json`
- Returns: `{active_pipelines, repos: [{name, workers, cost}]}`

### intelligence

- Spawns: `sw-intelligence.sh analyze --type dora|risk|optimize`
- Returns: `{lead_time_hours, deploy_frequency, ...}` (varies by type)

## Graceful Fallbacks

All tools check if subprocess is available. If not (feature disabled or script missing):

- Return best-effort cached/in-memory result
- Log warning to tracing
- Do NOT fail hard — allow pipeline to continue with degraded capabilities

## Testing Strategy

- Unit tests: subprocess.rs, memory_bridge.rs, fleet_bridge.rs
- Integration tests: all tools together
- Live tests: against real Shipwright bash scripts and daemon

## Future: Dashboard Integration

Once this is complete, update skipper-api/src/dashboard.rs to:

- Show active pipelines with stage progress bars
- Show fleet status with worker allocation
- Show unified memory (Shipwright + Skipper) in search UI
- Wire Skipper memory to Shipwright bash scripts via memory_bridge

## Known Limitations

1. Subprocess timeout is fixed (300s) — may need tuning for long pipelines
2. Memory search is linear scan — consider adding SQLite index for large repos
3. Fleet state is eventually consistent — reads are point-in-time snapshots
4. Subprocess caching (1hr TTL) may hide real-time changes — disable for interactive use

## Debugging

Enable detailed logging:

```bash
RUST_LOG=debug cargo build --release -p skipper-cli
RUST_LOG=skipper_shipwright=debug target/release/skipper.exe start
```
````

Watch subprocess calls:

```bash
tail -f ~/.shipwright/events.jsonl
```

Check subprocess cache:

```bash
ls -la ~/.shipwright/subprocess-cache/
```

```

**Commit:** `git add docs/plans && git commit -m "docs: add Stream 2 implementation notes"`

---

## Success Criteria Checklist

- [ ] All 5 new files created and compile without errors
- [ ] All 7 tool handlers converted to async and call real bash scripts
- [ ] All subprocess calls have graceful fallback to in-memory stubs
- [ ] All 3 file bridges (subprocess, memory, fleet) have unit tests with >90% coverage
- [ ] Integration test covers all 8 tools end-to-end
- [ ] Live integration test passes against real Shipwright scripts
- [ ] `cargo test --workspace` passes with 0 failures
- [ ] `cargo clippy --workspace --all-targets -- -D warnings` returns 0 warnings
- [ ] API routes registered and tested via HTTP
- [ ] Feature gate `shipwright-integration` toggles between real and in-memory
- [ ] Documentation updated with subprocess details
- [ ] All commits follow conventional commit format

---

## Estimated Effort

| Phase    | Tasks | Estimated Hours |
|----------|-------|-----------------|
| Phase 1  | 1–7   | 12–16 hours     |
| Phase 2  | 8–11  | 6–8 hours       |
| Phase 3  | 12–16 | 8–10 hours      |
| Phase 4  | 17–20 | 6–8 hours       |
| Phase 5  | 21–24 | 4–6 hours       |
| **Total**|       | **36–48 hours** |

---

## Merge and Next Steps

Once all tasks pass:

1. **Merge this branch** into `main` (after Stream 1: Clean Architecture is merged)
2. **Open PR** with:
   - Title: `feat: Stream 2 — Deep Integration (Shipwright tools → real bash scripts)`
   - Description: This plan doc + link to unified-platform-design.md
   - 20+ commits (one per task)
3. **Request review** from team lead (verify subprocess safety, error handling)
4. **After merge**, Stream 3 (Claude Code + bash cleanup) can proceed in parallel

---

## Notes for Executors

- Use `/fast` mode in Claude Code to speed up code generation
- For each subprocess.rs feature, write a unit test first (TDD), then implementation
- When async becomes complex, use `tokio::task::spawn_blocking()` for fallbacks
- Memory_bridge should be atomic (temp file + rename) to avoid corruption
- Fleet_bridge reads are best-effort (no locking) — OK for occasional stale reads
- If subprocess timeout is too tight, increase from 300s in config
- Test with `RUST_LOG=debug` to see all subprocess invocations
- Keep shell invocations simple: avoid pipes, use script exit codes for errors
```
