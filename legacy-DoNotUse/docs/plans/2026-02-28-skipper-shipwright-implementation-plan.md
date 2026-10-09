# Skipper-Shipwright Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Port Shipwright's complete autonomous software delivery system into a single `skipper-shipwright` crate within a fork of Skipper, creating a "Software Engineering Hand."

**Architecture:** Single Rust crate (`skipper-shipwright`) added to Skipper's Cargo workspace. Contains 7 modules (pipeline, decision, memory, fleet, github, intelligence, config) plus Hand definition files. Integrates with Skipper's kernel for scheduling/RBAC/metering, memory crate for vector search, and channels for notifications.

**Tech Stack:** Rust 1.75+, tokio async, serde/toml for config, reqwest for GitHub API, rusqlite for persistence, axum for API routes, clap for CLI, thiserror for errors.

**Design Doc:** `docs/plans/2026-02-28-skipper-shipwright-integration-design.md`

---

## Prerequisites

Before starting, complete these one-time setup steps:

```bash
# 1. Fork Skipper
gh repo fork RightNow-AI/skipper --clone --remote

# 2. Verify build
cd skipper
cargo build --workspace --lib
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings

# 3. Create feature branch
git checkout -b feat/shipwright-hand
```

---

## Task 1: Scaffold Crate & Config Module

**Files:**

- Create: `crates/skipper-shipwright/Cargo.toml`
- Create: `crates/skipper-shipwright/src/lib.rs`
- Create: `crates/skipper-shipwright/src/config.rs`
- Modify: `Cargo.toml` (workspace root — add member)

**Step 1: Add crate to workspace**

In the root `Cargo.toml`, add `"crates/skipper-shipwright"` to `workspace.members`.

**Step 2: Create crate Cargo.toml**

```toml
[package]
name = "skipper-shipwright"
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true
description = "Software Engineering Hand — autonomous delivery pipelines"

[dependencies]
skipper-types = { path = "../skipper-types" }
skipper-memory = { path = "../skipper-memory" }
skipper-runtime = { path = "../skipper-runtime" }

serde = { workspace = true, features = ["derive"] }
serde_json = { workspace = true }
toml = { workspace = true }
thiserror = { workspace = true }
tokio = { workspace = true, features = ["full"] }
chrono = { workspace = true, features = ["serde"] }
uuid = { workspace = true, features = ["v4"] }
tracing = { workspace = true }
reqwest = { workspace = true, features = ["json"] }
rusqlite = { workspace = true }
dashmap = { workspace = true }

[dev-dependencies]
tokio = { workspace = true, features = ["test-util", "macros"] }
```

**Step 3: Create lib.rs**

```rust
//! Skipper Shipwright — Software Engineering Hand
//!
//! Autonomous delivery pipelines: Issue → Plan → Build → Test → PR → Deploy.
//! Integrates with Skipper kernel for scheduling, RBAC, metering,
//! and cross-Hand intelligence via Collector, Researcher, and Predictor.

pub mod config;

pub use config::ShipwrightConfig;
```

**Step 4: Create config.rs**

