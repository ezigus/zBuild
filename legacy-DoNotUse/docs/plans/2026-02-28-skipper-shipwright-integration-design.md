# Skipper + Shipwright Integration Design

**Date**: 2026-02-28
**Status**: Approved
**Direction**: Shipwright as a native Skipper Hand
**Depth**: Deep integration — full port to Rust
**Location**: Fork of Skipper

## Context

Shipwright orchestrates autonomous Claude Code agent teams for software delivery (Issue → Pipeline → PR → Deploy). Skipper is a Rust-based Agent Operating System that runs autonomous Hands on schedules with WASM sandboxing, 40 channel adapters, and 16 security layers.

This design ports Shipwright's complete feature set into a single `skipper-shipwright` crate within a fork of Skipper, creating a "Software Engineering Hand" that leverages Skipper's kernel, memory, channels, and existing Hands for cross-pollinated intelligence.

## Why This Combination

| Shipwright Brings                                     | Skipper Brings                                      |
| ----------------------------------------------------- | ---------------------------------------------------- |
| 12-stage delivery pipeline                            | Rust kernel with scheduling, RBAC, metering          |
| Decision engine with autonomy tiers                   | WASM sandbox with dual metering                      |
| Failure pattern memory + learning                     | SQLite + vector embeddings for semantic search       |
| GitHub API integration (GraphQL, Checks, Deployments) | 40 channel adapters (Slack, Discord, Telegram, etc.) |
| DORA metrics + self-optimization                      | 76+ REST/WS/SSE API endpoints                        |
| Multi-repo fleet orchestration                        | A2A protocol for cross-instance agents               |
| Build loop with self-healing                          | Loop guard detection (SHA256)                        |

Key differentiator: Skipper's Collector, Researcher, and Predictor Hands become first-class signal sources for Shipwright's decision engine — OSINT-grade analysis, cross-referenced research, and calibrated forecasting feeding directly into what-to-build decisions.

## Crate Structure

```
skipper/
├── crates/
│   └── skipper-shipwright/
│       ├── Cargo.toml
│       ├── src/
│       │   ├── lib.rs                 # Public API, re-exports
│       │   ├── hand.rs                # HandDefinition, activation, lifecycle
│       │   ├── config.rs              # ShipwrightConfig types, TOML parsing
│       │   ├── pipeline/
│       │   │   ├── mod.rs             # Pipeline engine
│       │   │   ├── stages.rs          # 12 stage implementations
│       │   │   ├── templates.rs       # fast/standard/full/hotfix/autonomous/cost-aware
│       │   │   ├── composer.rs        # Dynamic pipeline composition
│       │   │   └── self_healing.rs    # Build loop with retry, backtrack, convergence
│       │   ├── decision/
│       │   │   ├── mod.rs             # Decision engine orchestrator
│       │   │   ├── signals.rs         # 18 collectors + Skipper Hand signals
│       │   │   ├── scoring.rs         # Value scoring (impact, urgency, effort, confidence, risk)
│       │   │   └── autonomy.rs        # Tier enforcement, rate limiting, halt/resume
│       │   ├── memory/
│       │   │   ├── mod.rs             # Memory system
│       │   │   ├── patterns.rs        # Failure pattern storage & retrieval
│       │   │   ├── architecture.rs    # Architecture rules & enforcement
│       │   │   └── learning.rs        # A/B testing, outcome learning, weight adjustment
│       │   ├── fleet/
│       │   │   ├── mod.rs             # Multi-repo orchestration
│       │   │   ├── daemon.rs          # Issue watcher, auto-scaling, worker pool
│       │   │   ├── dispatch.rs        # Job spawning, claim serialization
│       │   │   └── patrol.rs          # Security, deps, coverage, DORA patrol checks
│       │   ├── github/
│       │   │   ├── mod.rs             # GitHub API client
│       │   │   ├── graphql.rs         # Cached GraphQL queries
│       │   │   ├── checks.rs          # Check Runs API
│       │   │   ├── deployments.rs     # Deployments API
│       │   │   └── pr.rs              # PR lifecycle, reviewer selection
│       │   └── intelligence/
│       │       ├── mod.rs             # Analysis engine
│       │       ├── prediction.rs      # Risk scoring, anomaly detection
│       │       ├── dora.rs            # DORA metrics
│       │       └── optimization.rs    # Self-tuning, adaptive cycles
│       ├── agents/
│       │   └── shipwright/
│       │       ├── HAND.toml          # Hand manifest
│       │       ├── SKILL.md           # Domain expertise
│       │       └── system_prompt.md   # Multi-phase operational playbook
│       └── tests/
│           ├── pipeline_tests.rs
│           ├── decision_tests.rs
│           ├── memory_tests.rs
│           ├── fleet_tests.rs
│           └── integration_tests.rs
```

