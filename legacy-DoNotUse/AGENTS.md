# Agent Instructions (Codex Self-Contained)

Use centralized standards as source of truth:

- /Users/ericziegler/code/standards/ai-agent-standards/core/core-policy.md
- /Users/ericziegler/code/standards/ai-agent-standards/adapters/codex-adapter.md
- /Users/ericziegler/code/standards/ai-agent-standards/repo-overrides/shipwright.md
- /Users/ericziegler/code/standards/ai-agent-standards/resolution/profile-resolution-matrix.md
- /Users/ericziegler/code/standards/ai-agent-standards/resolution/shipwright-detection-contract.md

Default profile eligibility for this repo: shipwright.
Shipwright profile is conditional per detection contract.

Canonical source of truth:

- /Users/ericziegler/code/standards/ai-agent-standards

This file is self-contained for Codex and inlines critical directives.
Generated source snapshot:

- .ai-standards/generated/codex-instructions.md

## Critical Rules (Inlined)

- Do not use `sleep` or `timeout` as polling/synchronization mechanisms.
- Timeouts/sleeps are allowed only as failsafe bounds to prevent unbounded execution.
- In test code, fixed sleeps are last resort only and require justification in context.
- Always load mandatory baseline items from the resolution matrix on every turn.

## Repo-Specific Additions (Preserved)

# Repo-Specific Codex Additions

Add repo-local instructions here. This file is preserved across installs.

## BEGIN GENERATED STANDARDS (DO NOT EDIT IN PLACE)

# Generated Codex Instructions

Generated from central standards repository.

- Repo key: shipwright
- Repo override: repo-overrides/shipwright.md
- Default profiles: shipwright

## Mandatory Baseline (Always Load)

- core/core-policy.md
- core/testing-baseline.md
- adapters/codex-adapter.md
- repo-overrides/shipwright.md

### core/core-policy.md

# Core Policy

This is the shared, tool-agnostic policy baseline for Codex, Claude, and Copilot.

## Priorities

1. Safety and data integrity first.
2. Solve user-requested outcomes end-to-end.
3. Use deterministic, verifiable workflows.
4. Keep instructions DRY: update central docs, not repo-local duplicates.

## Rule Priority and Exceptions

- Use normative wording consistently.
- `MUST` defines mandatory behavior.
- `SHOULD` defines the default behavior; deviations require explicit justification.
- `MAY` defines optional behavior.
- Exception clauses override base rules only in their explicitly named context.

## Minimum Workflow

1. Understand scope and constraints.
2. Inspect existing implementation before edits.
3. Make targeted changes.
4. Run relevant validation/tests.
5. Summarize outcomes, risks, and next actions.

## Source of Truth

- Central standards: `~/code/standards/ai-agent-standards`
- Repo wrappers are thin entrypoints only.

### core/testing-baseline.md

# Testing Baseline

- Prefer targeted checks first, then broader regression as required.
- Report what was run and what was not run.
- Treat failing tests as signals; identify whether failures are pre-existing or introduced.
- Do not use `sleep` or `timeout` as polling/synchronization mechanisms.
- Timeouts/sleeps are allowed only as failsafe bounds to prevent unbounded execution.
- In test code, fixed sleeps are last resort only and require justification in context.

### adapters/codex-adapter.md

# Adapter: Codex

Use with repo `AGENTS.md` as a self-contained prompt file.

- Always load mandatory baseline items from the resolution matrix on every turn.
- `AGENTS.md` MUST inline critical rules and must not be pointer-only for required behavior.
- Generated Codex instructions may be used as the source for `AGENTS.md`, but critical rules must appear directly in `AGENTS.md`.
- Prefer practical, repository-grounded execution.
- Keep updates concise and explicit.

### repo-overrides/shipwright.md

# Repo Override: shipwright

- Platform: Shell/Node orchestration and operational workflows.
- Shipwright profile is generally active by repo context.

## Legacy Detail (Restored for Parity)

# Shipwright

Shipwright orchestrates autonomous Claude Code agent teams with delivery pipelines, daemon-driven issue processing, fleet operations across multiple repos, persistent memory, DORA metrics, cost intelligence, and repo preparation. CLI aliases `shipwright` and `sw` work identically.

## Commands

100+ commands organized by workflow. CLI aliases `shipwright` and `sw` work identically.

### Core Workflow

| Command                                            | Purpose                                           |
| -------------------------------------------------- | ------------------------------------------------- |
| `shipwright pipeline start --issue <N>`            | Full delivery pipeline for an issue               |
| `shipwright pipeline start --issue <N> --worktree` | Pipeline in isolated git worktree (parallel-safe) |
| `shipwright pipeline start --goal "..."`           | Pipeline from a goal description                  |
| `shipwright pipeline resume`                       | Resume from last stage                            |
| `shipwright loop "<goal>" --test-cmd "..."`        | Continuous autonomous agent loop                  |
| `shipwright daemon start`                          | Watch repo for labeled issues, auto-process       |
| `shipwright daemon start --detach`                 | Start daemon in background tmux session           |
| `shipwright daemon metrics`                        | DORA/DX metrics dashboard                         |
| `shipwright autonomous <cmd>`                      | AI-building-AI master controller                  |

### Agent Management

| Command                                   | Purpose                                    |
| ----------------------------------------- | ------------------------------------------ |
| `shipwright swarm <cmd>`                  | Dynamic agent swarm orchestration          |
| `shipwright recruit <cmd>`                | Agent recruitment & talent management      |
| `shipwright standup`                      | Automated daily standups for AI teams      |
| `shipwright guild <cmd>`                  | Knowledge guilds & cross-team learning     |
| `shipwright oversight <cmd>`              | Quality oversight board                    |
| `shipwright pm <cmd>`                     | Autonomous PM agent for team orchestration |
| `shipwright team-stages <cmd>`            | Multi-agent execution with roles           |
| `shipwright session <name> -t <template>` | Create team session with agent panes       |
| `shipwright scale <cmd>`                  | Dynamic agent team scaling                 |

### Quality & Review

| Command                     | Purpose                                  |
| --------------------------- | ---------------------------------------- |
| `shipwright code-review`    | Clean code & architecture analysis       |
| `shipwright security-audit` | Comprehensive security auditing          |
| `shipwright testgen`        | Autonomous test generation & coverage    |
| `shipwright hygiene`        | Repository organization & cleanup        |
| `shipwright adversarial`    | Red-team code review & edge case finding |
| `shipwright simulation`     | Multi-persona developer simulation       |
| `shipwright architecture`   | Living architecture model & enforcement  |
| `shipwright quality <cmd>`  | Intelligent completion audits            |

### Observability & Monitoring

| Command                           | Purpose                                    |
| --------------------------------- | ------------------------------------------ |
| `shipwright vitals`               | Pipeline vitals — real-time health scoring |
| `shipwright dora`                 | DORA metrics dashboard with intelligence   |
| `shipwright retro`                | Sprint retrospective engine                |
| `shipwright stream`               | Live terminal output streaming from panes  |
| `shipwright activity`             | Live agent activity stream                 |
| `shipwright replay`               | Pipeline run replay & timeline viewing     |
| `shipwright status`               | Team dashboard                             |
| `shipwright logs <team> --follow` | Tail agent logs                            |
| `shipwright ps`                   | Show running agent processes               |
| `shipwright heartbeat list`       | Show agent heartbeat status                |

### Release & Deployment

| Command                           | Purpose                                                   |
| --------------------------------- | --------------------------------------------------------- |
| `shipwright release`              | Release train automation                                  |
| `shipwright release build`        | Build release tarballs (darwin/linux) for GitHub Releases |
| `shipwright release-manager`      | Autonomous release pipeline                               |
| `shipwright changelog`            | Automated release notes & migration guides                |
| `shipwright version bump <x.y.z>` | Bump version everywhere (scripts, README, package.json)   |
| `shipwright version check`        | Verify version consistency (CI / before release)          |
| `shipwright deploys list`         | List GitHub deployments by environment                    |
| `shipwright durable <cmd>`        | Durable workflow engine for long-running ops              |

### Intelligence & Optimization