```rust
//! Shipwright configuration types.
//!
//! Parsed from `[shipwright]` section in `skipper.toml`.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Top-level Shipwright configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ShipwrightConfig {
    pub enabled: bool,
    pub default_template: PipelineTemplateName,
    pub fleet: FleetConfig,
    pub decision: DecisionConfig,
    pub intelligence: IntelligenceConfig,
    pub github: GitHubConfig,
    pub repos: Vec<RepoConfig>,
}

impl Default for ShipwrightConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            default_template: PipelineTemplateName::Standard,
            fleet: FleetConfig::default(),
            decision: DecisionConfig::default(),
            intelligence: IntelligenceConfig::default(),
            github: GitHubConfig::default(),
            repos: vec![],
        }
    }
}

/// Pipeline template selection.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum PipelineTemplateName {
    Fast,
    Standard,
    Full,
    Hotfix,
    Autonomous,
    CostAware,
}

impl Default for PipelineTemplateName {
    fn default() -> Self {
        Self::Standard
    }
}

/// Fleet/daemon worker configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct FleetConfig {
    pub poll_interval_seconds: u64,
    pub auto_scale: bool,
    pub max_workers: u32,
    pub min_workers: u32,
    pub worker_mem_gb: u32,
    pub cost_per_job_usd: f64,
}

impl Default for FleetConfig {
    fn default() -> Self {
        Self {
            poll_interval_seconds: 60,
            auto_scale: false,
            max_workers: 8,
            min_workers: 1,
            worker_mem_gb: 4,
            cost_per_job_usd: 5.0,
        }
    }
}

/// Decision engine configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct DecisionConfig {
    pub enabled: bool,
    pub cycle_interval_seconds: u64,
    pub max_issues_per_day: u32,
    pub max_cost_per_day_usd: f64,
    pub cooldown_seconds: u64,
    pub halt_after_failures: u32,
    pub outcome_learning: bool,
}

impl Default for DecisionConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            cycle_interval_seconds: 1800,
            max_issues_per_day: 15,
            max_cost_per_day_usd: 25.0,
            cooldown_seconds: 300,
            halt_after_failures: 3,
            outcome_learning: true,
        }
    }
}

/// Intelligence layer configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct IntelligenceConfig {
    pub cache_ttl_seconds: u64,
    pub prediction_enabled: bool,
    pub adversarial_enabled: bool,
    pub architecture_enabled: bool,
}

impl Default for IntelligenceConfig {
    fn default() -> Self {
        Self {
            cache_ttl_seconds: 3600,
            prediction_enabled: true,
            adversarial_enabled: false,
            architecture_enabled: false,
        }
    }
}

/// GitHub integration configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct GitHubConfig {
    pub watch_labels: Vec<String>,
    pub auto_merge: bool,
    pub check_runs_enabled: bool,
    pub deployment_tracking: bool,
}

impl Default for GitHubConfig {
    fn default() -> Self {
        Self {
            watch_labels: vec!["shipwright".into(), "ready-to-build".into()],
            auto_merge: false,
            check_runs_enabled: true,
            deployment_tracking: true,
        }
    }
}

/// Per-repository configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoConfig {
    pub path: PathBuf,
    pub owner: String,
    pub repo: String,
    #[serde(default = "default_template")]
    pub template: PipelineTemplateName,
    #[serde(default = "default_max_parallel")]
    pub max_parallel: u32,
    #[serde(default)]
    pub auto_merge: bool,
}

fn default_template() -> PipelineTemplateName {
    PipelineTemplateName::Standard
}

fn default_max_parallel() -> u32 {
    2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config_serializes() {
        let config = ShipwrightConfig::default();
        let toml_str = toml::to_string_pretty(&config).unwrap();
        assert!(toml_str.contains("enabled = false"));
    }

    #[test]
    fn test_config_round_trip() {
        let config = ShipwrightConfig {
            enabled: true,
            default_template: PipelineTemplateName::Autonomous,
            repos: vec![RepoConfig {
                path: "/tmp/test".into(),
                owner: "myorg".into(),
                repo: "myrepo".into(),
                template: PipelineTemplateName::Full,
                max_parallel: 3,
                auto_merge: true,
            }],
            ..Default::default()
        };
        let toml_str = toml::to_string_pretty(&config).unwrap();
        let parsed: ShipwrightConfig = toml::from_str(&toml_str).unwrap();
        assert!(parsed.enabled);
        assert_eq!(parsed.repos.len(), 1);
        assert_eq!(parsed.repos[0].max_parallel, 3);
    }

    #[test]
    fn test_defaults_are_sane() {
        let config = ShipwrightConfig::default();
        assert!(!config.enabled);
        assert_eq!(config.fleet.max_workers, 8);
        assert_eq!(config.decision.max_issues_per_day, 15);
        assert_eq!(config.intelligence.cache_ttl_seconds, 3600);
        assert_eq!(config.github.watch_labels, vec!["shipwright", "ready-to-build"]);
    }

    #[test]
    fn test_partial_toml_uses_defaults() {
        let toml_str = r#"
            enabled = true
            [fleet]
            max_workers = 4
        "#;
        let config: ShipwrightConfig = toml::from_str(toml_str).unwrap();
        assert!(config.enabled);
        assert_eq!(config.fleet.max_workers, 4);
        assert_eq!(config.fleet.poll_interval_seconds, 60); // default
        assert!(!config.decision.enabled); // default
    }
}
```

**Step 5: Verify it compiles**

Run: `cargo build -p skipper-shipwright`
Expected: Compiles with zero warnings

**Step 6: Run tests**

Run: `cargo test -p skipper-shipwright`
Expected: 4 tests pass

**Step 7: Clippy**

Run: `cargo clippy -p skipper-shipwright -- -D warnings`
Expected: Zero warnings

**Step 8: Commit**

```bash
git add crates/skipper-shipwright/ Cargo.toml
git commit -m "feat(shipwright): scaffold crate with config module"
```

---

## Task 2: GitHub API Client

**Files:**

- Create: `crates/skipper-shipwright/src/github/mod.rs`
- Create: `crates/skipper-shipwright/src/github/graphql.rs`
- Create: `crates/skipper-shipwright/src/github/checks.rs`
- Create: `crates/skipper-shipwright/src/github/deployments.rs`
- Create: `crates/skipper-shipwright/src/github/pr.rs`
- Modify: `crates/skipper-shipwright/src/lib.rs` (add `pub mod github`)

**Step 1: Write tests for GitHub client**

In `github/mod.rs`, write tests that verify:

