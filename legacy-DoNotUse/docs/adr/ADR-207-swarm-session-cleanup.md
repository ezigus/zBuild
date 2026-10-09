# Design: feat: add automatic swarm session cleanup to prevent OOM accumulation

## Context

### Problem Statement

Swarm agents launched by Shipwright run as persistent tmux sessions tracked in `~/.shipwright/swarm/registry.json`. When agents become inactive or crash, their heartbeats stop updating, but their registry entries remain—each holding a tmux session that consumes memory. Over time, accumulated stale sessions cause Out-of-Memory (OOM) errors, making the system unstable and forcing manual cleanup.

### Current State

- **Agent spawning** (`scripts/sw-swarm.sh:swarm_spawn_agent`): Creates tmux session `swarm-${id}` and registers agent with `last_heartbeat` timestamp
- **Agent retirement** (`scripts/sw-swarm.sh:cmd_retire`): Removes a single agent by ID (manual operation)
- **Health checks** (`scripts/sw-swarm.sh:cmd_health`): Detects stale agents using `stall_detection_threshold` (300s) but doesn't remove them
- **Cleanup** (`scripts/sw-cleanup.sh`): Clears Claude windows and teams, but ignores swarm sessions

### Constraints

- Must be safe for concurrent operation (atomic file updates on registry)
- Must not kill actively-working agents with temporary heartbeat delays
- Must be testable without real tmux sessions (mock-friendly)
- Must integrate naturally with existing health checks and cleanup routines

---

## Decision

### Chosen Approach: TTL-Based Pruning with Auto-Cleanup from Health Checks

**Core strategy**: Implement a `prune` subcommand that removes stale agents based on elapsed time since last heartbeat, integrate it automatically into health checks for passive cleanup, and extend `sw-cleanup.sh --force` to aggressively clean all swarm sessions.

### Three-Layer Cleanup Strategy

1. **On-demand pruning** (`shipwright swarm prune`)
   - User-facing command for explicit cleanup
   - Supports `SWARM_PRUNE_TTL` environment variable to override default threshold
   - Atomically removes stale agents from registry and kills their tmux sessions

2. **Automatic pruning** (integrated into `shipwright swarm health`)
   - After health report, silently prune stale agents via `cmd_prune --quiet`
   - Passive cleanup during normal monitoring operations
   - No user action required

3. **Destructive cleanup** (`shipwright cleanup --force`)
   - Kills all `swarm-*` tmux sessions
   - Removes orphaned registry entries (sessions that no longer exist)
   - Matches existing cleanup semantics for destructive operations

### Design Principles

**Reuse, Don't Refactor**

- `cmd_prune` inlines the tmux kill + registry removal logic similar to `cmd_retire`, but doesn't extract a shared helper
- Rationale: retire and prune paths differ enough (retire warns about active tasks, prune silently removes) that DRY extraction adds complexity without clear benefit
- Impact: ~10-15 lines of duplicated code is acceptable

**Conservative Defaults**

- Use same `stall_detection_threshold` (300s) already validated by health checks
- Default behavior requires explicit `--force` flag for destructive cleanup
- Verify tmux session exists before declaring stale (handles cases where session was already killed)

**Atomic Operations**

- All registry updates use tmp file + `mv` pattern (existing Shipwright standard)
- No partial state changes on concurrent prune/spawn operations
- Each agent removal is independent (no cascading failures)

---

## Alternatives Considered

### 1. Daemon-Based Periodic Sweep

**Approach**: Add background timer to `sw-daemon.sh` that calls `prune` every N seconds

- **Pros**: Fully automated; no user action needed
- **Cons**: Daemon may not always be running; harder to test; adds complexity to daemon
- **Rejected**: Issue calls for on-demand + auto-prune from health; daemon integration is a future enhancement

### 2. Registry TTL with Automatic Expiry

**Approach**: Add `expires_at` field to registry entries; every read filters expired entries

- **Pros**: Elegant and transparent
- **Cons**: Requires modifying every registry read path (high blast radius); more invasive
- **Rejected**: Prune-on-demand achieves the goal with minimal changes

### 3. Extract Shared Helper Function

**Approach**: Create `_remove_agent()` helper, call from both `cmd_retire` and `cmd_prune`