| Command                   | Purpose                                        |
| ------------------------- | ---------------------------------------------- |
| `shipwright intelligence` | Run intelligence engine analysis               |
| `shipwright predict`      | Predictive risk assessment & anomaly detection |
| `shipwright strategic`    | Strategic intelligence agent                   |
| `shipwright optimize`     | Self-optimization based on DORA metrics        |
| `shipwright model-router` | Intelligent model routing & cost optimization  |
| `shipwright adaptive`     | Data-driven pipeline tuning                    |

### Issue & Ticket Management

| Command                            | Purpose                                     |
| ---------------------------------- | ------------------------------------------- |
| `shipwright triage`                | Intelligent issue labeling & prioritization |
| `shipwright decompose --issue <N>` | AI-split complex features into subtasks     |
| `shipwright tracker <cmd>`         | Provider router for tracker integration     |
| `shipwright jira <cmd>`            | Jira ↔ GitHub bidirectional sync            |
| `shipwright linear <cmd>`          | Linear ↔ GitHub bidirectional sync          |
| `shipwright pr`                    | Autonomous PR management                    |

### Infrastructure & Operations

| Command                                   | Purpose                                         |
| ----------------------------------------- | ----------------------------------------------- |
| `shipwright fleet start`                  | Multi-repo daemon orchestration                 |
| `shipwright fleet discover --org <org>`   | Auto-discovery of repos in GitHub org           |
| `shipwright fleet-viz`                    | Multi-repo fleet visualization                  |
| `shipwright fix "<goal>" --repos <paths>` | Bulk fix across multiple repos in parallel      |
| `shipwright remote list`                  | Show registered remote machines                 |
| `shipwright remote add <name> --host <h>` | Register a remote worker machine                |
| `shipwright remote status`                | Health check all remote machines                |
| `shipwright connect start`                | Sync local state to team dashboard              |
| `shipwright connect join --token <t>`     | Join a team using an invite token               |
| `shipwright connect status`               | Show connection status                          |
| `shipwright dashboard`                    | Real-time web dashboard                         |
| `shipwright dashboard start`              | Start dashboard in background                   |
| `shipwright public-dashboard`             | Public real-time pipeline progress              |
| `shipwright mission-control`              | Terminal-based pipeline mission control         |
| `shipwright launchd install`              | Auto-start daemon + dashboard + connect on boot |

### GitHub & CI/CD

| Command                       | Purpose                                         |
| ----------------------------- | ----------------------------------------------- |
| `shipwright ci <cmd>`         | GitHub Actions CI/CD orchestration              |
| `shipwright github-app <cmd>` | GitHub App management & webhook receiver        |
| `shipwright webhook <cmd>`    | GitHub webhook receiver for instant processing  |
| `shipwright checks list`      | List GitHub Check runs for a commit             |
| `shipwright github context`   | Show repo GitHub context                        |
| `shipwright github security`  | CodeQL + Dependabot security alerts             |
| `shipwright trace`            | E2E traceability (Issue → Commit → PR → Deploy) |
| `shipwright instrument`       | Pipeline instrumentation & feedback loops       |

### Data, Learning & Memory

| Command                               | Purpose                                    |
| ------------------------------------- | ------------------------------------------ |
| `shipwright memory show`              | View captured failure patterns & learnings |
| `shipwright cost show`                | Token usage and spending dashboard         |
| `shipwright cost budget set <amount>` | Set daily budget limit                     |
| `shipwright db <cmd>`                 | SQLite persistence layer management        |
| `shipwright eventbus subscribe`       | Subscribe to real-time events by type      |
| `shipwright eventbus reaper`          | Clean up expired/consumed events           |
| `shipwright eventbus watch`           | Live event stream viewer                   |
| `shipwright eventbus replay`          | Replay events from a time range            |
| `shipwright eventbus status`          | Show bus health and pending event counts   |
| `shipwright eventbus clean`           | Purge old events beyond retention window   |
| `shipwright discovery <cmd>`          | Cross-pipeline real-time learning          |
| `shipwright feedback <cmd>`           | Production feedback loop                   |
| `shipwright regression`               | Regression detection pipeline              |
| `shipwright otel`                     | OpenTelemetry observability                |

### Setup, Maintenance & Configuration

| Command                               | Purpose                                    |
| ------------------------------------- | ------------------------------------------ |
| `shipwright init`                     | One-command tmux setup                     |
| `shipwright setup`                    | Guided setup — prerequisites, init, doctor |
| `shipwright prep`                     | Analyze repo and generate .claude/ configs |
| `shipwright doctor`                   | Validate setup and diagnose issues         |
| `shipwright upgrade --apply`          | Pull latest and apply updates              |
| `shipwright cleanup --force`          | Kill orphaned sessions                     |
| `shipwright reaper --watch`           | Automatic pane cleanup when agents exit    |
| `shipwright worktree create <branch>` | Git worktree for agent isolation           |
| `shipwright templates list`           | Browse team templates                      |
| `shipwright docs <cmd>`               | Documentation keeper                       |
| `shipwright docs-agent`               | Auto-sync README, wiki, API docs           |
| `shipwright tmux <cmd>`               | tmux health & plugin management            |
| `shipwright tmux-pipeline`            | Spawn and manage pipelines in tmux         |
| `shipwright checkpoint list`          | Show saved pipeline checkpoints            |
| `shipwright auth <cmd>`               | GitHub OAuth authentication                |
| `shipwright incident <cmd>`           | Autonomous incident detection & response   |

### Advanced & Experimental

| Command                       | Purpose                                |
| ----------------------------- | -------------------------------------- |
| `shipwright e2e-orchestrator` | Test suite registry & execution        |
| `shipwright ux`               | Premium UX enhancement layer           |
| `shipwright widgets`          | Embeddable status widgets              |
| `shipwright context gather`   | Assemble rich context for stages       |
| `shipwright deps <cmd>`       | Automated dependency update management |

## Pipeline Stages

12 stages, each can be enabled/disabled and gated (auto-proceed or pause for approval):

```
intake → plan → design → build → test → review → compound_quality → pr → merge → deploy → validate → monitor
```

The build stage delegates to `shipwright loop` for autonomous multi-iteration development. Self-healing: when tests fail, the pipeline re-enters the build loop with error context.

### Build Loop Capabilities

- **Session restart** (`--max-restarts N`): When the loop exhausts iterations without completing, it restarts with a fresh Claude session that reads progress from `progress.md`. Git state = resume point. Default 0 (off) for manual, 3 for daemon.
- **Progress persistence**: `progress.md` written after each iteration with goal, iteration count, test status, recent commits, changed files. Fresh sessions orient from this file.
- **Structured error feedback**: `error-summary.json` written after test failures with machine-readable error lines. Injected into the next iteration prompt as structured context.
- **Fast test mode** (`--fast-test-cmd "cmd"`): Alternates between a fast subset test and the full suite. Full test runs on iteration 1, every N iterations (`--fast-test-interval`, default 5), and the final iteration.
- **Agent roles** (`--roles "builder,reviewer,tester"`): In multi-agent mode, assigns specialization per agent. Built-in roles: `builder`, `reviewer`, `tester`, `optimizer`, `docs`, `security`.
- **Context exhaustion detection**: When the daemon detects a build loop failed due to iteration exhaustion (not a code error), it tags the failure as `context_exhaustion` and boosts `--max-restarts` on retry.

## Pipeline Templates

| Template     | Stages                                     | Gates                             | Use Case                 |
| ------------ | ------------------------------------------ | --------------------------------- | ------------------------ |
| `fast`       | intake → build → test → PR                 | all auto                          | Quick fixes              |
| `standard`   | intake → plan → build → test → review → PR | approve: plan, review, pr         | Normal feature work      |
| `full`       | all stages                                 | approve: plan, review, pr, deploy | Production deployment    |
| `hotfix`     | intake → build → test → PR                 | all auto                          | Urgent production fixes  |
| `autonomous` | all stages                                 | all auto                          | Daemon-driven delivery   |
| `enterprise` | all stages                                 | all approve, auto-rollback        | Maximum safety           |
| `cost-aware` | all stages                                 | all auto, budget checks           | Budget-limited delivery  |
| `deployed`   | all + deploy + validate + monitor          | approve: deploy                   | Full deploy + monitoring |