- `GitHubClient::new()` reads token from env
- `list_issues()` parses mock JSON response into `Vec<Issue>`
- `create_check_run()` sends correct POST payload
- `create_pr()` constructs correct body
- `select_reviewers()` deduplicates and limits to 3
- GraphQL cache returns cached result within TTL, fetches fresh after TTL

Use `mockito` or hand-built mock server for HTTP assertions.

**Step 2: Implement GitHub client**

Port from Shipwright's `scripts/lib/pipeline-github.sh` and `scripts/sw-github-graphql.sh`:

- `GitHubClient` struct with `reqwest::Client`, token, cache (`DashMap`)
- `list_issues(owner, repo, labels)` → REST GET `/repos/{owner}/{repo}/issues`
- `create_issue(owner, repo, title, body, labels)` → REST POST
- `add_label(owner, repo, issue, label)` → REST POST
- GraphQL queries: `file_change_frequency`, `blame_data`, `security_alerts`, `codeowners`, `similar_issues`
- Checks API: `create_check_run`, `update_check_run`
- Deployments API: `create_deployment`, `update_deployment_status`
- PR lifecycle: `create_pr`, `select_reviewers`, `auto_merge`

**Step 3: Verify tests pass**

Run: `cargo test -p skipper-shipwright -- github`
Expected: All tests pass

**Step 4: Commit**

```bash
git add crates/skipper-shipwright/src/github/
git commit -m "feat(shipwright): GitHub API client with GraphQL, Checks, Deployments, PR"
```

---

## Task 3: Memory System

**Files:**

- Create: `crates/skipper-shipwright/src/memory/mod.rs`
- Create: `crates/skipper-shipwright/src/memory/patterns.rs`
- Create: `crates/skipper-shipwright/src/memory/architecture.rs`
- Create: `crates/skipper-shipwright/src/memory/learning.rs`
- Modify: `crates/skipper-shipwright/src/lib.rs` (add `pub mod memory`)

**Step 1: Write tests for failure pattern storage**

In `memory/patterns.rs`, write tests:

- `store_failure()` inserts a `FailurePattern` into SQLite
- `search_similar_failures("undefined property")` returns semantically similar patterns (not just keyword match)
- `compose_context()` formats multiple patterns into agent-readable text
- Empty database returns empty results (no panic)

**Step 2: Write tests for architecture rules**

In `memory/architecture.rs`, write tests:

- `store_architecture()` persists layer definitions and dependency rules
- `check_violation("api", "db")` returns violation when direct api→db dependency exists
- `get_hotspots(repo, limit=5)` returns top 5 files by change frequency

**Step 3: Write tests for learning**

In `memory/learning.rs`, write tests:

- `record_outcome()` appends to outcomes table
- `adjust_weights()` with 10+ successful outcomes shifts weight toward that signal
- `ab_assign_group()` returns consistent group for same key
- `ab_report()` computes control vs treatment metrics

**Step 4: Implement memory module**

Port from Shipwright's `scripts/sw-memory.sh`:

- `ShipwrightMemory` wraps `skipper_memory::MemoryStore`
- `FailurePattern` struct with all fields from design doc
- `ArchitectureRule` struct with layers, dependency_rules, hotspots
- `Outcome` struct for decision learning
- `migrate_jsonl_memory(path)` reads Shipwright JSONL files and imports into SQLite with embeddings
- Semantic search via `store.vector_search()` on sqlite-vec

**Step 5: Verify tests pass**

Run: `cargo test -p skipper-shipwright -- memory`
Expected: All tests pass

**Step 6: Commit**

```bash
git add crates/skipper-shipwright/src/memory/
git commit -m "feat(shipwright): memory system with vector search, patterns, architecture, learning"
```

---

## Task 4: Pipeline Engine

**Files:**

- Create: `crates/skipper-shipwright/src/pipeline/mod.rs`
- Create: `crates/skipper-shipwright/src/pipeline/stages.rs`
- Create: `crates/skipper-shipwright/src/pipeline/templates.rs`
- Create: `crates/skipper-shipwright/src/pipeline/composer.rs`
- Create: `crates/skipper-shipwright/src/pipeline/self_healing.rs`
- Modify: `crates/skipper-shipwright/src/lib.rs` (add `pub mod pipeline`)

**Step 1: Write tests for stage state machine**

In `pipeline/stages.rs`, write tests:

- `Stage::all()` returns 12 stages in order
- `Pipeline::advance()` transitions `Running{Build}` → `Running{Test}`
- `Pipeline::fail()` transitions to `Failed` with retry count
- `Pipeline::pause()` transitions to `Paused` with gate reason
- Invalid transition (e.g., `Completed` → `Running`) returns error

**Step 2: Write tests for templates**

In `pipeline/templates.rs`, write tests:

- `PipelineTemplate::Fast` enables only Intake, Build, Test, Pr
- `PipelineTemplate::Full` enables all 12 stages
- `PipelineTemplate::CostAware` sets model routing (haiku for intake, opus for design)
- Template stages match the table in design doc

**Step 3: Write tests for self-healing build loop**

In `pipeline/self_healing.rs`, write tests:

- `BuildLoop::evaluate()` returns `TestsPassing` when test command succeeds
- `BuildLoop::evaluate()` returns `Converging` when error count drops >50%
- `BuildLoop::evaluate()` returns `Diverging` when error count increases
- `BuildLoop::evaluate()` returns `Exhausted` after `max_iterations`
- Convergence detection uses sliding window of size `convergence_window`

**Step 4: Write tests for dynamic composition**

In `pipeline/composer.rs`, write tests:

- `compose()` adjusts iterations based on complexity score
- `compose()` routes models based on stage type
- `compose()` respects intelligence overrides (risky_areas, test_intensity)

**Step 5: Implement pipeline engine**

Port from Shipwright's `scripts/sw-pipeline.sh`, `scripts/lib/pipeline-stages.sh`, `scripts/sw-loop.sh`:

- `Stage` enum with 12 variants
- `Pipeline` struct with state machine (`PipelineState`)
- `StageConfig` with gate, model, timeout, iterations
- `PipelineTemplate` enum → `Vec<StageConfig>` conversion
- `BuildLoop` with convergence detection, backtracking, restart logic
- `PipelineComposer` that adjusts template based on intelligence output
- Channel notifications via kernel on state transitions

**Step 6: Verify tests pass**

Run: `cargo test -p skipper-shipwright -- pipeline`
Expected: All tests pass

**Step 7: Commit**

```bash
git add crates/skipper-shipwright/src/pipeline/
git commit -m "feat(shipwright): 12-stage pipeline engine with templates, self-healing, composition"
```

---

## Task 5: Decision Engine

**Files:**

- Create: `crates/skipper-shipwright/src/decision/mod.rs`
- Create: `crates/skipper-shipwright/src/decision/signals.rs`
- Create: `crates/skipper-shipwright/src/decision/scoring.rs`
- Create: `crates/skipper-shipwright/src/decision/autonomy.rs`
- Modify: `crates/skipper-shipwright/src/lib.rs` (add `pub mod decision`)

**Step 1: Write tests for signal collection**

In `decision/signals.rs`, write tests:

- `SecurityCollector::collect()` parses `npm audit --json` output into candidates
- `DependencyCollector::collect()` classifies bump type (patch/minor/major)
- `CoverageCollector::collect()` detects coverage below threshold
- `HandSignalCollector::collect()` queries mock Collector/Researcher/Predictor Hands
- All collectors set `dedup_key` for idempotency
- Each candidate has valid `risk_score` (0-100) and `confidence` (0.0-1.0)

**Step 2: Write tests for scoring**

In `decision/scoring.rs`, write tests:

- Formula: `value = (impact * 0.30) + (urgency * 0.25) + (effort * 0.20) + (confidence * 0.15) - (risk * 0.10)`
- `score_candidate()` with critical CVE returns value > 80
- `score_candidate()` with style nit returns value < 30
- Custom weights from `ScoringWeights` override defaults
- `adjust_weights()` via EMA shifts weights toward consistently successful signals

**Step 3: Write tests for autonomy**

In `decision/autonomy.rs`, write tests:

- `resolve_tier("security_patch")` returns `Auto`
- `resolve_tier("refactor_hotspot")` returns `Propose`
- `resolve_tier("new_feature")` returns `Draft`
- `check_budget()` returns false after 15 issues/day
- `check_rate_limit()` returns false within 300s cooldown
- `check_halt()` returns true when halt flag is set
- `record_decision()` appends to daily log
- `halt()` + `resume()` round-trip

**Step 4: Implement decision engine**

Port from Shipwright's `scripts/sw-decide.sh`, `scripts/lib/decide-*.sh`:

- `SignalCollector` trait with `name()` and `collect()` methods
- 10+ built-in collectors (Security, Dependency, Coverage, DeadCode, etc.)
- `HandSignalCollector` that queries Skipper kernel for Hand results
- `Candidate` struct with all fields from design doc
- `score_candidate()` function with configurable weights
- `AutonomyTier` enum with tier resolution from category rules
- `DecisionLimits` with budget, rate, and halt enforcement
- `DecisionEngine::run_cycle()` orchestrating collect → dedup → score → tier → execute
- Deduplication against open GitHub issues and recent decisions (7d window)

**Step 5: Verify tests pass**

Run: `cargo test -p skipper-shipwright -- decision`
Expected: All tests pass

**Step 6: Commit**

```bash
git add crates/skipper-shipwright/src/decision/
git commit -m "feat(shipwright): decision engine with signals, scoring, autonomy tiers, Hand cross-pollination"
```