- **Pros**: DRY principle; single point of change for removal logic
- **Cons**: Refactoring retire path risks breaking stable behavior; code paths differ (retire checks active tasks, prune doesn't)
- **Rejected**: Duplicated ~10 lines is acceptable cost vs. refactoring risk

### 4. Integration with Cluster Orchestrator

**Approach**: Delegate cleanup to external cluster manager (Kubernetes, Docker Swarm)

- **Pros**: Uses platform-native lifecycle management
- **Cons**: Assumes orchestrator exists; out of scope for Shipwright's shell-based model
- **Rejected**: Shipwright manages its own agent lifecycle locally

---

## Implementation Plan

### Files to Create/Modify

#### 1. `scripts/sw-swarm.sh` (~60 new lines)

**Change type**: Add new function + integrate into existing flow

| Aspect                 | Details                                           |
| ---------------------- | ------------------------------------------------- |
| **New function**       | `cmd_prune()` at line ~342                        |
| **Router update**      | Add `prune)` case between `health)` and `scale)`  |
| **Health integration** | Call `cmd_prune --quiet` at end of `cmd_health()` |
| **Help text**          | Add prune to help output                          |

**Function signature**:

```bash
cmd_prune([--quiet]) -> void
```

**Logic flow**:

1. Ensure registry initialized, read config for `stall_detection_threshold` (default 300s)
2. Get current epoch via `now_epoch`
3. Iterate all agents via `jq -r '.agents[] | @base64'`
4. For each agent: decode, extract `id`, `last_heartbeat`; check `now - heartbeat_epoch > threshold`
5. If stale: kill tmux session `swarm-${id}` (silent if doesn't exist), collect ID for removal
6. Atomic registry update: remove all collected stale IDs via single jq pass + tmp+mv
7. Record `prune` metric for each removed agent
8. Output summary (suppress if `--quiet`)

**Error contracts**:

- Registry missing/empty: no-op, return 0
- Invalid agent entry: skip, continue (defensive)
- Tmux kill fails: log warning, continue removal from registry (registry entry supersedes session)

#### 2. `scripts/sw-cleanup.sh` (~50 new lines)

**Change type**: Add new section for swarm cleanup

| Aspect       | Details                                                                                   |
| ------------ | ----------------------------------------------------------------------------------------- |
| **Location** | After tmux windows section (after line 224)                                               |
| **Section**  | Swarm Sessions & Registry cleanup                                                         |
| **Counters** | SWARM_SESSIONS_FOUND, SWARM_SESSIONS_KILLED, SWARM_REGISTRY_FOUND, SWARM_REGISTRY_REMOVED |

**Logic flow**:

1. Find all tmux sessions matching `swarm-*` pattern
2. If `--force`: kill each session, increment counter
3. Read registry if exists; for each entry, check if session `swarm-${id}` still exists
4. If session gone: mark as stale
5. If `--force`: remove stale entries (atomic jq update)
6. Add counters to summary output

**Error contracts**:

- Tmux command fails: log warning, continue
- Registry missing: skip registry check (OK state)
- Invalid registry JSON: log error, skip (don't crash cleanup)

#### 3. `scripts/sw-swarm-test.sh` (~80 new lines)

**Change type**: Add 6 unit test cases

| Test                              | Coverage                                  |
| --------------------------------- | ----------------------------------------- |
| `test_prune_removes_stale_agents` | Agent with heartbeat >300s ago is removed |
| `test_prune_keeps_active_agents`  | Agent with recent heartbeat is kept       |
| `test_prune_mixed_agents`         | Both stale and active agents in registry  |
| `test_prune_empty_registry`       | No errors on empty registry               |
| `test_prune_quiet_flag`           | Output suppression works                  |
| `test_health_auto_prunes`         | Health check triggers automatic prune     |

---

## Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│                 Shipwright Agent Lifecycle              │
└─────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│   Spawn      │   │   Monitor    │   │   Cleanup    │
│  (register)  │   │  (heartbeat) │   │  (prune)     │
└──────────────┘   └──────────────┘   └──────────────┘
        │                   │                   │
        └───────┬───────────┴───────┬───────────┘
                │                   │
                ▼                   ▼
    ┌──────────────────────────────────────┐
    │  Registry (~/.shipwright/swarm/)     │
    │  registry.json                       │
    │  ├─ agents: [{id, last_heartbeat}]  │
    │  ├─ active_count                     │
    │  └─ config                           │
    └──────────────────────────────────────┘
                │
    ┌───────────┼───────────┐
    │           │           │
    ▼           ▼           ▼
  Prune     Health     Retire
  (TTL)     (TTL)     (manual)
```

### Key Interfaces

```typescript
// CLI Interface
shipwright swarm prune [--quiet]
  → Exit 0 on success, 1 on error
  → Output: "Pruned N agents" or "No stale agents found"
  → Env: SWARM_PRUNE_TTL (seconds, overrides config)

// Function Contracts (sw-swarm.sh)
cmd_prune(flags?: string[]) -> void
  → Side effects: kills tmux sessions, updates registry.json
  → Errors: logs to stderr, exits 1 on registry failure

cmd_health() -> void
  → Now calls: cmd_prune --quiet at end
  → Backwards compatible (adds passive cleanup)

// Registry Schema (existing, no changes)
{
  "agents": [
    {
      "id": "agent-uuid",
      "last_heartbeat": "2026-03-25T22:30:00Z",
      "tmux_session": "swarm-agent-uuid",
      ...
    }
  ],
  "active_count": 5,
  "config": { "stall_detection_threshold": 300 }
}
```

### Data Flow: Prune Operation

```
┌─ User runs: shipwright swarm prune ─────────────────────┐
│                                                          │
├─ 1. Load registry.json (atomic read)                    │
│                                                          │
├─ 2. Get current epoch: now = $(date +%s)              │
│                                                          │
├─ 3. For each agent:                                     │
│    ├─ Parse last_heartbeat ISO → convert to epoch      │
│    ├─ elapsed = now - heartbeat_epoch                  │
│    └─ if elapsed > threshold (300s):                   │
│       ├─ Kill tmux session: tmux kill-session -t ...   │
│       └─ Collect ID for removal                        │
│                                                          │
├─ 4. Atomic registry update:                            │
│    ├─ jq 'remove IDs from .agents'                     │
│    └─ Write to temp file, mv to registry.json         │
│                                                          │
├─ 5. Record metrics: emit_event "prune" "count=N" ...  │
│                                                          │
└─ 6. Output summary (unless --quiet) ──────────────────┘
```

---

## Error Handling & Boundaries

| Component             | Error Cases                  | Handling                                 |
| --------------------- | ---------------------------- | ---------------------------------------- |
| **Registry Read**     | Missing, empty, invalid JSON | Skip (no-op), log warning                |
| **Heartbeat Parse**   | Invalid ISO format           | Skip agent (defensive), continue         |
| **Tmux Session Kill** | Session doesn't exist        | Silently continue (idempotent)           |
| **Tmux Session Kill** | Permission denied            | Log warning, continue registry removal   |
| **Registry Write**    | Disk full, permission denied | Log error, exit 1 (fail hard)            |
| **Time Calculation**  | Clock skew                   | Use conservative threshold (300s buffer) |

---

## Risk Analysis & Mitigations

| Risk                                                     | Probability | Impact                  | Mitigation                                                                                                                     |
| -------------------------------------------------------- | ----------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Prune kills working agent with stale heartbeat           | Low         | Medium (lost agent)     | Use same 300s threshold as proven health checks; emit events to trace decisions                                                |
| Race condition on registry during concurrent prune/spawn | Very Low    | Low (duplicate entry)   | Atomic tmp+mv (existing Shipwright pattern); spawn already handles this                                                        |
| `cleanup --force` kills active pipeline's swarm          | Low         | Medium (pipeline fails) | Documented as destructive; consistent with existing cleanup semantics; can be recovered                                        |
| Date parsing fails on non-standard systems               | Low         | Medium (pruning fails)  | Use `date_to_epoch` from `scripts/lib/compat.sh` (GNU/BSD portable); skip agent on parse failure rather than treating as stale |
| Heartbeat timestamp corruption                           | Very Low    | Medium (wrong pruning)  | Each agent write includes fresh ISO timestamp; only issue if registry corrupted                                                |
| Memory leak in tmux session after kill                   | Low         | Low (residual memory)   | Tmux native cleanup should work; monitor with `tmux list-sessions`                                                             |

---

## Validation Criteria

### Unit Test Coverage (6 tests in `sw-swarm-test.sh`)

- [ ] **Stale agent removal**: Registry with agent heartbeat >300s old → agent removed + tmux session killed
- [ ] **Active agent preservation**: Registry with agent heartbeat <300s old → agent kept
- [ ] **Mixed population**: 1 stale + 1 active agent → only stale removed
- [ ] **Empty registry**: Prune on empty registry → no errors, clean exit
- [ ] **Quiet flag**: `prune --quiet` → no stdout output
- [ ] **Health auto-prune**: `health` command → stale agents pruned silently

### Integration Test (implicit)

- [ ] **Cleanup with active swarm**: `cleanup --force` kills all swarm sessions and cleans registry
- [ ] **Idempotent prune**: Running prune twice → no errors, same result
- [ ] **Atomic updates**: Concurrent spawn + prune → no corrupted registry entries

### Manual Verification (pre-merge)

- [ ] Run `shipwright swarm prune` with live agents → correct agents removed
- [ ] Run `shipwright swarm health` → auto-prune works, status shows correct active count
- [ ] Run `shipwright cleanup --force` → all `swarm-*` sessions killed, registry cleaned
- [ ] Verify no OOM issues after 24h of daemon operation (future: monitor in production)

### Acceptance Criteria (from issue #207)

- [ ] `shipwright swarm prune` kills tmux sessions with no heartbeat >300s and removes registry entries
- [ ] `shipwright swarm health` auto-prunes stale agents after reporting status
- [ ] `shipwright cleanup --force` kills all `swarm-agent-*` tmux sessions and removes stale registry entries
- [ ] 6 new unit tests pass in `sw-swarm-test.sh`
- [ ] All existing tests continue to pass (`npm test`)

---

## Testing Strategy

### Test Pyramid Breakdown

- **Unit tests** (6): 100% in `sw-swarm-test.sh`, no real tmux needed (mock-friendly)
- **Integration tests** (0): Not needed—prune reuses proven retire patterns; cleanup follows existing patterns
- **E2E tests** (0): Manual verification sufficient (daemon-level testing is future work)

### Critical Paths to Test

1. **Happy path**: Stale agent (heartbeat >300s) → pruned, tmux killed, registry entry removed
2. **Error case 1**: Registry missing/empty → graceful no-op, exit 0
3. **Error case 2**: Agent in registry but tmux session already gone → registry entry still removed
4. **Edge case 1**: Agent heartbeat exactly at threshold (e.g., 300.0s) → NOT pruned (use strict `>`, not `>=`)
5. **Edge case 2**: All agents stale → registry ends with empty `agents` array and `active_count=0`
6. **Edge case 3**: Concurrent prune + spawn → no registry corruption (atomic writes)

### Coverage Targets

- 100% of `cmd_prune()` branches: empty registry, all stale, all active, mixed, quiet flag, threshold boundaries
- `cmd_health()` auto-prune call path after status output
- `sw-cleanup.sh` swarm section logic (same pattern as existing cleanup tests)

---

## API/CLI Specification

### Endpoint: `shipwright swarm prune`

| Aspect         | Specification                                                        |
| -------------- | -------------------------------------------------------------------- |
| **Command**    | `shipwright swarm prune [--quiet]`                                   |
| **Flags**      | `--quiet` (suppress output, for programmatic use from health checks) |
| **Exit codes** | `0` = success (even if nothing pruned); `1` = registry error         |
| **Output**     | Summary: `Pruned N agents` or `No stale agents found`                |
| **Env vars**   | `SWARM_PRUNE_TTL` (seconds, overrides config threshold)              |
| **Idempotent** | Yes—safe to run multiple times; removes only truly stale agents      |

### Error Codes

- **Not applicable**: CLI tool, not HTTP API. Errors logged to stderr, exit code indicates success/failure.

### Rate Limiting

- **Not applicable**: CLI tool running locally, not network-exposed.

### Versioning

- **Not applicable**: Internal CLI subcommand, no external API contract to version.

---

## Definition of Done

### Implementation Tasks

- [ ] Task 1: `cmd_prune()` function in `sw-swarm.sh` with TTL-based detection and removal
- [ ] Task 2: `prune` case added to main router; help text updated
- [ ] Task 3: `cmd_health()` modified to auto-call `cmd_prune --quiet` after status report
- [ ] Task 4: Swarm cleanup section added to `sw-cleanup.sh` (kill `swarm-*` + clean stale registry)
- [ ] Task 5: Cleanup summary counters updated with swarm stats
- [ ] Task 6: 6 unit tests added to `sw-swarm-test.sh`
- [ ] Task 7: `npm test` passes (all existing + new tests)

### Quality Gates

- [ ] Code follows Shipwright shell standards (`set -euo pipefail`, bash 3.2 compatible)
- [ ] Registry updates use atomic tmp+mv pattern
- [ ] All error paths logged with context
- [ ] Metrics recorded for each prune decision
- [ ] No regressions in existing swarm operations (spawn, retire, health, scale)
- [ ] Test coverage ≥95% for new `cmd_prune()` function

### Documentation

- [ ] PR description explains OOM problem and solution
- [ ] ADR stored at `docs/adr/ADR-207-swarm-session-cleanup.md`
- [ ] Commit messages reference issue #207
- [ ] Help text updated with prune subcommand

---

## Summary

This ADR specifies a **minimal, focused solution** to prevent OOM accumulation from stale swarm sessions. The approach:

1. Adds on-demand pruning (`shipwright swarm prune`)
2. Integrates automatic cleanup into existing health checks
3. Extends destructive cleanup to handle swarm sessions
4. Requires no refactoring of stable code paths (retire, spawn)
5. Is testable without complex infrastructure (mock-friendly)
6. Maintains backward compatibility with all existing operations

**Key trade-off**: Accepts ~10-15 lines of code duplication between retire and prune logic to avoid refactoring risk. Clarity and safety outweigh DRY principle in this case.