## Autonomous Agents in v2.0.0

**Wave 1 (Organizational Agents):**

| Agent              | Command   | Purpose                                               |
| ------------------ | --------- | ----------------------------------------------------- |
| Swarm Manager      | `swarm`   | Dynamic agent team orchestration, role specialization |
| Autonomous PM      | `pm`      | Team leadership, task scheduling, roadmap execution   |
| Knowledge Guild    | `guild`   | Cross-team learning, pattern capture, mentorship      |
| Recruitment System | `recruit` | Talent acquisition, team composition optimization     |
| Standup Automaton  | `standup` | Daily standups, progress tracking, blocker detection  |

**Wave 2 (Operational Backbone):**

| Agent                  | Command                   | Purpose                                              |
| ---------------------- | ------------------------- | ---------------------------------------------------- |
| Quality Oversight      | `oversight`               | Intelligent audits, zero-defect gates, completeness  |
| Strategic Agent        | `strategic`               | Long-term planning, goal decomposition, roadmap      |
| Code Reviewer          | `code-review`             | Architecture analysis, clean code, best practices    |
| Security Auditor       | `security-audit`          | Vulnerability detection, threat modeling, compliance |
| Test Generator         | `testgen`                 | Coverage analysis, scenario discovery, regression    |
| Incident Commander     | `incident`                | Autonomous triage, root cause, resolution            |
| Dependency Manager     | `deps`                    | Semantic versioning, updates, compatibility          |
| Release Manager        | `release-manager`         | Release planning, changelog, deployment              |
| Adaptive Tuner         | `adaptive`                | DORA metrics, self-optimization, performance         |
| Strategic Intelligence | (integrated in `predict`) | Predictive analysis, trend detection                 |

Each agent spawns specialized Claude Code sessions with domain-specific instructions. Agents coordinate via the task list and persistent memory.

## Local Mode

Run Shipwright entirely offline (no GitHub) for development and testing:

```bash
# Full pipeline without GitHub
shipwright pipeline start --goal "build auth module" --local

# Daemon mode locally
shipwright daemon start --no-github

# What works offline
- All 12 pipeline stages execute
- Intelligence layer operates
- Cost tracking (estimated)
- Memory system (local only)
- Agent teams
- Test execution
- Output to ~/.shipwright/local-artifacts/

# What requires --skip or degrades gracefully
- GitHub PR creation — skipped, saved to .claude/pr-draft.md
- Deployment tracking — skipped
- GitHub checks — skipped
- Contributor analysis — uses local git history only
- Security alerts — local scanning only
- CODEOWNERS — read from repo if present
```

Enable via config:

```json
{
  "local_mode": true,
  "skip_github": true,
  "offline_enabled": true
}
```

Or environment variables:

```bash
export SHIPWRIGHT_LOCAL=1
export NO_GITHUB=1
```

## Multi-Repo Operations

### Fleet Mode

Run daemon across multiple repositories with shared worker pool:

```bash
# Initialize fleet
shipwright fleet start

# Auto-discover repos in GitHub org
shipwright fleet discover --org myorg --language go,python

# Visualize fleet state
shipwright fleet-viz

# View fleet dashboard
shipwright dashboard --fleet

# Config at .claude/fleet-config.json
{
  "worker_pool": {
    "enabled": true,
    "total_workers": 12,
    "rebalance_interval_seconds": 120
  },
  "repos": [
    {
      "path": "/path/to/repo1",
      "priority": 1,
      "auto_sync": true,
      "labels": ["shipwright"]
    }
  ]
}
```

Worker pool scales across repos proportionally to queue depth and issue complexity.

### Bulk Fix Across Repos

Apply the same fix to multiple repositories in parallel:

```bash
# Single fix across many repos
shipwright fix "upgrade Go to 1.21" --repos \
  ~/projects/api,~/projects/cli,~/projects/sdk

# With custom test command per repo type
shipwright fix "add license header" \
  --repos ~/a,~/b,~/c \
  --test-cmd "npm test"

# With worktree isolation (true parallelism)
shipwright fix "refactor logging" \
  --repos ~/a,~/b,~/c \
  --worktree
```

Output:

```
Fix Results Across 3 Repos
  ~/projects/api     ✓ MERGED   (1 PR)
  ~/projects/cli     ✓ MERGED   (1 PR)
  ~/projects/sdk     ✓ MERGED   (1 PR)

Total: 3 PRs merged, $0.47 cost
```

### Per-Repo Pipeline Override

Control pipeline behavior per repository:

```bash
# Via environment
export SHIPWRIGHT_PIPELINE_TEMPLATE=fast     # global
export REPO_a_TEMPLATE=full                  # repo-specific

# Via fleet-config.json
{
  "repos": [
    {
      "path": "/path/to/repo",
      "pipeline_template": "full",
      "max_parallel_builds": 1,
      "auto_merge": false,
      "labels": ["shipwright", "gated"]
    }
  ]
}
```

### Distributed Execution

Execute pipeline steps on remote machines:

```bash
# Register remote worker
shipwright remote add builder-1 --host 192.168.1.50

# View health
shipwright remote status

# Configure in daemon-config.json
{
  "remote": {
    "enabled": true,
    "machines": ["builder-1", "builder-2"],
    "load_balance": true
  }
}
```

The daemon routes builds to remote workers, syncing state atomically.

## Team Patterns

- Assign each agent **different files** to avoid merge conflicts
- Use `--worktree` for file isolation between agents running concurrently
- Keep tasks self-contained — 5-6 focused tasks per agent
- Use the task list for coordination, not direct messaging
- 25 team templates cover the full SDLC: `shipwright templates list`
- Agents from Wave 1 coordinate Wave 2 specialists via PM agent

## tmux Integration

Shipwright includes a production tmux configuration optimized for Claude Code TUI compatibility, agent team workflows, and multi-pane management.

### Key Bindings

| Binding           | Action                                |
| ----------------- | ------------------------------------- |
| `prefix + T`      | Launch Shipwright team session        |
| `prefix + Ctrl-t` | Team dashboard in floating popup      |
| `prefix + G`      | Toggle zoom on current pane           |
| `prefix + g`      | Display pane numbers (type to select) |
| `prefix + F`      | Floating popup terminal               |
| `prefix + C-f`    | FZF session switcher                  |
| `prefix + M-1`    | Horizontal layout (leader 65% left)   |
| `prefix + M-2`    | Vertical layout (leader 60% top)      |
| `prefix + M-3`    | Tiled layout (equal sizes)            |
| `prefix + M-s`    | Capture current pane to file          |
| `prefix + M-a`    | Capture all panes to files            |
| `prefix + M-d`    | Full dashboard popup                  |
| `prefix + M-m`    | Memory system popup                   |
| `prefix + R`      | Reap dead agent panes                 |
| `prefix + S`      | Sync panes (toggle)                   |

### Claude Code Compatibility

| Setting             | Value    | Why                                                  |
| ------------------- | -------- | ---------------------------------------------------- |
| `allow-passthrough` | `on`     | DEC 2026 synchronized output — eliminates flicker    |
| `extended-keys`     | `on`     | TUI apps receive modifier key combos properly        |
| `escape-time`       | `0`      | No input delay                                       |
| `history-limit`     | `250000` | Handles Claude Code's high output volume             |
| `set-clipboard`     | `on`     | Native OSC 52 clipboard (works across SSH + nesting) |
| `focus-events`      | `on`     | TUI focus tracking                                   |

### Plugins (via TPM)

| Plugin           | Purpose                                       |
| ---------------- | --------------------------------------------- |
| `tmux-sensible`  | Sensible defaults everyone agrees on          |
| `tmux-resurrect` | Persist sessions across restarts              |
| `tmux-continuum` | Auto-save every 15 min, auto-restore on start |
| `tmux-yank`      | System clipboard integration (OSC 52)         |
| `tmux-fzf`       | Fuzzy finder for sessions/windows/panes       |

### tmux Health Management