---

## Task 6: Intelligence Layer

**Files:**

- Create: `crates/skipper-shipwright/src/intelligence/mod.rs`
- Create: `crates/skipper-shipwright/src/intelligence/prediction.rs`
- Create: `crates/skipper-shipwright/src/intelligence/dora.rs`
- Create: `crates/skipper-shipwright/src/intelligence/optimization.rs`
- Modify: `crates/skipper-shipwright/src/lib.rs` (add `pub mod intelligence`)

**Step 1: Write tests for DORA metrics**

In `intelligence/dora.rs`, write tests:

- `calculate_lead_time()` computes hours from first commit to deploy
- `calculate_deploy_frequency()` counts deploys per day over window
- `calculate_change_failure_rate()` is ratio of failed to total deploys
- `calculate_mttr()` averages time from failure to recovery
- `dora_level()` classifies as Elite/High/Medium/Low per DORA benchmarks

**Step 2: Write tests for prediction**

In `intelligence/prediction.rs`, write tests:

- `predict_risk(issue)` returns 0-100 based on file hotspots + complexity
- `detect_anomaly(metrics, threshold)` flags values > N standard deviations
- `recommend_model(risk)` returns Opus for risk>70, Sonnet for risk<30

**Step 3: Write tests for self-optimization**

In `intelligence/optimization.rs`, write tests:

- `suggest_config_change(dora_metrics)` recommends max_workers increase if lead time is high
- `adaptive_cycles(base, stage, current, previous)` extends cycles on convergence
- Self-optimization respects limits (never exceed 6 cycles, never reduce below 1)

**Step 4: Implement intelligence layer**

Port from Shipwright's `scripts/sw-intelligence.sh`, `scripts/sw-predictive.sh`, `scripts/sw-dora.sh`, `scripts/sw-self-optimize.sh`:

- DORA metrics calculator with GitHub deployment history
- Risk prediction using file hotspots from `github/graphql.rs`
- Anomaly detection with z-score threshold
- Self-optimization that adjusts config based on DORA trends
- Adaptive cycle count based on convergence/divergence patterns

**Step 5: Verify tests pass**

Run: `cargo test -p skipper-shipwright -- intelligence`
Expected: All tests pass

**Step 6: Commit**

```bash
git add crates/skipper-shipwright/src/intelligence/
git commit -m "feat(shipwright): intelligence layer with DORA, prediction, self-optimization"
```

---

## Task 7: Fleet & Daemon

**Files:**

- Create: `crates/skipper-shipwright/src/fleet/mod.rs`
- Create: `crates/skipper-shipwright/src/fleet/daemon.rs`
- Create: `crates/skipper-shipwright/src/fleet/dispatch.rs`
- Create: `crates/skipper-shipwright/src/fleet/patrol.rs`
- Modify: `crates/skipper-shipwright/src/lib.rs` (add `pub mod fleet`)

**Step 1: Write tests for worker pool**

In `fleet/dispatch.rs`, write tests:

- `WorkerPool::has_capacity(repo)` returns true when workers < max_parallel
- `WorkerPool::claim(repo, agent_id)` decrements available
- `WorkerPool::release(agent_id)` increments available
- Auto-scaling formula: `min(cpu*0.75, mem/worker_mem, budget/cost)`
- `WorkerPool::rebalance()` distributes proportionally to queue depth

**Step 2: Write tests for daemon poll cycle**

In `fleet/daemon.rs`, write tests:

- `poll_cycle()` with 3 labeled issues dispatches up to `max_parallel`
- `poll_cycle()` skips issues already claimed
- `poll_cycle()` respects worker pool capacity
- Triage scores issues: p0 > p1 > unlabeled
- Issues with `shipwright:proposed` label require approval before dispatch

**Step 3: Write tests for patrol**

In `fleet/patrol.rs`, write tests:

- `run_patrol()` detects outdated dependencies
- `run_patrol()` detects security vulnerabilities
- `run_patrol()` detects coverage regression
- `run_patrol()` detects DORA metric degradation
- Patrol results feed into decision engine as candidates

**Step 4: Implement fleet module**

Port from Shipwright's `scripts/sw-daemon.sh`, `scripts/lib/daemon-*.sh`, `scripts/sw-fleet.sh`:

- `FleetManager` struct with kernel handle, repos, worker pool
- `poll_cycle()` as async kernel-scheduled job
- `WorkerPool` with static and auto-scaling strategies
- `Dispatcher` that spawns pipelines as Skipper agents
- `Patrol` that runs periodic checks and feeds decision engine
- Replace bash PID/flock with kernel agent registry
- Replace tmux with kernel agent management

**Step 5: Verify tests pass**

Run: `cargo test -p skipper-shipwright -- fleet`
Expected: All tests pass

**Step 6: Commit**

