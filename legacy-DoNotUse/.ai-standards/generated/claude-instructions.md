# Generated Claude Instructions

Generated from central standards repository.
- Repo key: shipwright
- Repo override: repo-overrides/shipwright.md
- Default profiles: shipwright

## Mandatory Baseline (Always Load)
- core/core-policy.md
- core/testing-baseline.md
- adapters/claude-adapter.md
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

### adapters/claude-adapter.md
# Adapter: Claude

Use with `.claude/CLAUDE.md` thin wrappers.

- Keep imports/references minimal; avoid loading large docs by default.
- Apply profile matrix for conditional guidance.

### repo-overrides/shipwright.md
# Repo Override: shipwright

- Platform: Shell/Node orchestration and operational workflows.
- Shipwright profile is generally active by repo context.

# Shipwright

Shipwright orchestrates autonomous Claude Code agent teams with delivery pipelines, daemon-driven issue processing, fleet operations across multiple repos, persistent memory, DORA metrics, cost intelligence, and repo preparation. CLI aliases `shipwright` and `sw` work identically.

## Core Commands

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
| `shipwright status`                                | Team dashboard                                    |
| `shipwright memory show`                           | View captured failure patterns                    |
| `shipwright cost show`                             | Token usage and spending dashboard                |
| `shipwright doctor`                                | Validate setup and diagnose issues                |
| `shipwright cleanup --force`                       | Kill orphaned sessions                            |
| `shipwright worktree create <branch>`              | Git worktree for agent isolation                  |

## Pipeline Stages

12 stages, each can be enabled/disabled and gated (auto-proceed or pause for approval):

```
intake → plan → design → build → test → review → compound_quality → pr → merge → deploy → validate → monitor
```

The build stage delegates to `shipwright loop`. Self-healing: when tests fail, the pipeline re-enters the build loop with error context. Progress is persisted to `progress.md`; `error-summary.json` is injected into the next iteration prompt.

## Pipeline Templates

| Template     | Stages                                     | Gates                             | Use Case                |
| ------------ | ------------------------------------------ | --------------------------------- | ----------------------- |
| `fast`       | intake → build → test → PR                 | all auto                          | Quick fixes             |
| `standard`   | intake → plan → build → test → review → PR | approve: plan, review, pr         | Normal feature work     |
| `full`       | all stages                                 | approve: plan, review, pr, deploy | Production deployment   |
| `hotfix`     | intake → build → test → PR                 | all auto                          | Urgent production fixes |
| `autonomous` | all stages                                 | all auto                          | Daemon-driven delivery  |
| `cost-aware` | all stages                                 | all auto, budget checks           | Budget-limited delivery |

## Team Patterns

- Assign each agent **different files** to avoid merge conflicts
- Use `--worktree` for file isolation between agents running concurrently
- Keep tasks self-contained — 5-6 focused tasks per agent
- Use the task list for coordination, not direct messaging

## Runtime State

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

## Development Guidelines

### Shell Standards

- All scripts use `set -euo pipefail`
- **Bash 3.2 compatible** — no `declare -A` (associative arrays), no `readarray`, no `${var,,}` (lowercase), no `${var^^}` (uppercase)
- `VERSION` variable at top of every script — keep in sync
- Event logging: `emit_event "type" "key=val" "key2=val2"` writes to `events.jsonl`

### Output Helpers

- `info()`, `success()`, `warn()`, `error()` — standardized output
- Boxed headers with Unicode box-drawing characters

### Common Pitfalls

- `grep -c || echo "0"` under pipefail produces double output — use `|| true` + `${var:-0}`
- `cmd | while read` loses variable state (subshell) — use `while read; done < <(cmd)`
- Atomic file writes: use tmp file + `mv`, not direct `echo > file`
- JSON in bash: use `jq --arg` for proper escaping, never string interpolation
- `cd` in helper functions changes caller's directory — use subshells `( cd dir && ... )`
- Check `$NO_GITHUB` in any new GitHub API features

## Maintainer / Release

| Task                       | CLI (preferred)                   | Script (fallback)                      |
| -------------------------- | --------------------------------- | -------------------------------------- |
| Bump version everywhere    | `shipwright version bump <x.y.z>` | `scripts/update-version.sh <x.y.z>`    |
| Verify version consistency | `shipwright version check`        | `scripts/check-version-consistency.sh` |
| Build release tarballs     | `shipwright release build`        | `scripts/build-release.sh`             |
| Release train              | `shipwright release publish`      | `scripts/sw-release.sh publish`        |

Canonical version: `package.json` → `version`. Run `shipwright version check` before release.

## Setup & Validation

- **`shipwright doctor`** — Validates prerequisites, installed files, PATH, env vars, and version consistency. Run after install or when debugging setup.
- **`shipwright setup`** — Guided setup (four phases); **`shipwright init`** — Quick setup with no prompts.

## Test Harness

```bash
./scripts/sw-pipeline-test.sh   # pipeline tests (mock binaries, no real Claude/GitHub)
npm test                         # all test suites
```

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

## Build Loop: Test Execution

When `SHIPWRIGHT_SOURCE=loop`, the harness owns test execution:

- **NEVER run the full test suite yourself.** The loop runs it automatically after each iteration and injects the results into your next prompt. Xcode tests take 60–90 minutes — running them yourself exhausts your entire context window and causes a timeout.
- You MAY run a single targeted test class to validate a specific fix:
  `./scripts/run-xcode-tests.sh -t SpecificTestClass`
  Only do this for the specific failing test, not the full suite.
- After making your code changes, stop and describe what you changed. The harness will run the full suite and report back.
- When a UI test fails, read the failure details from the injected test log. Do not re-run the full suite to reproduce it — diagnose from the log and fix the code.

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