## Pipeline Engine

### Stage Mapping

12 stages execute as Skipper workflow steps with sequential, conditional, and loop support:

```
intake → plan → design → build ⟲ test → review → compound_quality → pr → merge → deploy → validate → monitor
                           ↑         │
                           └─────────┘ (self-healing loop)
```

### Key Types

```rust
pub enum Stage {
    Intake, Plan, Design, Build, Test, Review,
    CompoundQuality, Pr, Merge, Deploy, Validate, Monitor,
}

pub struct Pipeline {
    pub id: String,
    pub issue: Option<u64>,
    pub goal: String,
    pub template: PipelineTemplate,
    pub stages: Vec<StageConfig>,
    pub state: PipelineState,
    pub artifacts_dir: PathBuf,
}

pub struct StageConfig {
    pub stage: Stage,
    pub enabled: bool,
    pub gate: Gate,              // Auto or Approve
    pub max_iterations: u32,
    pub model: ModelChoice,      // haiku/sonnet/opus routing
    pub timeout_seconds: u64,
}

pub enum PipelineState {
    Pending,
    Running { current_stage: Stage, iteration: u32 },
    Paused { at_stage: Stage, reason: String },
    Completed { pr_url: Option<String> },
    Failed { at_stage: Stage, error: String, retries: u32 },
}
```

### Build Loop & Self-Healing

```rust
pub struct BuildLoop {
    pub max_iterations: u32,
    pub max_restarts: u32,
    pub fast_test_cmd: Option<String>,
    pub fast_test_interval: u32,
    pub convergence_window: u32,
    pub progress: ProgressState,
}

pub enum BuildOutcome {
    TestsPassing,
    Converging { issues_remaining: u32 },
    Diverging,
    Exhausted,
}
```

Kernel's dual metering (fuel + epoch interruption) replaces bash timeouts. Skipper's loop guard detection (SHA256 of tool calls) replaces manual convergence checking.

### Templates

Six templates stored as Rust constants:

| Template   | Stages                     | Gates                             |
| ---------- | -------------------------- | --------------------------------- |
| Fast       | intake → build → test → pr | all auto                          |
| Standard   | + plan, review             | approve: plan, review, pr         |
| Full       | all 12 stages              | approve: plan, review, pr, deploy |
| Hotfix     | intake → build → test → pr | all auto, priority lane           |
| Autonomous | all stages                 | all auto                          |
| CostAware  | all stages                 | model routing by complexity       |

## Decision Engine

### Signal Collectors

18 built-in collectors plus Skipper Hand cross-pollination:

```rust
pub trait SignalCollector: Send + Sync {
    fn name(&self) -> &str;
    fn collect(&self, ctx: &RepoContext) -> Result<Vec<Candidate>>;
}

pub struct Candidate {
    pub id: String,
    pub signal: SignalType,
    pub category: Category,
    pub title: String,
    pub description: String,
    pub evidence: serde_json::Value,
    pub risk_score: u8,
    pub confidence: f64,
    pub dedup_key: String,
}

pub enum SignalType {
    Security, Dependency, Coverage, DeadCode, Performance,
    Architecture, Dora, Documentation, Failure,
    SkipperHand,  // Signals from Collector, Researcher, Predictor
}
```

### Skipper Hand Cross-Pollination

```rust
pub struct HandSignalCollector {
    kernel: Arc<KernelHandle>,
}

impl SignalCollector for HandSignalCollector {
    fn collect(&self, ctx: &RepoContext) -> Result<Vec<Candidate>> {
        let mut candidates = vec![];

        // Collector Hand → OSINT on dependencies, CVE databases
        if let Some(collector) = self.kernel.get_hand("collector") {
            let intel = collector.query("security vulnerabilities for {}", ctx.dependencies)?;
            candidates.extend(parse_collector_findings(intel));
        }

        // Researcher Hand → Cross-referenced analysis
        if let Some(researcher) = self.kernel.get_hand("researcher") {
            let report = researcher.query("architecture anti-patterns in {}", ctx.repo_url)?;
            candidates.extend(parse_researcher_findings(report));
        }

        // Predictor Hand → Forecasting failure probability
        if let Some(predictor) = self.kernel.get_hand("predictor") {
            let forecast = predictor.query("probability of regression in {}", ctx.hot_files)?;
            candidates.extend(parse_predictor_findings(forecast));
        }

        Ok(candidates)
    }
}
```

### Scoring & Autonomy Tiers