```bash
git add crates/skipper-shipwright/src/fleet/
git commit -m "feat(shipwright): fleet manager with daemon, auto-scaling, patrol"
```

---

## Task 8: Hand Definition

**Files:**

- Create: `crates/skipper-shipwright/src/hand.rs`
- Create: `crates/skipper-shipwright/agents/shipwright/HAND.toml`
- Create: `crates/skipper-shipwright/agents/shipwright/SKILL.md`
- Create: `crates/skipper-shipwright/agents/shipwright/system_prompt.md`
- Modify: `crates/skipper-shipwright/src/lib.rs` (add `pub mod hand`)

**Step 1: Create HAND.toml**

Follow the researcher hand pattern:

```toml
[hand]
id = "shipwright"
name = "Shipwright Hand"
description = "Autonomous software delivery — Issue to PR to Production"
category = "development"
icon = "⚓"

[config]
temperature = 0.2
max_tokens = 16384
max_iterations = 120
module = "builtin:chat"

[[tools]]
name = "shell"
[[tools]]
name = "read_file"
[[tools]]
name = "write_file"
[[tools]]
name = "web_search"
[[tools]]
name = "read_url"
[[tools]]
name = "schedule"
[[tools]]
name = "memory_store"
[[tools]]
name = "memory_query"
[[tools]]
name = "event_publish"
[[tools]]
name = "knowledge_graph"

[[settings]]
type = "select"
name = "pipeline_template"
label = "Pipeline Template"
description = "Which pipeline template to use for builds"
default = "standard"
[[settings.options]]
value = "fast"
label = "Fast (skip review)"
[[settings.options]]
value = "standard"
label = "Standard (with review)"
[[settings.options]]
value = "full"
label = "Full (all stages)"
[[settings.options]]
value = "autonomous"
label = "Autonomous (all auto)"

[[settings]]
type = "select"
name = "auto_merge"
label = "Auto-Merge PRs"
default = "false"
[[settings.options]]
value = "true"
label = "Yes"
[[settings.options]]
value = "false"
label = "No"

[[settings]]
type = "select"
name = "decision_engine"
label = "Decision Engine"
description = "Autonomous what-to-build decisions"
default = "off"
[[settings.options]]
value = "off"
label = "Off"
[[settings.options]]
value = "propose"
label = "Propose only"
[[settings.options]]
value = "auto"
label = "Fully autonomous"

[dashboard]
[[dashboard.metrics]]
name = "pipelines_completed"
label = "Pipelines Completed"
type = "counter"
[[dashboard.metrics]]
name = "pr_success_rate"
label = "PR Success Rate"
type = "percentage"
[[dashboard.metrics]]
name = "avg_lead_time_hours"
label = "Avg Lead Time"
type = "gauge"
[[dashboard.metrics]]
name = "active_workers"
label = "Active Workers"
type = "gauge"

[[requirements]]
type = "binary"
name = "git"
[[requirements]]
type = "env"
name = "GITHUB_TOKEN"
```

**Step 2: Create SKILL.md**

Write domain expertise content covering:

- Pipeline stage conventions (what each stage does, expected inputs/outputs)
- Build loop patterns (convergence detection, when to backtrack vs restart)
- GitHub workflow conventions (PR formatting, label semantics, reviewer selection)
- Test strategy (when to use fast tests vs full suite)
- Memory usage (how to search and store failure patterns)
- DORA metrics interpretation

**Step 3: Create system_prompt.md**

Multi-phase operational playbook:

1. Platform detection (repo structure, test framework, build system)
2. Issue analysis (decomposition, complexity scoring)
3. Pipeline execution (stage-by-stage with gate checks)
4. Build loop (iterative code generation with self-healing)
5. Quality assurance (adversarial review, architecture check)
6. PR creation (reviewer selection, description generation)
7. Post-merge (deployment tracking, monitoring)

**Step 4: Implement hand.rs**

Wire the Hand definition to load bundled files and register with Skipper's hand registry:

```rust
//! Shipwright Hand definition and registration.

use crate::config::ShipwrightConfig;

/// Hand definition metadata embedded at compile time.
pub const HAND_TOML: &str = include_str!("../agents/shipwright/HAND.toml");
pub const SKILL_MD: &str = include_str!("../agents/shipwright/SKILL.md");
pub const SYSTEM_PROMPT: &str = include_str!("../agents/shipwright/system_prompt.md");

/// Register the Shipwright hand with Skipper's hand registry.
pub fn register(/* registry: &mut HandRegistry */) {
    // Parse HAND.toml, attach SKILL.md, register definition
    // Follows same pattern as skipper-hands/src/bundled.rs
}
```

**Step 5: Verify compilation**

Run: `cargo build -p skipper-shipwright`
Expected: Compiles, Hand files embedded

**Step 6: Commit**