```bash
shipwright tmux doctor     # Check Claude Code compat + features
shipwright tmux install    # Install TPM + all plugins
shipwright tmux fix        # Auto-fix issues in running session
shipwright tmux reload     # Reload config
```

### Conventions

- Team windows: named `claude-<team-name>` (shows lambda icon in status bar)
- Pane titles: `<team>-<role>` (visible in pane borders via pane-border-status)
- Set pane title: `printf '\033]2;agent-name\033\\'`
- Prefix key: **Ctrl-a**
- Adapter uses pane IDs (not indices) to avoid the pane-base-index bug

## Architecture

All scripts are bash (except the dashboard server in TypeScript). Grouped by layer:

### Core Scripts

<!-- AUTO:core-scripts -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-activity.sh` | 483 | Live agent activity stream |
| `scripts/sw-adaptive.sh` | 941 | data-driven pipeline tuning |
| `scripts/sw-adversarial.sh` | 270 | Adversarial Agent Code Review |
| `scripts/sw-ai.sh` | 99 | set -euo pipefail |
| `scripts/sw-architecture-enforcer.sh` | 330 | Living Architecture Model & Enforcer |
| `scripts/sw-auth.sh` | 610 | GitHub OAuth Authentication |
| `scripts/sw-autonomous.sh` | 1064 | Master controller for AI-building-AI loop |
| `scripts/sw-changelog.sh` | 696 | Automated Release Notes & Migration Guides |
| `scripts/sw-checkpoint.sh` | 605 | Save and restore agent state mid-stage |
| `scripts/sw-ci-reset-stale-state.sh` | 50 | Rewrite stale blocking statuses to `failed`. |
| `scripts/sw-ci.sh` | 589 | GitHub Actions CI/CD Orchestration |
| `scripts/sw-cleanup.sh` | 632 | Clean up orphaned Claude team sessions & artifacts |
| `scripts/sw-code-review.sh` | 707 | Clean Code & Architecture Analysis |
| `scripts/sw-connect.sh` | 625 | Sync local state to team dashboard |
| `scripts/sw-context.sh` | 613 | Context Engine for Pipeline Stages |
| `scripts/sw-cost.sh` | 1378 | Token Usage & Cost Intelligence |
| `scripts/sw-daemon.sh` | 1529 | Autonomous GitHub Issue Watcher |
| `scripts/sw-dashboard.sh` | 523 | Fleet Command Dashboard |
| `scripts/sw-db.sh` | 1940 | SQLite Persistence Layer |
| `scripts/sw-decide.sh` | 703 | Shipwright Autonomous Decision Engine |
| `scripts/sw-decompose.sh` | 529 | Intelligent Issue Decomposition |
| `scripts/sw-deps.sh` | 533 | Automated Dependency Update Management |
| `scripts/sw-developer-simulation.sh` | 249 | Multi-Persona Developer Simulation |
| `scripts/sw-discovery.sh` | 718 | Cross-Pipeline Real-Time Learning |
| `scripts/sw-doc-fleet.sh` | 825 | Documentation Fleet Orchestrator |
| `scripts/sw-docs-agent.sh` | 525 | Auto-sync README, wiki, API docs |
| `scripts/sw-docs.sh` | 626 | Documentation Keeper |
| `scripts/sw-doctor.sh` | 1415 | Validate Shipwright setup |
| `scripts/sw-dora.sh` | 605 | DORA Metrics Dashboard with Engineering Intelligence |
| `scripts/sw-durable.sh` | 708 | Durable Workflow Engine |
| `scripts/sw-e2e-orchestrator.sh` | 536 | Test suite registry & execution |
| `scripts/sw-eventbus.sh` | 418 | Durable event bus for real-time inter-component |
| `scripts/sw-evidence.sh` | 760 | Machine-Verifiable Proof for Agent Deliveries |
| `scripts/sw-feedback.sh` | 476 | Production Feedback Loop |
| `scripts/sw-fix.sh` | 458 | Bulk Fix Across Multiple Repos |
| `scripts/sw-fleet-discover.sh` | 550 | Auto-Discovery from GitHub Orgs |
| `scripts/sw-fleet-viz.sh` | 411 | Multi-Repo Fleet Visualization |
| `scripts/sw-fleet.sh` | 1377 | Multi-Repo Daemon Orchestrator |
| `scripts/sw-guild.sh` | 556 | Knowledge Guilds & Cross-Team Learning |
| `scripts/sw-heartbeat.sh` | 342 | File-based agent heartbeat protocol |
| `scripts/sw-hello.sh` | 67 | Hello World Command |
| `scripts/sw-hygiene.sh` | 728 | Repository Organization & Cleanup |
| `scripts/sw-incident.sh` | 904 | Autonomous Incident Detection & Response |
| `scripts/sw-init.sh` | 911 | Complete setup for Shipwright + Shipwright |
| `scripts/sw-instrument.sh` | 691 | Pipeline Instrumentation & Feedback Loops |
| `scripts/sw-intelligence.sh` | 1572 | AI-Powered Analysis & Decision Engine |
| `scripts/sw-jira.sh` | 628 | Jira ↔ GitHub Bidirectional Sync |
| `scripts/sw-launchd.sh` | 703 | Process supervision (macOS + Linux) |
| `scripts/sw-linear.sh` | 643 | Linear ↔ GitHub Bidirectional Sync |
| `scripts/sw-logs.sh` | 353 | View and search agent pane logs |
| `scripts/sw-loop.sh` | 3748 | Continuous agent loop harness for Claude Code |
| `scripts/sw-memory.sh` | 2272 | Persistent Learning & Context System |
| `scripts/sw-mission-control.sh` | 473 | Terminal-based pipeline mission control |
| `scripts/sw-model-router.sh` | 606 | Intelligent Model Routing & Cost Optimization |
| `scripts/sw-otel.sh` | 625 | OpenTelemetry Observability |
| `scripts/sw-oversight.sh` | 757 | Quality Oversight Board |
| `scripts/sw-patrol-meta.sh` | 445 | Shipwright Self-Improvement Patrol |
| `scripts/sw-pipeline-composer.sh` | 444 | Dynamic Pipeline Composition |
| `scripts/sw-pipeline-vitals.sh` | 1086 | Pipeline Vitals Engine |
| `scripts/sw-pipeline.sh` | 4309 | Autonomous Feature Delivery (Idea → Production) |
| `scripts/sw-pm.sh` | 754 | Autonomous PM Agent for Team Orchestration |
| `scripts/sw-pr-lifecycle.sh` | 698 | Autonomous PR Management |
| `scripts/sw-predictive.sh` | 857 | Predictive & Proactive Intelligence |
| `scripts/sw-prep.sh` | 1656 | Repository Preparation for Agent Teams |
| `scripts/sw-ps.sh` | 178 | Show running agent process status |
| `scripts/sw-public-dashboard.sh` | 807 | Public real-time pipeline progress |
| `scripts/sw-quality.sh` | 676 | Intelligent completion, audits, zero auto |
| `scripts/sw-reaper.sh` | 408 | Automatic tmux pane cleanup when agents exit |
| `scripts/sw-recruit.sh` | 2644 | AGI-Level Agent Recruitment & Talent Management |
| `scripts/sw-regression.sh` | 632 | Regression Detection Pipeline |
| `scripts/sw-release-manager.sh` | 721 | Autonomous Release Pipeline |
| `scripts/sw-release.sh` | 701 | Release train automation |
| `scripts/sw-remote.sh` | 670 | Machine Registry & Remote Daemon Management |
| `scripts/sw-replay.sh` | 542 | Pipeline run replay, timeline viewing, narratives |
| `scripts/sw-retro.sh` | 820 | Sprint Retrospective Engine |
| `scripts/sw-review-rerun.sh` | 222 | Canonical Rerun Comment Writer |
| `scripts/sw-scale.sh` | 625 | Dynamic agent team scaling during pipeline execution |
| `scripts/sw-security-audit.sh` | 520 | Comprehensive Security Auditing |
| `scripts/sw-self-optimize.sh` | 1717 | Learning & Self-Tuning System |
| `scripts/sw-session.sh` | 553 | Launch a Claude Code team session in a new tmux window |
| `scripts/sw-setup.sh` | 376 | Comprehensive onboarding wizard |
| `scripts/sw-standup.sh` | 721 | Automated Daily Standups for AI Agent Teams |
| `scripts/sw-status.sh` | 869 | Dashboard showing Claude Code team status |
| `scripts/sw-strategic.sh` | 943 | Strategic Intelligence Agent |
| `scripts/sw-stream.sh` | 467 | Live terminal output streaming from agent panes |
| `scripts/sw-swarm.sh` | 826 | Dynamic agent swarm management |
| `scripts/sw-team-stages.sh` | 510 | Multi-agent execution with leader/specialist roles |
| `scripts/sw-templates.sh` | 254 | Browse and inspect team templates |
| `scripts/sw-testgen.sh` | 567 | Autonomous test generation and coverage maintenance |
| `scripts/sw-tmux-pipeline.sh` | 538 | Spawn and manage pipelines in tmux windows |
| `scripts/sw-tmux-role-color.sh` | 81 | Set pane border color by agent role |
| `scripts/sw-tmux-status.sh` | 153 | Status bar widgets for tmux |
| `scripts/sw-tmux.sh` | 625 | tmux Health & Plugin Management |
| `scripts/sw-trace.sh` | 490 | E2E Traceability (Issue → Commit → PR → Deploy) |
| `scripts/sw-tracker.sh` | 517 | Provider Router for Issue Tracker Integration |
| `scripts/sw-triage.sh` | 823 | Intelligent Issue Labeling & Prioritization |
| `scripts/sw-upgrade.sh` | 491 | Detect and apply updates from the repo |
| `scripts/sw-ux.sh` | 685 | Premium UX Enhancement Layer |
| `scripts/sw-webhook.sh` | 631 | GitHub Webhook Receiver for Instant Issue Processing |
| `scripts/sw-widgets.sh` | 538 | Embeddable Status Widgets |
| `scripts/sw-worktree.sh` | 421 | Git worktree management for multi-agent isolation |
| `scripts/sw` | 621 | CLI router — dispatches subcommands via exec |
<!-- /AUTO:core-scripts -->

### GitHub API Modules

<!-- AUTO:github-modules -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-github-app.sh` | 585 | GitHub App Management & Webhook Receiver |
| `scripts/sw-github-checks.sh` | 511 | Native GitHub Checks API Integration |
| `scripts/sw-github-deploy.sh` | 523 | Native GitHub Deployments API Integration |
| `scripts/sw-github-graphql.sh` | 965 | GitHub GraphQL API Client |
<!-- /AUTO:github-modules -->