```rust
pub struct ScoringWeights {
    pub impact: f64,      // 0.30
    pub urgency: f64,     // 0.25
    pub effort: f64,      // 0.20
    pub confidence: f64,  // 0.15
    pub risk: f64,        // 0.10
}

pub enum AutonomyTier {
    Auto,     // Create issue + spawn pipeline immediately
    Propose,  // Create issue, wait for approval
    Draft,    // Write to drafts only
}

pub struct DecisionLimits {
    pub max_issues_per_day: u32,     // 15
    pub max_cost_per_day_usd: f64,   // 25.0
    pub cooldown_seconds: u64,       // 300
    pub halt_after_failures: u32,    // 3
}
```

### Outcome Learning

EMA-based weight adjustment stored in Skipper's SQLite:

```rust
pub struct Outcome {
    pub candidate_id: String,
    pub predicted_score: f64,
    pub actual_success: bool,
    pub duration_minutes: u32,
    pub cost_usd: f64,
    pub signal_source: SignalType,
}
```

After 10+ outcomes, weights auto-adjust per signal source.

## Memory System

### Architecture

Reuses Skipper's `MemoryStore` (SQLite + sqlite-vec) instead of JSONL:

```rust
pub struct ShipwrightMemory {
    store: Arc<skipper_memory::MemoryStore>,
}

pub struct FailurePattern {
    pub repo: String,
    pub stage: Stage,
    pub error_class: String,
    pub error_signature: String,
    pub root_cause: String,
    pub fix_applied: String,
    pub fix_commit: Option<String>,
    pub success: bool,
    pub embedding: Vec<f32>,
}

pub struct ArchitectureRule {
    pub repo: String,
    pub layers: Vec<String>,
    pub dependency_rules: Vec<DependencyRule>,
    pub hotspots: HashMap<String, u32>,
    pub conventions: Vec<String>,
}
```

### Semantic Search

Vector similarity search replaces keyword/TF-IDF matching:

```rust
impl ShipwrightMemory {
    pub fn search_similar_failures(
        &self, error_text: &str, repo: &str, limit: usize,
    ) -> Result<Vec<FailurePattern>> {
        let query_embedding = self.store.embed(error_text)?;
        self.store.vector_search("failure_patterns", &query_embedding, limit, Some(&[("repo", repo)]))
    }

    pub fn compose_context(&self, error: &str, repo: &str) -> String {
        let patterns = self.search_similar_failures(error, repo, 3).unwrap_or_default();
        patterns.iter().map(|p| {
            format!("Previously fixed similar error:\n  Cause: {}\n  Fix: {}", p.root_cause, p.fix_applied)
        }).collect::<Vec<_>>().join("\n\n")
    }
}
```

### Cross-Hand Memory Sharing

All Hands access the same MemoryStore:

- Collector finds CVE → stores with embedding → Shipwright finds it during pipeline
- Predictor queries Shipwright outcomes for calibration
- Researcher stores architecture analysis → Shipwright enforces it

### Migration

```rust
pub fn migrate_jsonl_memory(jsonl_path: &Path, store: &MemoryStore) -> Result<u32> {
    // Read JSONL → parse → embed → insert into SQLite
}
```

## Fleet & Daemon

### Fleet Manager

```rust
pub struct FleetManager {
    kernel: Arc<KernelHandle>,
    repos: Vec<RepoConfig>,
    worker_pool: WorkerPool,
}

pub struct WorkerPool {
    pub total_workers: u32,
    pub min_per_repo: u32,
    pub rebalance_interval: Duration,
    pub scaling: ScalingStrategy,
}

pub enum ScalingStrategy {
    Static { workers: u32 },
    Auto { max_workers: u32, min_workers: u32, worker_mem_gb: u32, cost_per_job_usd: f64 },
}
```

### Daemon as Kernel-Scheduled Job

```rust
impl FleetManager {
    pub async fn poll_cycle(&self) -> Result<()> {
        for repo in &self.repos {
            let issues = self.github.list_issues(&repo, &repo.watch_labels).await?;
            let new_issues = self.filter_unclaimed(issues)?;
            let scored = self.triage_and_score(new_issues).await?;
            for issue in scored {
                if self.worker_pool.has_capacity(&repo) {
                    let agent_id = self.kernel.spawn_agent(
                        AgentConfig::from_pipeline(issue, repo)
                    ).await?;
                    self.worker_pool.claim(repo, agent_id)?;
                }
            }
        }
        Ok(())
    }
}
```

### What the Kernel Replaces