```bash
git add crates/skipper-shipwright/src/hand.rs crates/skipper-shipwright/agents/
git commit -m "feat(shipwright): Hand definition with HAND.toml, SKILL.md, system prompt"
```

---

## Task 9: CLI & API Routes

**Files:**

- Create: `crates/skipper-shipwright/src/cli.rs`
- Create: `crates/skipper-shipwright/src/api.rs`
- Modify: `crates/skipper-shipwright/src/lib.rs` (add `pub mod cli; pub mod api`)
- Modify: `crates/skipper-api/src/server.rs` (register Shipwright routes)
- Modify: `crates/skipper-cli/src/main.rs` (register `shipwright` subcommand)

**Step 1: Implement CLI subcommands**

Using clap, define the `shipwright` subcommand group:

```rust
#[derive(clap::Subcommand)]
pub enum ShipwrightCommand {
    Pipeline {
        #[command(subcommand)]
        cmd: PipelineCmd,
    },
    Decide {
        #[command(subcommand)]
        cmd: DecideCmd,
    },
    Fleet {
        #[command(subcommand)]
        cmd: FleetCmd,
    },
    Memory {
        #[command(subcommand)]
        cmd: MemoryCmd,
    },
    Dora,
    Cost,
    Doctor,
}
```

**Step 2: Implement API routes**

Using axum, define Shipwright routes:

- `GET /api/shipwright/pipelines` → list active/completed pipelines
- `POST /api/shipwright/pipelines` → start new pipeline
- `GET /api/shipwright/pipelines/:id` → pipeline detail with stage status
- `GET /api/shipwright/pipelines/:id/ws` → WebSocket for real-time stage updates
- `POST /api/shipwright/decide/run` → trigger decision cycle
- `GET /api/shipwright/decide/candidates` → list current candidates
- `GET /api/shipwright/fleet/status` → fleet overview
- `GET /api/shipwright/dora/:repo` → DORA metrics for repo
- `GET /api/shipwright/memory/search` → semantic memory search

**Step 3: Register routes in Skipper API server**

Add Shipwright router to `server.rs`:

```rust
.nest("/api/shipwright", skipper_shipwright::api::router(state.clone()))
```

**Step 4: Register CLI in Skipper CLI**

Add `Shipwright` variant to main CLI enum, dispatch to `skipper_shipwright::cli::run()`.

**Step 5: Verify CLI works**

Run: `cargo build --release -p skipper-cli`
Run: `target/release/skipper shipwright --help`
Expected: Shows pipeline, decide, fleet, memory, dora, cost, doctor subcommands

**Step 6: Commit**

```bash
git add crates/skipper-shipwright/src/cli.rs crates/skipper-shipwright/src/api.rs
git add crates/skipper-api/src/server.rs crates/skipper-cli/src/main.rs
git commit -m "feat(shipwright): CLI subcommands and API routes"
```

---

## Task 10: Dashboard Pages

**Files:**

- Modify: `crates/skipper-api/static/index.html` (add Shipwright nav + pages)
- Modify: `crates/skipper-api/static/app.js` (add Shipwright page logic)

**Step 1: Add navigation**

Add "Shipwright" section to dashboard sidebar with 6 sub-pages:
Pipelines, Fleet, Decisions, DORA, Memory, Intelligence.

**Step 2: Implement Pipelines page**

- Fetch `GET /api/shipwright/pipelines`
- Render table: ID, issue, template, current stage, status, cost, duration
- Stage progress bar (12 segments, color-coded: green=done, blue=running, gray=pending, red=failed)
- WebSocket connection for real-time updates

**Step 3: Implement Fleet page**

- Fetch `GET /api/shipwright/fleet/status`
- Worker pool visualization (allocated vs available)
- Per-repo queue depth and active pipelines
- Auto-scaling metrics (CPU, memory, budget)

**Step 4: Implement Decisions page**

- Fetch `GET /api/shipwright/decide/candidates`
- Candidate table: ID, signal, title, score, tier, status
- Score breakdown visualization (impact, urgency, effort, confidence, risk)
- Outcome history chart

**Step 5: Implement DORA page**

- Fetch `GET /api/shipwright/dora/:repo`
- Four metric cards: Lead Time, Deploy Frequency, CFR, MTTR
- Trend charts over 30/90 day windows
- DORA level badge (Elite/High/Medium/Low)

**Step 6: Implement Memory page**

- Search bar → `GET /api/shipwright/memory/search?q=...`
- Failure pattern cards with root cause, fix, similarity score
- Architecture rule viewer

**Step 7: Implement Intelligence page**

- Risk heatmap by file
- Anomaly detection alerts
- Self-optimization suggestion log

**Step 8: Live integration test**

Run: `cargo build --release -p skipper-cli`
Run: `target/release/skipper start &`
Navigate to `http://localhost:4200/shipwright/pipelines`
Verify: All 6 pages render, API calls succeed, WebSocket connects