### Issue Tracker Adapters

<!-- AUTO:tracker-adapters -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-linear.sh` | 643 | Linear ↔ GitHub Bidirectional Sync |
| `scripts/sw-jira.sh` | 628 | Jira ↔ GitHub Bidirectional Sync |
| `scripts/sw-tracker-linear.sh` | 568 | do not call directly |
| `scripts/sw-tracker-jira.sh` | 474 | do not call directly |
<!-- /AUTO:tracker-adapters -->

### Shared Libraries

| File                    | Lines | Purpose                            |
| ----------------------- | ----: | ---------------------------------- |
| `scripts/lib/compat.sh` |     — | Cross-platform compatibility shims |

### Test Suites

<!-- AUTO:test-suites -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-activity-test.sh` | 219 | Validate live agent activity stream |
| `scripts/sw-adapters-test.sh` | 197 | Structural/smoke tests for terminal & deploy |
| `scripts/sw-adaptive-test.sh` | 206 | Validate data-driven pipeline tuning |
| `scripts/sw-adversarial-test.sh` | 258 | Validate adversarial agent code review |
| `scripts/sw-agi-roadmap-test.sh` | 872 | Tests every feature we implemented |
| `scripts/sw-ai-provider-test.sh` | 86 | Router + adapter normalization tests |
| `scripts/sw-ai-test.sh` | 68 |  |
| `scripts/sw-architecture-enforcer-test.sh` | 301 | Validate architecture model |
| `scripts/sw-auth-test.sh` | 150 | Validate OAuth authentication commands |
| `scripts/sw-autonomous-e2e-test.sh` | 293 | Autonomous Loop E2E Test |
| `scripts/sw-autonomous-test.sh` | 207 | AI-building-AI master controller tests |
| `scripts/sw-budget-chaos-test.sh` | 252 | Budget Exhaustion & Chaos Tests |
| `scripts/sw-build-prompt-memory-guard-test.sh` | 165 |  |
| `scripts/sw-changelog-test.sh` | 201 | Validate release notes generation |
| `scripts/sw-chaos-test.sh` | 387 | Fault injection & recovery validation |
| `scripts/sw-checkpoint-test.sh` | 341 | Validate checkpoint save/restore |
| `scripts/sw-ci-reset-stale-state-test.sh` | 179 | Unit tests |
| `scripts/sw-ci-test.sh` | 198 | GitHub Actions CI/CD orchestration tests |
| `scripts/sw-cleanup-test.sh` | 178 | Clean up orphaned sessions & artifacts |
| `scripts/sw-code-review-test.sh` | 174 | Clean code & architecture analysis tests |
| `scripts/sw-connect-test.sh` | 882 | Validate dashboard connection, heartbeat |
| `scripts/sw-context-test.sh` | 219 | Context Engine for Pipeline Stages tests |
| `scripts/sw-cost-test.sh` | 968 | Validate token usage & cost intelligence |
| `scripts/sw-cross-repo-isolation-test.sh` | 424 | Issue #425 |
| `scripts/sw-daemon-test.sh` | 2205 | Unit tests for daemon metrics, health, alerting |
| `scripts/sw-dashboard-e2e-test.sh` | 595 | full live validation |
| `scripts/sw-dashboard-test.sh` | 250 | validates dashboard structure |
| `scripts/sw-db-test.sh` | 971 | SQLite Persistence Layer Test Suite |
| `scripts/sw-decide-test.sh` | 576 | Unit tests for the Autonomous Decision Engine |
| `scripts/sw-decompose-test.sh` | 142 | Intelligent Issue Decomposition tests |
| `scripts/sw-deps-test.sh` | 165 | Automated Dependency Update Management tests |
| `scripts/sw-developer-simulation-test.sh` | 262 | Validate multi-persona |
| `scripts/sw-discovery-test.sh` | 210 | Cross-Pipeline Real-Time Learning tests |
| `scripts/sw-doc-fleet-test.sh` | 344 | Validate documentation fleet operations |
| `scripts/sw-docs-agent-test.sh` | 182 | Validate documentation agent operations |
| `scripts/sw-docs-test.sh` | 781 | Validate documentation keeper, AUTO sections, |
| `scripts/sw-doctor-test.sh` | 299 | Validate setup diagnostics |
| `scripts/sw-dora-test.sh` | 241 | Validate DORA metrics dashboard, DX metrics, |
| `scripts/sw-durable-test.sh` | 221 | Validate durable workflow engine |
| `scripts/sw-e2e-integration-test.sh` | 355 | Real Claude + Real GitHub |
| `scripts/sw-e2e-orchestrator-test.sh` | 157 | Test suite registry & execution |
| `scripts/sw-e2e-smoke-test.sh` | 1134 | Pipeline orchestration without API keys |
| `scripts/sw-e2e-system-test.sh` | 576 | Proves full daemon→pipeline→loop→PR flow |
| `scripts/sw-eventbus-test.sh` | 155 | Durable event bus tests |
| `scripts/sw-evidence-test.sh` | 214 | Unit tests for sw-evidence.sh |
| `scripts/sw-feedback-test.sh` | 176 | Production Feedback Loop tests |
| `scripts/sw-fix-test.sh` | 619 | Unit tests for bulk fix across repos |
| `scripts/sw-fleet-discover-test.sh` | 274 | Validate GitHub org auto-discovery, |
| `scripts/sw-fleet-test.sh` | 822 | Unit tests for fleet orchestration |
| `scripts/sw-fleet-viz-test.sh` | 278 | Validate fleet visualization dashboard, |
| `scripts/sw-frontier-test.sh` | 574 | Validate adversarial review, developer |
| `scripts/sw-gha-pipeline-test.sh` | 527 | Static validation of shipwright-pipeline.yml |
| `scripts/sw-github-app-test.sh` | 145 | Validate GitHub App management |
| `scripts/sw-github-checks-test.sh` | 535 | Validate Checks API wrapper |
| `scripts/sw-github-deploy-test.sh` | 523 | Validate Deployments API wrapper |
| `scripts/sw-github-graphql-test.sh` | 661 | Unit tests for GitHub GraphQL client |
| `scripts/sw-guild-test.sh` | 149 | Knowledge guilds & cross-team learning tests |
| `scripts/sw-heartbeat-test.sh` | 626 | Validate heartbeat lifecycle, |
| `scripts/sw-hello-test.sh` | 109 | Hello Command Test Suite |
| `scripts/sw-hygiene-test.sh` | 198 | Repository Organization & Cleanup tests |
| `scripts/sw-incident-test.sh` | 250 | Validate incident detection & response |
| `scripts/sw-init-test.sh` | 788 | E2E validation of init/setup flow |
| `scripts/sw-instrument-test.sh` | 172 | Pipeline instrumentation & feedback loops |
| `scripts/sw-integration-claude-test.sh` | 84 | Budget-limited real Claude smoke |
| `scripts/sw-intelligence-test.sh` | 823 | Unit tests for intelligence core |
| `scripts/sw-jira-test.sh` | 284 | Validate Jira ↔ GitHub bidirectional sync |
| `scripts/sw-launchd-test.sh` | 899 | Validate service management on |
| `scripts/sw-lib-audit-trail-test.sh` | 311 |  |
| `scripts/sw-lib-ci-reconcile-state-test.sh` | 236 | Unit tests |
| `scripts/sw-lib-compat-test.sh` | 297 | Unit tests for cross-platform helpers |
| `scripts/sw-lib-compound-audit-test.sh` | 795 |  |
| `scripts/sw-lib-config-test.sh` | 113 | Unit tests for centralized config reader |
| `scripts/sw-lib-cost-share-test.sh` | 311 | Validate cross-machine cost merging |
| `scripts/sw-lib-daemon-dispatch-test.sh` | 414 | Unit tests for spawn/reap/queue |
| `scripts/sw-lib-daemon-failure-test.sh` | 213 | Unit tests for failure handling |
| `scripts/sw-lib-daemon-patrol-test.sh` | 406 | Unit tests for all patrol functions |
| `scripts/sw-lib-daemon-poll-test.sh` | 344 | Unit tests for poll, health, cleanup |
| `scripts/sw-lib-daemon-state-test.sh` | 383 | Unit tests for state management |
| `scripts/sw-lib-daemon-triage-test.sh` | 267 | Unit tests for triage scoring |
| `scripts/sw-lib-error-actionability-test.sh` | 149 |  |
| `scripts/sw-lib-goal-mutation-test.sh` | 71 | issue #362 |
| `scripts/sw-lib-helpers-test.sh` | 439 | Unit tests for shared helper functions |
| `scripts/sw-lib-loop-convergence-test.sh` | 297 | Stuckness throttle (issue #447) |
| `scripts/sw-lib-loop-iteration-test.sh` | 146 | Unit tests for loop-iteration.sh |
| `scripts/sw-lib-loop-restart-test.sh` | 490 | Unit tests for loop state |
| `scripts/sw-lib-pipeline-detection-test.sh` | 497 | Unit tests for detection fns |
| `scripts/sw-lib-pipeline-github-test.sh` | 366 | Unit tests for GitHub helpers |
| `scripts/sw-lib-pipeline-intelligence-test.sh` | 1265 | Unit tests for intelligence |
| `scripts/sw-lib-pipeline-quality-checks-test.sh` | 616 | Unit tests for quality |
| `scripts/sw-lib-pipeline-stages-review-test.sh` | 589 | Unit tests for cross-stage drift detector |
| `scripts/sw-lib-pipeline-stages-test.sh` | 2691 | Unit tests for stage functions |
| `scripts/sw-lib-pipeline-state-test.sh` | 1163 | Unit tests for pipeline state |
| `scripts/sw-linear-test.sh` | 300 | Validate Linear ↔ GitHub bidirectional sync |
| `scripts/sw-logs-test.sh` | 281 | Validate agent pane log viewing, searching, |
| `scripts/sw-loop-test.sh` | 4321 | Validate continuous agent loop harness |
| `scripts/sw-memory-discovery-e2e-test.sh` | 412 | Memory & Discovery E2E Test |
| `scripts/sw-memory-test.sh` | 1095 | Unit tests for memory system & cost tracking |
| `scripts/sw-mission-control-test.sh` | 153 | Validate mission control dashboard |
| `scripts/sw-model-router-test.sh` | 188 | Intelligent model routing & optimization |
| `scripts/sw-otel-test.sh` | 146 | OpenTelemetry observability |
| `scripts/sw-oversight-test.sh` | 164 | Quality oversight board tests |
| `scripts/sw-patrol-meta-test.sh` | 306 | Validate self-improvement patrol |
| `scripts/sw-pipeline-artifact-push-test.sh` | 325 | PAT push (loop + final artifact save) |
| `scripts/sw-pipeline-composer-test.sh` | 632 | Test Suite |
| `scripts/sw-pipeline-memory-guard-test.sh` | 190 |  |
| `scripts/sw-pipeline-resume-test.sh` | 410 | Validate workflow shell logic |
| `scripts/sw-pipeline-test.sh` | 4736 | E2E validation invoking the REAL pipeline |
| `scripts/sw-pipeline-vitals-test.sh` | 226 | Validate pipeline health scoring |
| `scripts/sw-pm-test.sh` | 225 | Autonomous PM Agent test suite |
| `scripts/sw-policy-e2e-test.sh` | 290 | Verify config/policy.json is honored |
| `scripts/sw-postmortem-460-test.sh` | 1223 | Behavioral tests for pipeline hardening fixes |
| `scripts/sw-pr-lifecycle-test.sh` | 317 | Validate autonomous PR management |
| `scripts/sw-predictive-test.sh` | 755 | Unit tests for predictive intelligence |
| `scripts/sw-prep-test.sh` | 636 | Validate repo preparation |
| `scripts/sw-ps-test.sh` | 296 | Validate agent process status display |
| `scripts/sw-public-dashboard-test.sh` | 165 | Validate public dashboard generation |
| `scripts/sw-quality-test.sh` | 227 | Validate ruthless quality validation engine |
| `scripts/sw-reaper-test.sh` | 232 | Validate automatic tmux pane cleanup |
| `scripts/sw-recruit-test.sh` | 1399 | Test suite for AGI-level agent recruitment system |
| `scripts/sw-regression-test.sh` | 265 | Validate regression detection pipeline |
| `scripts/sw-release-manager-test.sh` | 206 | Validate release pipeline |
| `scripts/sw-release-test.sh` | 200 | Release train automation |
| `scripts/sw-remote-test.sh` | 396 | Validate machine registry, atomic writes, |
| `scripts/sw-replay-test.sh` | 167 | Pipeline run replay & timeline viewing |
| `scripts/sw-repo-dir-project-root-test.sh` | 363 | Regression tests for #335 |
| `scripts/sw-resume-test.sh` | 267 | TDD tests for WIP branch resume logic |
| `scripts/sw-retro-test.sh` | 171 | Sprint retrospective engine tests |
| `scripts/sw-review-rerun-test.sh` | 307 | SHA-deduped rerun comment writer |
| `scripts/sw-ruflo-adapter-test.sh` | 5452 |  |
| `scripts/sw-ruflo-benchmark-test.sh` | 269 | Validation tests for the #504 acceptance |
| `scripts/sw-ruflo-bridge-test.sh` | 293 | Mock-driven tests for the ruflo unix socket |
| `scripts/sw-ruflo-timeout-test.sh` | 282 | regression tests for ruflo_with_timeout FD hang (#426) |
| `scripts/sw-scale-test.sh` | 151 | Dynamic agent team scaling |
| `scripts/sw-security-audit-test.sh` | 163 | Security auditing tests |
| `scripts/sw-self-optimize-test.sh` | 837 | Unit tests for learning & tuning system |
| `scripts/sw-server-api-test.sh` | 714 | Dashboard Server API Test Suite |
| `scripts/sw-session-test.sh` | 605 | E2E validation of session creation flow |
| `scripts/sw-setup-test.sh` | 262 | Validate comprehensive onboarding wizard |
| `scripts/sw-snapshot-guard-test.sh` | 296 | Validates HEAD guard logic for the snapshot step |
| `scripts/sw-standup-test.sh` | 241 | Validate daily standup automation |
| `scripts/sw-status-test.sh` | 294 | Validate status dashboard and --json output |
| `scripts/sw-strategic-test.sh` | 216 | Validate strategic intelligence agent |
| `scripts/sw-stream-test.sh` | 140 | Live terminal output streaming |
| `scripts/sw-swarm-test.sh` | 261 | Dynamic agent swarm management tests |
| `scripts/sw-team-stages-test.sh` | 148 | Validate multi-agent stage execution |
| `scripts/sw-templates-test.sh` | 251 | Validate team template browser |
| `scripts/sw-testgen-test.sh` | 160 | Test generation & coverage tests |
| `scripts/sw-tmux-pipeline-test.sh` | 187 | Validate tmux pipeline management |
| `scripts/sw-tmux-test.sh` | 746 | Validate tmux doctor, install, fix, reload, |
| `scripts/sw-trace-test.sh` | 143 | E2E traceability (Issue → Commit → PR → Deploy) |
| `scripts/sw-tracker-providers-test.sh` | 552 | Unit tests for GitHub, Linear, |
| `scripts/sw-tracker-test.sh` | 534 | Validate tracker router, providers, and |
| `scripts/sw-triage-test.sh` | 296 | Intelligent Issue Labeling & Prioritization |
| `scripts/sw-upgrade-test.sh` | 334 | Validate upgrade detection and apply |
| `scripts/sw-ux-test.sh` | 185 | Validate UX enhancement layer |
| `scripts/sw-webhook-test.sh` | 167 | GitHub Webhook Receiver tests |
| `scripts/sw-widgets-test.sh` | 357 | Validate embeddable status widgets |
| `scripts/sw-worktree-test.sh` | 148 | Git worktree management for agent isolation |
<!-- /AUTO:test-suites -->

### Dashboard & Infra

| File                   | Lines | Purpose                            |
| ---------------------- | ----: | ---------------------------------- |
| `dashboard/server.ts`  |  3501 | Bun WebSocket dashboard server     |
| `dashboard/public/`    |     — | Dashboard frontend (HTML/CSS/JS)   |
| `install.sh`           |   755 | Interactive installer              |
| `templates/pipelines/` |     — | 8 pipeline template JSON files     |
| `tmux/templates/`      |     — | 25 team composition JSON templates |

### Runtime State and Artifacts

<!-- AUTO:runtime-state -->

- Pipeline state: `.claude/pipeline-state.md`
- Pipeline artifacts: `.claude/pipeline-artifacts/`
- Composed pipeline: `.claude/pipeline-artifacts/composed-pipeline.json`
- Events log: `~/.shipwright/events.jsonl`
- Daemon config: `.claude/daemon-config.json`
- Fleet config: `.claude/fleet-config.json`
- Heartbeats: `~/.shipwright/heartbeats/<job-id>.json`
- Checkpoints: `.claude/pipeline-artifacts/checkpoints/`
- Machine registry: `~/.shipwright/machines.json`
- Cost data: `~/.shipwright/costs.json, ~/.shipwright/budget.json`
- Intelligence cache: `.claude/intelligence-cache.json`
- Optimization data: `~/.shipwright/optimization/`
- Baselines: `~/.shipwright/baselines/`
- Architecture models: `~/.shipwright/memory/<repo-hash>/architecture.json`
- Team config: `~/.shipwright/team-config.json`
- Developer registry: `~/.shipwright/developer-registry.json`
- Team events: `~/.shipwright/team-events.jsonl`
- Invite tokens: `~/.shipwright/invite-tokens.json`
- Connect PID: `~/.shipwright/connect.pid`
- Connect log: `~/.shipwright/connect.log`
- GitHub cache: `~/.shipwright/github-cache/`
- Check run IDs: `.claude/pipeline-artifacts/check-run-ids.json`
- Deployment tracking: `.claude/pipeline-artifacts/deployment.json`
- Error log: `.claude/pipeline-artifacts/error-log.jsonl`
<!-- /AUTO:runtime-state -->

## GitHub Integration

The pipeline uses native GitHub APIs for CI integration, deployment tracking, and intelligent reviewer selection.

### GitHub API Modules

- **GraphQL Client** (`sw-github-graphql.sh`): Cached queries for file change frequency, blame data, contributors, similar issues, commit history, branch protection, CODEOWNERS, security alerts, Dependabot alerts, and Actions run history. All intelligence modules call through this layer.
- **Checks API** (`sw-github-checks.sh`): Creates native GitHub Check Runs per pipeline stage (visible in PR timeline). Replaces comment-based stage tracking with first-class GitHub UI integration.
- **Deployments API** (`sw-github-deploy.sh`): Tracks deployments per environment (staging/production). Enables rollback, deployment history, and environment state tracking.

### Pipeline Integration

- **Stage tracking**: Each pipeline stage creates/updates a GitHub Check Run (in addition to existing comment-based tracking)
- **Deployment tracking**: Deploy stage creates GitHub Deployment objects with status updates
- **Reviewer selection**: PR stage routes reviews to CODEOWNERS first, then top contributors, with auto-approve fallback
- **Branch protection**: Merge stage checks required reviews and status checks before attempting auto-merge
- **Intelligence enrichment**: All intelligence modules receive GitHub context (security alerts, contributor data, CI history, file churn)
- **Patrol enhancement**: Security patrol enriched with CodeQL + Dependabot alert data
- **Doctor checks**: Section 13 validates GitHub API access, scopes, GraphQL, and module installation

## Intelligence Layer

Intelligence defaults to **auto** (enabled when Claude CLI is available). Configure in `.claude/daemon-config.json` under the `intelligence` key; set `intelligence.enabled=false` to explicitly disable.

### Feature Flags

<!-- AUTO:feature-flags -->

| Flag | Default | Purpose |
| --- | --- | --- |
| `intelligence.cache_ttl_seconds` | `3600` | |
| `intelligence.adversarial_enabled` | `false` | |
| `intelligence.simulation_enabled` | `false` | |
| `intelligence.architecture_enabled` | `false` | |
| `intelligence.ab_test_ratio` | `0.2` | |
| `intelligence.anomaly_threshold` | `3.0` | |
<!-- /AUTO:feature-flags -->

### Modules

- **Intelligence Engine** (`sw-intelligence.sh`): Analyzes codebase structure, file change frequency, and test coverage to produce a cached analysis used by other modules.
- **Pipeline Composer** (`sw-pipeline-composer.sh`): Generates custom pipeline configurations by adjusting stage timeouts, iteration counts, and model routing based on intelligence output.
- **Self-Optimize** (`sw-self-optimize.sh`): Reads DORA metrics (lead time, deployment frequency, CFR, MTTR) and adjusts daemon config to improve performance over time.
- **Predictive** (`sw-predictive.sh`): Scores incoming issues for risk, detects anomalies in pipeline metrics, and provides AI patrol summaries.
- **Adversarial Review** (`sw-adversarial.sh`): Runs a second-pass adversarial review looking for edge cases, security issues, and failure modes.
- **Developer Simulation** (`sw-developer-simulation.sh`): Simulates developer workflows (clone, install, build, test) to catch UX issues.
- **Architecture Enforcer** (`sw-architecture-enforcer.sh`): Validates changes against architecture rules (dependency direction, naming conventions, layer boundaries).

### Enabling

```json
{
  "intelligence": {
    "enabled": true,
    "composer_enabled": true,
    "prediction_enabled": true
  }
}
```

The daemon calls into the intelligence layer at spawn time. The `intelligence` and `predict` CLI commands can also be run standalone.

## Custom Agents

Specialized agent definitions in `.claude/agents/` are loaded automatically by Claude Code when agents are spawned:

| Agent                   | File                         | Purpose                                                                   |
| ----------------------- | ---------------------------- | ------------------------------------------------------------------------- |
| Shell Script Specialist | `shell-script-specialist.md` | Bash 3.2 rules, pipefail safety, atomic writes, test harness patterns     |
| Code Reviewer           | `code-reviewer.md`           | Review checklist, security, performance, architecture layer boundaries    |
| Test Specialist         | `test-specialist.md`         | Test harness conventions, mock patterns, PASS/FAIL counting, coverage     |
| DevOps Engineer         | `devops-engineer.md`         | GitHub Actions, pipeline workflows, GitHub API, worktree management       |
| Pipeline Agent          | `pipeline-agent.md`          | Build loop context, memory injection, architecture rules, file hotspots   |
| Doc Fleet Agent         | `doc-fleet-agent.md`         | Documentation fleet — audit, refactor, enhance docs (5 specialized roles) |

## Hooks

Repo-level hooks in `.claude/hooks/` fire on lifecycle events. Registered in `.claude/settings.json`.

| Hook                 | Trigger                          | Purpose                                                      |
| -------------------- | -------------------------------- | ------------------------------------------------------------ |
| `pre-tool-use.sh`    | Before Edit/Write on `.sh` files | Injects bash 3.2 compatibility reminder                      |
| `post-tool-use.sh`   | After Bash tool failures         | Captures error signatures to `error-log.jsonl`               |
| `session-started.sh` | On session start                 | Shows pipeline state, recent failures, active issues, budget |

## Documentation Keeper

Auto-sync documentation from source code using HTML comment markers (`AUTO:section-id` pairs). For autonomous multi-agent documentation work, use `shipwright doc-fleet` (5 specialized agents: audit, refactor, enhance).

```bash
shipwright docs check      # Report which sections are stale (exit 1 if any)
shipwright docs sync       # Regenerate all stale AUTO sections
shipwright docs wiki       # Generate/update GitHub wiki pages
shipwright docs report     # Show documentation freshness report
```

AUTO sections in `.claude/CLAUDE.md`: `core-scripts`, `github-modules`, `tracker-adapters`, `test-suites`, `feature-flags`, `runtime-state`. The daemon patrol auto-syncs stale sections. A GitHub Actions workflow (`shipwright-docs.yml`) runs on push to main and weekly.

## Development Guidelines

### Shell Standards

- All scripts use `set -euo pipefail`
- **Bash 3.2 compatible** — no `declare -A` (associative arrays), no `readarray`, no `${var,,}` (lowercase), no `${var^^}` (uppercase)
- `VERSION` variable at top of every script — keep in sync
- Event logging: `emit_event "type" "key=val" "key2=val2"` writes to `events.jsonl`

### Output Helpers

- `info()`, `success()`, `warn()`, `error()` — standardized output
- Boxed headers with Unicode box-drawing characters

### Colors

| Name   | Hex       | Usage                          |
| ------ | --------- | ------------------------------ |
| Cyan   | `#00d4ff` | Primary accent, active borders |
| Purple | `#7c3aed` | Tertiary accent                |
| Blue   | `#0066ff` | Secondary accent               |
| Green  | `#4ade80` | Success indicators             |

### Common Pitfalls

- `grep -c || echo "0"` under pipefail produces double output — use `|| true` + `${var:-0}`
- `cmd | while read` loses variable state (subshell) — use `while read; done < <(cmd)`
- Atomic file writes: use tmp file + `mv`, not direct `echo > file`
- JSON in bash: use `jq --arg` for proper escaping, never string interpolation
- `cd` in helper functions changes caller's directory — use subshells `( cd dir && ... )`
- Check `$NO_GITHUB` in any new GitHub API features

## Maintainer / Release (which script to call)

**Prefer the CLI** so tooling and agents always use the same entry points:

| Task                                           | CLI (preferred)                   | Script (if not using CLI)              |
| ---------------------------------------------- | --------------------------------- | -------------------------------------- |
| Bump version everywhere                        | `shipwright version bump <x.y.z>` | `scripts/update-version.sh <x.y.z>`    |
| Verify version consistency                     | `shipwright version check`        | `scripts/check-version-consistency.sh` |
| Build release tarballs                         | `shipwright release build`        | `scripts/build-release.sh`             |
| Release train (tag, changelog, GitHub release) | `shipwright release publish`      | `scripts/sw-release.sh publish`        |

- **Canonical version**: `package.json` → `version`. All script `VERSION=`, README badge, and (at build time) website footer derive from it after a bump.
- **Before release**: Run `shipwright version check` (CI does this). Then bump with `shipwright version bump <x.y.z>`, add a `[x.y.z]` section to `CHANGELOG.md`, then `shipwright release publish` or tag and push for the release workflow.
- **Packaging**: `scripts/build-release.sh` is invoked by `.github/workflows/release.yml` on tag push; it reads version from `package.json` and creates `dist/shipwright-{platform}.tar.gz` and checksums. npm publish and Homebrew tap update are separate steps (see README/CHANGELOG).

## Setup & validation (everything working)

- **`shipwright doctor`** — Validates prerequisites (tmux, jq, Node, Claude CLI), installed files (overlay, hooks), PATH, pane display, env vars, and (when run from the Shipwright repo) **version consistency** (package.json vs README vs scripts). Run after install or when debugging "is my setup correct?"
- **`shipwright version check`** — Exit 0 only if version is consistent everywhere; run in CI and before release. When in the Shipwright repo, `doctor` runs this automatically.
- **`shipwright setup`** — Guided setup (four phases); **`shipwright init`** — Quick setup with no prompts. Use one of these in a new environment before using pipeline/daemon/loop.

## Test Harness

```bash
# Run all pipeline tests (mock binaries, no real Claude/GitHub calls)
./scripts/sw-pipeline-test.sh

# Run all 102 test suites
npm test
```

See the AUTO:test-suites table above for the complete list of test suites registered in `package.json`.

Each test suite uses mock binaries in a temp directory, with PASS/FAIL counters, colored output, and ERR traps.

## Conditional Directives (Always Present, Apply Only When Condition Matches)

- IF: Shipwright detection contract evaluates true
  THEN: Apply profiles/shipwright-operations.md

### profiles/shipwright-operations.md

# Profile: Shipwright Operations

Load only when Shipwright is active (see detection contract).

## Core Commands

- `shipwright status`
- `shipwright activity`
- `shipwright pipeline start --issue <N>`
- `shipwright cleanup --force` (use intentionally)

## Operational Rules

- Verify whether daemon/pipeline is already active before starting a new run.
- Use Shipwright-specific diagnostics before manual intervention.
- Treat lock/cleanup actions as explicit operations with visible logs.

### resolution/profile-resolution-matrix.md

# Profile Resolution Matrix

Always load:

1. `core/core-policy.md`
2. `core/testing-baseline.md`
3. agent adapter (`adapters/*-adapter.md`)
4. repo override (`repo-overrides/*.md`)

Conditional profile loading:

- `profiles/ui-testing-profile.md` for UI test/harness/flakiness tasks.
- `profiles/carplay-profile.md` for CarPlay tasks.
- `profiles/ios-swift-profile.md` for Swift/Xcode/iOS tasks.
- `profiles/home-assistant-yaml-profile.md` for HA YAML/entity tasks.
- `profiles/shipwright-operations.md` only when detection contract evaluates true.

### resolution/shipwright-detection-contract.md

# Shipwright Detection Contract (Lenient)

Shipwright is active if any condition is true:

1. Env marker: `SHIPWRIGHT_ACTIVE=1`
2. Repo marker file: `.shipwright/context.json` with `active=true`
3. Task contains explicit Shipwright command intent (`shipwright ...` or `sw ...`)
4. User explicitly requests Shipwright usage

If none are true, do not load `profiles/shipwright-operations.md`.

## Optional env metadata

- `SHIPWRIGHT_RUN_ID=<id>`
- `SHIPWRIGHT_SOURCE=pipeline|daemon|session`

## END GENERATED STANDARDS