| Shipwright Bash                 | Skipper Kernel                 |
| ------------------------------- | ------------------------------- |
| PID management + flock          | Agent registry (atomic)         |
| tmux pane isolation             | WASM sandbox                    |
| File-based heartbeats           | Kernel heartbeat monitor        |
| `while true; sleep 60`          | Cron scheduler                  |
| `claim_issue()` race conditions | Kernel agent spawn (serialized) |

### Channel Notifications

Pipeline events push to configured channels automatically:

```rust
impl Pipeline {
    async fn notify(&self, event: PipelineEvent) {
        self.kernel.send_channel_message(&self.notify_channels, &event.format()).await;
    }
}
```

40 adapters available: Slack, Discord, Telegram, email, Teams, etc.

## Configuration

Single `[shipwright]` section in `skipper.toml`:

```toml
[shipwright]
enabled = true
default_template = "standard"

[shipwright.fleet]
poll_interval_seconds = 60
auto_scale = true
max_workers = 8

[shipwright.decision]
enabled = true
max_issues_per_day = 15
max_cost_per_day_usd = 25.0
outcome_learning = true

[shipwright.intelligence]
prediction_enabled = true
adversarial_enabled = false

[shipwright.github]
watch_labels = ["shipwright", "ready-to-build"]
auto_merge = false

[[shipwright.repos]]
path = "/home/user/projects/my-app"
owner = "myorg"
repo = "my-app"
template = "autonomous"
max_parallel = 2
```

Hot-reload via filesystem watcher — changes apply without restart.

## CLI

```
skipper shipwright pipeline start --issue 42
skipper shipwright pipeline resume
skipper shipwright pipeline status

skipper shipwright decide run [--dry-run]
skipper shipwright decide candidates
skipper shipwright decide halt / resume

skipper shipwright fleet start / status
skipper shipwright fleet discover --org myorg

skipper shipwright memory show / search / import
skipper shipwright dora
skipper shipwright cost show
skipper shipwright doctor
```

## Dashboard Pages

6 pages added to Skipper's SPA dashboard:

| Page         | Route                      | Content                                |
| ------------ | -------------------------- | -------------------------------------- |
| Pipelines    | `/shipwright/pipelines`    | Active/completed, stage progress, cost |
| Fleet        | `/shipwright/fleet`        | Multi-repo status, worker allocation   |
| Decisions    | `/shipwright/decisions`    | Candidates, scores, tiers, outcomes    |
| DORA         | `/shipwright/dora`         | Lead time, deploy frequency, CFR, MTTR |
| Memory       | `/shipwright/memory`       | Failure patterns, search, architecture |
| Intelligence | `/shipwright/intelligence` | Risk predictions, hotspots, anomalies  |

## API Endpoints

```
GET  /api/shipwright/pipelines
POST /api/shipwright/pipelines
GET  /api/shipwright/pipelines/{id}
GET  /api/shipwright/pipelines/{id}/ws
POST /api/shipwright/decide/run
GET  /api/shipwright/decide/candidates
GET  /api/shipwright/fleet/status
GET  /api/shipwright/dora/{repo}
GET  /api/shipwright/memory/search?q=...
```

## Build Sequence

| Phase | Module          | Depends On                         | Deliverable                                     |
| ----- | --------------- | ---------------------------------- | ----------------------------------------------- |
| 1     | `config.rs`     | —                                  | TOML config parsing                             |
| 2     | `github/`       | config                             | GitHub API client                               |
| 3     | `memory/`       | config                             | Vector memory, migration                        |
| 4     | `pipeline/`     | config, github, memory             | 12-stage engine, templates, self-healing        |
| 5     | `decision/`     | config, github, memory, pipeline   | Signals, scoring, tiers, Hand cross-pollination |
| 6     | `intelligence/` | config, github, memory             | DORA, prediction, self-optimization             |
| 7     | `fleet/`        | config, github, pipeline, decision | Daemon, multi-repo, auto-scaling, patrol        |
| 8     | `hand.rs`       | all modules                        | Hand definition, HAND.toml, SKILL.md            |
| 9     | CLI + API       | all modules                        | Subcommands, REST/WS endpoints                  |
| 10    | Dashboard       | API                                | 6 SPA pages                                     |

## Testing Strategy

- Unit tests per module with mock GitHub API and mock kernel
- Integration tests for full pipeline lifecycle
- Match Skipper standards: zero Clippy warnings, doc comments on all public types
- Test Hand cross-pollination (Collector → Decision → Pipeline)

## Migration Path

1. Fork & build: `cargo build --release`
2. Import memory: `skipper shipwright memory import --jsonl ~/.shipwright/memory/`
3. Configure repos in `skipper.toml`
4. Activate Hand: `skipper hand activate shipwright`
5. Start: `skipper start`

Existing bash Shipwright continues to work independently.
