# Compound Audit Architecture & Shipyard Simulation Design

**Date**: 2026-02-28
**Status**: Approved
**Scope**: Three parallel workstreams

## 1. Compound Negative-Critical Audit Architecture

### Philosophy

Every audit asks "What did we get wrong?" The questions:

- What did we miss?
- What did we not think through or consider?
- What did we fail to test, audit, research, validate, or prove works E2E?
- Where are we lying to ourselves about capability?

### 6 Audit Dimensions

Evaluated against background-agents.com gold standard:

| Architect          | Dimension              | Core Question                                                                        |
| ------------------ | ---------------------- | ------------------------------------------------------------------------------------ |
| infra-auditor      | Isolated Compute       | Can Shipwright provision isolated dev environments with production parity?           |
| event-auditor      | Event Routing          | Can Shipwright trigger agents from webhooks, schedules, Slack, API, mobile?          |
| governance-auditor | Governance & Safety    | Does Shipwright enforce identity, permissions, audit trails at execution layer?      |
| context-auditor    | Context & Connectivity | Can agents access internal APIs, databases, private registries behind firewalls?     |
| fleet-auditor      | Fleet Coordination     | Can Shipwright run the same fix across 100 repos in parallel with progress tracking? |
| dx-auditor         | Developer Experience   | Is the dashboard/website compelling enough to choose Shipwright over alternatives?   |

### Finding Format

```
FINDING-{dimension}-{number}
Severity: P0 | P1 | P2 | P3
Category: missing | broken | incomplete | misleading | untested
Question: What specific question does this answer?
Gap: What background-agents.com describes that we don't have
Reality: What Shipwright actually does today
Impact: Why this matters to users
Action: Concrete fix with effort estimate (S/M/L/XL)
```

### Scoring

Each dimension scored 0-100. Overall "Shipwright Readiness Score" = weighted average.

## 2. Shipyard Simulation Engine

### A. Pipeline Lifecycle Simulator (`shipyard-simulator.ts`)

Client-side state machine generating realistic pipeline behavior:

```
SPAWN (2s) -> intake (5-15s) -> plan (10-25s) -> design (8-20s) ->
build (20-60s) -> test (15-40s) -> review (10-30s) ->
compound_quality (10-20s) -> pr (5-15s) -> deploy (8-20s) ->
validate (5-10s) -> monitor (10-30s) -> COMPLETE + DESPAWN (3s)
```

- Pool of 4-10 concurrent pipelines
- New pipelines spawn every 15-45s
- 10% failure chance at build/test/review, 70% recovery rate
- Completed pipelines trigger celebration then despawn
- Stage durations randomized for organic feel

### B. Speech Bubbles (`shipyard-bubbles.ts`)

Contextual messages floating above agents:

**Types**:

- Speech (white, rounded): "Compiling modules...", "47/52 tests passing"
- Thought (cloud, translucent): "Analyzing dependencies...", "Waiting for review..."
- Shout (spiky, bright): "Build failed!", "Merge conflict!"
- Celebrate (sparkly): "All tests pass!", "Shipped!"

**40+ unique messages** across stages:

| Stage  | Sample Messages                                        |
| ------ | ------------------------------------------------------ |
| intake | "Reading issue...", "Triaging requirements..."         |
| plan   | "Designing architecture...", "Mapping dependencies..." |
| build  | "Compiling module 3/7...", "Linking binaries..."       |
| test   | "Running test suite...", "47/52 passing..."            |
| review | "Checking code style...", "Reviewing PR diff..."       |
| deploy | "Rolling out to prod...", "Health checks green!"       |

**Behavior**:

- Auto-show on state transitions
- Ambient chatter every 8-15s for working agents
- Dismiss after 3-5s with fade-out
- Max 1 bubble per agent, 3 visible total
- Typewriter effect for longer messages

### C. Agent Community Behaviors

1. **Passing interactions**: Agents walking through same corridor pause and face each other (0.3s)
2. **Stage celebrations**: Pipeline completes -> nearby agents jump (2 frames, 0.4s)
3. **Idle variety**: Random look left/right, stretch, wander within compartment
4. **Work intensity**: Animation speed increases with elapsed time
5. **Alert clustering**: Failure -> nearby agents turn toward alert

### D. Enhanced Crew Manifest Bar

```
CREW  *#191 intake  *#178 plan  *#142 build  *#157 test  ...
       [====--] 45%  [=====] 80%  [==---] 30%  [====-] 55%
       8 active - 2 completed - 1 failed
```

- Mini progress bars per agent
- Color-coded status dots
- Rolling stats (completed, failed, throughput)
- Click to highlight/focus agent

### E. Ship's Log Overlay

```
-- SHIP'S LOG ----------------------
12:07  #220 entered Airlock
12:06  #142 tests passing
12:05  #157 build failed
12:05  #178 advanced to Bridge
12:04  #163 review complete
------------------------------------
```

- Max 6 visible entries, newest at top
- Color-coded by event type
- Semi-transparent overlay
- Togglable with LOG button

## 3. Living Gap Analysis Output

### Document Structure

Produces `docs/plans/2026-02-28-compound-audit-gap-analysis.md`:

- Executive summary (top 5 gaps, top 5 strengths)
- Dimension scores table with status indicators
- All findings grouped by dimension
- Shipyard simulation requirements (from DX audit)
- Website gap analysis (claims vs. proven)
- Action plan (ranked by impact x effort)

### Compound Loop

Audit -> Fix -> Re-Audit -> Fix. Each cycle the readiness score increases.

## 4. Execution Plan

### Phase 1: Audit (6 parallel architects, read-only)

Each architect searches codebase against background-agents.com criteria, produces findings.

### Phase 2: Synthesis (lead)

Merge findings into gap analysis, score dimensions, prioritize actions.

### Phase 3: Implementation (3 parallel builders)

- simulation-engineer: `shipyard-simulator.ts` + `shipyard-bubbles.ts`
- scene-integrator: Wire simulation into scene, enhance manifest/log
- agent-animator: Community behaviors in `pixel-agent.ts`

### Phase 4: Re-Audit (negative-critical loop)

Run same 6 auditors on changed codebase. Score should increase.

## Files To Create

| File                                         | Purpose                                |
| -------------------------------------------- | -------------------------------------- |
| `dashboard/src/canvas/shipyard-simulator.ts` | Pipeline lifecycle simulation engine   |
| `dashboard/src/canvas/shipyard-bubbles.ts`   | Speech/thought bubble rendering system |

## Files To Modify

| File                                       | Changes                                                       |
| ------------------------------------------ | ------------------------------------------------------------- |
| `dashboard/src/canvas/pixel-agent.ts`      | Community behaviors, celebration state, progress tracking     |
| `dashboard/src/canvas/shipyard-scene.ts`   | Integrate simulator, bubbles, activity log, enhanced manifest |
| `dashboard/src/canvas/shipyard-effects.ts` | Celebration effects, enhanced ambient effects                 |
| `dashboard/src/design/submarine-theme.ts`  | Bubble styles, message pools, simulator timing constants      |