**Step 9: Commit**

```bash
git add crates/skipper-api/static/
git commit -m "feat(shipwright): dashboard with 6 pages — pipelines, fleet, decisions, DORA, memory, intelligence"
```

---

## Task 11: Integration Tests

**Files:**

- Create: `crates/skipper-shipwright/tests/pipeline_tests.rs`
- Create: `crates/skipper-shipwright/tests/decision_tests.rs`
- Create: `crates/skipper-shipwright/tests/memory_tests.rs`
- Create: `crates/skipper-shipwright/tests/fleet_tests.rs`
- Create: `crates/skipper-shipwright/tests/integration_tests.rs`

**Step 1: Pipeline integration test**

Test full pipeline lifecycle: create → run stages → build loop (mock LLM) → self-heal → complete → PR created.

**Step 2: Decision integration test**

Test: collect signals (mock npm audit, mock Hand responses) → score → resolve tier → dedup → create issue.

**Step 3: Memory integration test**

Test: store failure → import JSONL → semantic search → compose context → verify relevance.

**Step 4: Fleet integration test**

Test: configure 2 repos → poll cycle → dispatch within worker limit → auto-scale up → rebalance.

**Step 5: End-to-end integration test**

Test: Skipper Collector Hand finds CVE → Decision engine scores it → Pipeline spawned → Build loop runs → PR created → Outcome recorded → Weights adjusted.

**Step 6: Run full test suite**

Run: `cargo test --workspace`
Expected: All existing Skipper tests pass + all new Shipwright tests pass

Run: `cargo clippy --workspace --all-targets -- -D warnings`
Expected: Zero warnings

**Step 7: Commit**

```bash
git add crates/skipper-shipwright/tests/
git commit -m "test(shipwright): integration tests for pipeline, decision, memory, fleet, and e2e"
```

---

## Task 12: Documentation & Final Verification

**Files:**

- Modify: `README.md` (add Shipwright Hand section)
- Modify: `CHANGELOG.md` (add entry)

**Step 1: Update README**

Add section describing the Shipwright Hand — what it does, how to activate, configuration reference.

**Step 2: Update CHANGELOG**

```markdown
## [Unreleased]

### Added

- **Shipwright Hand**: Autonomous software delivery pipeline
  - 12-stage pipeline engine with 6 templates
  - Decision engine with 18 signal collectors + Skipper Hand cross-pollination
  - Vector memory with semantic failure pattern search
  - Fleet manager with auto-scaling worker pool
  - GitHub integration (GraphQL, Checks, Deployments, PR lifecycle)
  - Intelligence layer (DORA metrics, risk prediction, self-optimization)
  - CLI subcommands: `skipper shipwright {pipeline,decide,fleet,memory,dora,cost,doctor}`
  - 9 API endpoints with WebSocket real-time updates
  - 6 dashboard pages
```

**Step 3: Final verification**

```bash
cargo build --workspace --lib
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

All three must pass with zero errors, zero warnings.

**Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs(shipwright): README and CHANGELOG for Shipwright Hand"
```

**Step 5: Create PR**

```bash
git push origin feat/shipwright-hand
gh pr create --title "feat: Shipwright Hand — autonomous software delivery" \
  --body "Ports Shipwright into skipper-shipwright crate. See docs/plans/2026-02-28-skipper-shipwright-integration-design.md"
```

---

## Summary

| Task | Module                  | Tests                 | Commit                                                |
| ---- | ----------------------- | --------------------- | ----------------------------------------------------- |
| 1    | Crate scaffold + config | 4 unit tests          | `feat(shipwright): scaffold crate with config module` |
| 2    | GitHub API client       | ~15 unit tests        | `feat(shipwright): GitHub API client`                 |
| 3    | Memory system           | ~12 unit tests        | `feat(shipwright): memory system with vector search`  |
| 4    | Pipeline engine         | ~15 unit tests        | `feat(shipwright): 12-stage pipeline engine`          |
| 5    | Decision engine         | ~18 unit tests        | `feat(shipwright): decision engine`                   |
| 6    | Intelligence layer      | ~12 unit tests        | `feat(shipwright): intelligence layer`                |
| 7    | Fleet & daemon          | ~12 unit tests        | `feat(shipwright): fleet manager`                     |
| 8    | Hand definition         | Compile check         | `feat(shipwright): Hand definition`                   |
| 9    | CLI & API               | CLI smoke test        | `feat(shipwright): CLI and API routes`                |
| 10   | Dashboard               | Live test             | `feat(shipwright): dashboard pages`                   |
| 11   | Integration tests       | ~10 integration tests | `test(shipwright): integration tests`                 |
| 12   | Documentation           | Final verification    | `docs(shipwright): README and CHANGELOG`              |

**Total: 12 tasks, ~100+ tests, 12 commits**
