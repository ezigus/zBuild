# zBuild Keepers Spec

> **Citation note:** file:line references throughout this document resolve into `legacy/` after the legacy import step completes. Before that, they pointed at the upstream repo (`https://github.com/ezigus/shipwright`), which was used as the source of truth for "what behaviors exist today" during the audit.

## Context

The original Keepers Spec catalogs ~80 behaviors to lift into zBuild, a plugin-based framework where AI agents, non-AI integrations, and recovery strategies are interchangeable plugins over a stable stage contract. Three audit passes against the live legacy codebase (engine surface, safety primitives, daemon, learning loops, plus a re-verification pass focused on aspirational claims) produced corrections and additions. This document is the revised spec. Goals: (1) accurate citations, (2) load-bearing details the original missed, (3) honest separation between "preserve" and "build new," (4) post-stabilization wishlist for items that don't fully exist yet but should.

The spec is organized as the original was, with deltas called out.

---

## Section A — Pipeline / Stage Composition (verified)

**Carry forward as-is, with one correction:**

- Stage dispatch is **already centralized** at `legacy/scripts/sw-pipeline.sh:1572` (`run_stage_with_retry` calls `stage_${stage_id}` by name). The original spec's "scattered case statements" framing is wrong — the existing seam is already plugin-shaped. zBuild's registry drops in on top; no refactor of dispatch logic needed.
- Stage handlers already live in modular files: `legacy/scripts/lib/pipeline-stages-{intake,build,review,delivery,monitor}.sh`. Plugin migration wraps these; do not rewrite.
- Gate semantics (auto / approve / budget / score / scope / smoke) and template subtractive composition (hotfix disables stages, doesn't fork code) — confirmed and carry forward.

**RETIRED (issue #979, EPIC #1277, 2026-07-09):** The four `cq-*` plugins and the `test_assessment` plugin below were deleted along with `standard.yaml` (the only template that used them). The default `simple.yaml` pipeline replaces the compound-quality lattice with the composable mechanical gates + `gate-aggregator` convergence (ADR-040) and the advisory `review_lenses` group. The history below is preserved for provenance; the plugins no longer exist on disk.

**Re-cleave DONE (issue #755, 2026-06-13):**

`stage_compound_quality` has been split into four independent leaf-stage agent plugins:

1. **`cq-preflight`** → `plugins/agent/cq-preflight/` — bash-compat check, coverage, untested-functions. Non-cyclic, fail-fast. Source: `pipeline-intelligence.sh:2042-2195`.
2. **`cq-audit-plan`** → `plugins/agent/cq-audit-plan/` — reads `quality-scores.jsonl` history, emits `audit-plan.json`. Source: `pipeline-intelligence.sh:429-508`.
3. **`cq-cycle`** → `plugins/agent/cq-cycle/` — iterative audit loop, emits `quality-feedback.md`. Source: `pipeline-intelligence.sh:2236-2900`.
4. **`cq-backtrack`** → `plugins/agent/cq-backtrack/` — architecture-class backtrack, non-blocking. Source: `pipeline-intelligence.sh:1339-1422`.

See tombstone: `legacy/migrated/A2-compound-quality.md`.

**A.6 — Design stage migration (issue #754):**

- `stage_design` (`legacy/scripts/lib/pipeline-stages-intake.sh:1004`) → `plugins/agent/design/`
- `_extract_scope_from_design` (`legacy/scripts/lib/pipeline-stages.sh:38-71`) → `plugins/agent/design/plugin.sh` + `plugins/agent/build/plugin.sh`
- Scope manifest as fenced markdown in design.md is now the primary authoritative scope source for the build stage (with plan.json as fallback). See `plugins/agent/design/manifest.yaml`.

**New stages (zBuild-only, not carried from legacy):**

- **`test_assessment` — LLM-interpreted test verdict (NEW for zBuild, not in legacy).** Sits between the deterministic `test` tool stage and the `review` agent stage. Reads `test-results.json` + optional `diff.patch`; writes `test-assessment.json` with semantic verdict (`pass|fail|error|inconclusive`), human-readable diagnosis, and a markdown `failure_summary_md` field. Source of truth for (1) the `build_test_cycle`'s `until:` predicate (ADR-021 §"test_assessment as until: source"), (2) review's coercion source (ADR-019 §7), (3) build's inter-iter feedback preamble (ADR-020 LLM-interpreted verdict stages subsection). Pattern 1 stage per ADR-018 with registered renderer `render_test_assessment_md`. Full record in ADR-022.

---

## Section B — Intelligence + Learning (substantially revised)

The original spec listed 11 items here. After re-verification, items split into three buckets:

### B1 — Verified wired, carry forward as core

1. **Telemetry event bus** (`legacy/scripts/lib/helpers.sh:75`, `config/event-schema.json`) — dual SQLite + JSONL under flock; schema-as-warn. Verified load-bearing across activity / replay / mission-control / dashboard.
2. **Audit intensity auto-selection** (`legacy/scripts/lib/pipeline-intelligence.sh:429-508`) — verified: reads `quality-scores.jsonl` at `:453-482`, branches intensity on avg score at `:470-480`, upgrades complexity→full at `:485-492`. Real history query, real branching.
3. **Skill registry success-rate self-improvement** (`legacy/scripts/lib/skill-memory.sh:144-176`, `legacy/scripts/lib/pipeline-state.sh:325/608`) — verified: records successes/failures, sorts by success rate at `legacy/scripts/lib/skill-memory.sh:173`, recommendations consumed at `legacy/scripts/sw-pipeline.sh:1703` to steer retries. Real closed loop.
4. **Two-phase complexity** (initial LLM + post-build reassessment, `legacy/scripts/sw-intelligence.sh:533`, `legacy/scripts/lib/pipeline-intelligence.sh:1238`) — carry forward.
5. **Vitals composite as circuit-breaker input** — `legacy/scripts/lib/loop-convergence.sh:101-132` (`check_circuit_breaker`) reads `pipeline_compute_vitals()` JSON at `:108`, branches on `verdict == "abort"` at `:111` to trip the breaker. This is real control, not just telemetry. Weights at `legacy/scripts/lib/sw-pipeline-vitals.sh:56-59` are env-tunable but static defaults. Carry forward as core; treat weights as configuration, not learned parameters.
6. **Scope manifest as fenced markdown in design.md** (`legacy/scripts/lib/pipeline-stages.sh:42`) — artifact-as-contract pattern; carry forward.
7. **Three-tier memory recall cascade** (`legacy/scripts/lib/pipeline-stages-build.sh:209`, `legacy/scripts/lib/ruflo-adapter.sh:2383/2429/2443`) — goal-scoped → issue-scoped → repo-scoped. Verified plumbed. Legacy native memory has no embeddings (`legacy/scripts/sw-memory.sh:197-206`, `_has_embeddings` returns false), but `legacy/scripts/lib/ruflo-adapter.sh:2376-2440` provides HNSW vector recall via the ruflo MCP layer under per-repo / per-issue namespaces (legacy uses `shipwright-repo-{hash}` / `shipwright-{hash}-{ISSUE_NUMBER}`; zBuild will use its own `zbuild-repo-{hash}` / `zbuild-{hash}-{ISSUE_NUMBER}` namespaces to avoid cross-talk). Carry forward as side-service with the existing two-tier (native TF-IDF + ruflo HNSW) backing.
8. **Adaptive cycle limits with convergence/divergence/plateau detection** (`legacy/scripts/lib/pipeline-intelligence.sh:351/1604`) — carry forward; plateau predicate is already a pure testable function.
9. **Cost ledger + baselines feeding routing** (`legacy/scripts/sw-cost.sh`, `lib/cost/*`) — carry forward as side service; `--render-plain` markdown output is a keeper.
10. **UCB1 router** (`legacy/scripts/sw-self-optimize.sh:907-955`) — verified correct UCB formula. Carry forward as the routing primitive.
11. **Thompson sampling for template selection** (`legacy/scripts/sw-self-optimize.sh:851-893`, called from `legacy/scripts/sw-pipeline.sh:3188` and `legacy/scripts/lib/daemon-triage.sh:411`) — Beta(s+1, f+1) with stochastic noise; pseudo-Thompson but actually wired to template choice. Carry forward.
12. **Quality finding classifier + architecture backtrack** (`legacy/scripts/lib/pipeline-intelligence.sh:134/1343/1745`) — six categories; security-first; architecture routes back to design. Carry forward.
13. **Error signature persistence in SQLite** (`legacy/scripts/sw-db.sh:312-325` schema, `:1147-1167` query) — `memory_failures` table stores `error_signature TEXT` keyed on `(repo_hash, failure_class)`. The "cache" exists as DB rows, not a hash-keyed cache, but the substrate is real. Carry forward.

### B2 — Verified aspirational; do NOT mark as keepers

These were claimed in the original spec but the re-verification confirms they do not exist as wired behaviors today. They move to Section L (post-stabilization wishlist), not the Section H mapping table.

- **SPRT** (Sequential Probability Ratio Test). Zero references anywhere. Original spec confused it with Thompson + UCB1.
- **AI fallback in error classifier** (rules → haiku → cache). `legacy/scripts/lib/daemon-failure.sh:22-71` is rules-only; no LLM call exists.
- **Verdict-gradient kill steering**. The verdict gradient (healthy → slowing → stalled → stuck) is computed at `legacy/scripts/lib/daemon-poll.sh:414-497` but only the wall-clock 2×-stale rule actually triggers kills. Nudge file written at `:461`, zero readers anywhere in the codebase.
- **DORA → template escalation closed loop**. `legacy/scripts/lib/daemon-triage.sh:264-322` requires ≥5 recent `pipeline.completed` events; in practice the CFR > 40% trigger almost never fires for healthy repos. Code exists; loop doesn't close in real workloads.

### B3 — Re-classified

- **Vitals composite "drive adaptive iteration caps"** — partial: drives circuit breaker (B1.5), not iteration caps. Caps remain template-driven. Don't claim more than the wiring supports.

---

## Section C — Reliability + Safety (expanded)

Carry forward all original entries with these corrections and additions.

### Corrections

- **Redaction has 9 prompt seams, not 6.** Verified sites: `legacy/scripts/lib/pipeline-stages-build.sh:448`, `legacy/scripts/lib/pipeline-stages-review.sh:364`, `legacy/scripts/lib/pipeline-intelligence.sh:1795/1845`, `legacy/scripts/lib/pipeline-quality-checks.sh:807-809` (×3), `legacy/scripts/lib/compound-audit.sh:129-133` (×3), `legacy/scripts/lib/loop-iteration.sh:674`. No wrapper function exists today — every site calls `_redact_paths_outside_scope` directly. zBuild MUST introduce one chokepoint (`_apply_scope_redaction()`) that all LLM-bound text passes through.
- **Goal sanitization at initial capture: confirmed wired.** `legacy/scripts/sw-loop.sh:517` calls `_strip_synthesized_sections()` (`legacy/scripts/lib/goal-sanitize.sh:11`) on initial GOAL capture when `LOOP_CONTEXT_FILE` is set, before any prompt is built. Also applied on resume (`legacy/scripts/lib/pipeline-state.sh:946-968`) and restart (`legacy/scripts/lib/loop-restart.sh:134-143`). Carry forward as multi-boundary primitive.
- **Admission gate tiers are dependent, not independent.** Order: `reap_stale_pipeline_locks` (`legacy/scripts/sw-pipeline.sh:321`) → `count_active_pipeline_locks` (`:324`, depends on reaping) → memory floor (`:339`) → `write_active_pipeline_lock` (`:257`, depends on count passing) → `release_active_pipeline_lock` (`:292`). Preserve this ordering.
- **`CURRENT_ITERATION` is lost on resume.** Verified at `legacy/scripts/lib/pipeline-state.sh:876-1075` — `resume_state` does not parse an `iteration:` field. Only `SELF_HEAL_COUNT` is restored. zBuild must persist iteration explicitly or reconstruct it from `events.jsonl` tail.

### Additions (hidden safety primitives the original spec missed)

Promote to first-class concerns:

1. **Disk-space precheck** (`legacy/scripts/lib/helpers.sh:297`, `check_disk_space`) — only one caller today (`legacy/scripts/lib/pipeline-state.sh:796`). Extend to all artifact writes.
2. **JSON corruption recovery** (`legacy/scripts/lib/helpers.sh:179`, `validate_json`) — only at daemon startup today. Wire into every state read with `.bak` rotation.
3. **Atomic-append for JSONL** (`legacy/scripts/lib/helpers.sh:239-272`) — assumes no concurrent writers. Event-bus contract must specify single-writer or add multi-writer locking.
4. **Scope-violation logging file** (`legacy/scripts/lib/helpers.sh:945-968`) — `scope-violations.txt` is diagnostic-only; if `persist_artifacts` fails before commit, violations are invisible on resume.
5. **ANSI stripping in event log emission** (`legacy/scripts/lib/helpers.sh:431-437`) — must be applied to every payload; selective application corrupts JSON.
6. **Git bookkeeping exclude lists** (`legacy/scripts/lib/helpers.sh:515-531`) — two lists (`_GIT_BOOKKEEPING_FILES`, `_GIT_RUNTIME_EXCLUDES`). Need single source-of-truth for "files that shouldn't count as work."
7. **Event-log rotation race** (`legacy/scripts/lib/helpers.sh:202-213`) — JSONL truncation during a concurrent plugin write loses recent events. SQLite mirror is durable; rotation must defer to writer-coordinated quiescence.
8. **Resume best-effort contract** — explicitly document persisted vs. reconstructed state.

---

## Section D — Daemon + Autonomous Operation (revised)

Carry forward originals except:

- **Multi-tier locking across machines** (`legacy/scripts/lib/daemon-state.sh:602-720`): TOCTOU window between `gh issue edit --add-label claimed:<machine>` and verification re-read is real. Backoff + re-verify mitigates but doesn't eliminate. See Section M.
- **DORA → template escalation** → Section L wishlist.
- **Verdict-gradient kill** → Section L wishlist.

Everything else (GitHub label contract as control plane, patient-kill wall-clock rule, persisted circuit breaker with `resume_after`, triage scoring with age boost, auto-scale with five independent ceilings, peer failover via label release, patrol-as-self-generated-work, watchdog around poll loop, polling-canonical / webhooks-observability) — verified and carry forward.

---

## Section E — CLI + UX (carry forward unchanged)

All 13 original items verified. Lift verbatim, including the live-updating GitHub comment marker + atomic ID persistence (`legacy/scripts/lib/pipeline-github.sh:97-135`, `legacy/scripts/sw-pipeline.sh:1150-1154`).

---

## Section F — Personas + Recruit + Skills (refined)

- Compound-audit 7-lens cascade — verified; carry forward as 7 agent plugins with prompt-discipline preserved verbatim.
- Skill registry self-improvement — verified wired (B1.3).
- `legacy/scripts/sw-recruit.sh` AGI-framing — drop; keep the learning loop only; revisit talent-database after migration.
- `code-review-swarm` — drop reference; never implemented.

User-confirmed constraint: existing agents/personas are well-written and not exhaustive; preserve them as-is during the infrastructure migration; revisit/refine after the new infrastructure is stable.

---

## Section G — Test Harness (carry forward, with audit correction)

All seven harness primitives confirmed. **Correction:** the earlier audit's claim of "60+ grep-for-function-name assertions" is wrong — re-audit found **zero** `grep -qE "^funcname\(\)"` patterns across the 160 test files. Tests invoke functions directly and assert outputs/side-effects. That's a major asset, not a liability.

Test inventory in legacy: 160 test files (158 bash + 2 vitest), naming convention `sw-*-test.sh`, flat layout in `legacy/scripts/`. Split: ~80 unit, ~40 integration, ~9 E2E, plus 2 dashboard JS. `legacy/scripts/lib/test-helpers.sh` is generic and reusable — already lifted into zBuild's `scripts/lib/test-helpers.sh`.

Migration math:
- **~50 migrate near-unchanged:** all 25 lib tests, 9 E2E, core feature tests for pipeline/ci/loop/replay/daemon/init/cleanup/cost/db.
- **~30 rewrite:** adapters, agi-roadmap, chaos, postmortem-460, ruflo-adapter, tmux-pipeline, ai-provider, cross-repo-isolation, budget-chaos, evidence — all encode platform-specific assumptions.
- **~20 delete:** obsolete features, incident-specific postmortems, extreme stress tests.

Still add golden-file diffing as a new capability (confirmed zero golden tests in legacy today).

**Enumeration note:** the 50/30/20 split must be enumerated row-by-row in `.github/issues/keepers-manifest.yaml` so the test-migration acceptance criterion is checkable (not just forecasted).

---

## Section H — Mapping Table

| Original row | Revised landing |
|---|---|
| "Stage handlers → `kind: agent\|tool` plugins" | Already centralized at `legacy/scripts/sw-pipeline.sh:1572`; plugin registry wraps existing function-name dispatch. No refactor. |
| "Self-healing loops → recovery plugin" | Landed in the engine, not a plugin: error-classification is `disposition` (ADR-054 §6) and the backward edge is `route_back` (ADR-045). `kind: recovery` was retired by #1900 — the shared-core-first warning was right, and the shared core absorbed the whole concern. |
| "Compound-audit cascade" | 7 agent plugins + 1 orchestrator plugin + 4 phase modules (pre-flight, audit-plan, cycle, backtrack), not 2. |
| "Vitals composite" | Core engine subsystem (not "side service"); already wired into circuit breaker at `legacy/scripts/lib/loop-convergence.sh:111`. |
| "Memory recall (3-tier)" | Side service with two-backend split: native TF-IDF (`legacy/scripts/sw-memory.sh`) + ruflo HNSW (`legacy/scripts/lib/ruflo-adapter.sh:2376-2440`). |
| "UCB1 + SPRT model router" | UCB1 + Thompson router (SPRT does not exist; see Section L wishlist). |
| "Scope manifest as fenced markdown in design.md" (`legacy/scripts/lib/pipeline-stages.sh:42`) | `plugins/agent/design/` — design stage produces design.md with ```scope block; build stage reads it as authoritative scope source (plan.json fallback). Migrated in issue #754. |
| "JSON corruption recovery (`legacy/scripts/lib/helpers.sh:179`, `validate_json`)" | `core/state/atomic.sh` (`read_state`, `_zbuild_lsu_validate_and_copy`) + `scripts/lib/helpers.sh` (`validate_json` primitive); wired into every state read as of issue #38. |
| "Scope redaction" | Single chokepoint helper (`_apply_scope_redaction`) replacing 9 direct call sites; core engine I/O wrapper. |
| "Multi-tier locking" | Core engine for in-process / per-host; cross-machine claim mechanism is a decision point (Section M). |
| "Resume contract" | Explicit two-tier: persisted (stage status, SELF_HEAL_COUNT, scope manifest, cost ledger, CURRENT_ITERATION) vs reconstructed (runtime caches, loop-state.md). |
| "ANSI stripping in event log emission (`legacy/scripts/lib/helpers.sh:431-437`)" | `core/event-bus/event-bus.sh` — `_eb_strip_ansi` (private), called by `eb_emit_event` on every payload value and string envelope field. Migrated in issue #c-9. |

---

## Section I — Explicitly NOT Keeping

Original NOT-keeping list + new additions:

- The 1013-line `stage_compound_quality` monolith (split into 4 per Section A).
- The 2974-line `legacy/scripts/lib/pipeline-intelligence.sh` junk drawer.
- The 4309-line `legacy/scripts/sw-pipeline.sh` god-script (CLI + engine + selfheal + errors).
- Three separate named self-healing loops — collapse into one engine driven by `disposition` (ADR-054 §6).
- Hardcoded `_extract_blocking_items` source list — replaced by `plugins/*/findings.json` glob.
- `_COMPOUND_AGENT_PROMPTS_*` bash variable indirection.
- Anthropic-named tier strings (`haiku|sonnet|opus`) in code — replaced by T0-T4 ordinal with models as data.
- Bash 3.2 polyfills in `compat.sh`.
- Multiple repo-hash schemes — unify on one. **DONE (#1930, 2026-08-23):** `scripts/lib/identity.sh` owns the one derivation — a hash id for flat keys and an `owner/repo` slug for paths. Struck rather than deleted: it records that this was carried forward from legacy and has since been discharged (ADR-059 §6).
- The `_design_rescue` heuristic for Claude CLI quirks — gate behind a config flag.
- The "AI fallback in error classifier" — falsely claimed; moved to Section L as new-build.
- The nudge-file mechanism — written but never read; remove rather than carry forward dead bytes.

---

## Section J — Verification

5-test trial per keeper:
1. Does the new code preserve the behavior (not the implementation)?
2. Does the regression test prove it?
3. Is the file:line citation still discoverable in the new tree?
4. Does the mapping-table landing place match where the code actually lives?
5. Does removing the new implementation reproduce the symptom the original was solving?

Plus end-to-end smoke + multi-daemon claim race test.

---

## Section K — Deferred

**Persona / agent refinements (deferred):**
- The existing agent taxonomy is "not exhaustive" by user acknowledgement. Gaps to revisit later.
- Audit redundancy: security appears in four places (compound-audit security lens, developer-simulation security persona, `legacy/scripts/sw-adversarial.sh`, `legacy/scripts/skills/security-audit.md` skill). Consolidate post-migration.
- Skill registry overlap with personas — decide later whether skills fold into agent plugins.
- Edge-case lens vs security lens prompt-overlap — tighten mutual exclusion post-migration.

**Architectural refinements (deferred):**
- Patch-mode self-healing vs current whole-stage rebuild.
- Compound-quality single-source-of-truth (currently pre-loop snapshot/restore dance papers over double-counting).
- Real cross-machine claim leases with TTL (see Section M).

**Process / hygiene (deferred):**
- Adding golden-output / snapshot tests (currently zero in legacy).
- Splitting `legacy/scripts/sw-recruit.sh` (2644 LoC) into focused modules.

---

## Section L — Post-Stabilization Wishlist

Behaviors not wired today; build after migration stabilizes (not blocking Phase 0).

1. **Real SPRT for routing graduation.** Today: Thompson + UCB1 with `total_trials >= 5` graduation. Add Wald SPRT as a hypothesis test.
2. **AI error-classifier fallback (rules → haiku → SQLite-cached).** Key on existing `memory_failures.error_signature` row schema.
3. **Verdict-gradient kill steering.** Wire `slowing` → soft nudge (daemon reads the file before deciding), `stalled` → reduce iteration cap, `stuck` → kill.
4. **DORA → template feedback loop.** Lower trigger threshold or expand event window so CFR-driven escalation actually fires.
5. **Native embedding-backed memory recall.** Pull ONNX 384-dim embeddings into native memory layer; don't depend on ruflo MCP availability.
6. **Mid-pipeline JSON corruption recovery.** Wire `validate_json` + `.bak` rotation into every state read.
7. **Disk-space precheck on artifact writes.** Add to every `atomic_write` boundary.
8. **Patch-mode self-healing** (also in Section K).
9. **Compound-quality single-source-of-truth** (also in Section K).
10. **TTL-lease claim coordinator** — `plugins/claim-coordinator/ttl-leases/` replacing the label-claim TOCTOU window with real leases + heartbeats.
11. **Dashboard-as-serializer claim coordinator** — third variant for users running the dashboard.

---

## Section M — Multi-Machine Claim Safety (decided: modular, swap later)

**Decision:** Keep the existing `claimed:<machine>` label scheme as the default cross-machine claim mechanism. Wrap behind a `kind: claim-coordinator` plugin contract so a real-TTL-lease implementation can drop in later without engine changes.

- **Contract:** `claim(issue_id) → {acquired, lease_id?}`, `release(issue_id, lease_id?)`, `heartbeat(lease_id?) → ok|expired`, `list_claims() → [{issue, holder, acquired_at}]`. Label-based impl heartbeats by no-op; TTL impl heartbeats for real.
- **Default plugin (Phase 0):** Port `legacy/scripts/lib/daemon-state.sh:602-720` logic verbatim into `plugins/claim-coordinator/github-labels/`. Document the TOCTOU window in the plugin README.
- **Follow-on:** `plugins/claim-coordinator/ttl-leases/` with `~/.zbuild/leases/<issue>.json`, heartbeat thread, TTL expiry. Users select via config.
- **Bonus:** `plugins/claim-coordinator/dashboard/` as a third variant on its own schedule.

---

## Section N — Repository Creation & Legacy Import

**Decision:** import the upstream source as `legacy/` reference — plain copy, no git history.

**Why import (verified by content audit):** 1,851 LoC of incident-hardened content would be expensive to recreate from memory across 12 categories: 7-lens compound-audit prompts (48 LoC), 20 goal-sanitize sentinels (30), gate-signal 3-layer regex (32), scope parser + redaction (230), 17 skill .md fragments (851), pessimist 7-question template + adversarial prompts (160), 3 simulation personas (55), 6 error-classifier regex rules (50), architecture-enforcer manifest detection (36), hallucination filter (144), dedup + escalation (135), `safe_git_stage` (80). Retyping from spec re-introduces the bugs each block defends against.

**Why plain copy, not subtree:** The upstream is being sunset; full git history is reference-only value. Plain copy is simplest, keeps zBuild's history clean, and the `legacy/` tree shrinks to zero as keepers verify out.

**Critical risk: PROJECT_ROOT collision (SEVERE).** If a developer runs `./legacy/scripts/sw-daemon.sh` from zBuild root, the daemon resolves `PROJECT_ROOT` via `git rev-parse --show-toplevel` to **zBuild root**, then writes state to `zBuild/.claude/pipeline-state.md` and claims labels in zBuild's GitHub issues. Plus `~/.shipwright/events.jsonl` is global and shared.

**Mitigation:**
- `legacy/FROZEN.md` at the top of legacy/ with explicit "DO NOT RUN" notice.
- `legacy/.shipwright-disabled` sentinel; legacy entry point patched to check for it and refuse to run. (See ADR-002 for the sole-exception protocol.)
- Any intentional invocation must be wrapped: `(cd legacy && PROJECT_ROOT="$(pwd)" SHIPWRIGHT_HOME="$(pwd)/.shipwright-legacy" ./scripts/sw ...)`.

**Pruning protocol:** when a keeper passes its 5-test trial: `git rm` the legacy source, create `legacy/migrated/<keeper-id>.md` tombstone with date + issue link, commit both as one commit.

---

## Section O — Issue Tree & Milestones

### Milestones

1. **Phase 0: Core Engine Foundation** — ships when redaction chokepoint, CURRENT_ITERATION persistence, plugin registry skeleton, event bus, first agent plugin (security lens), new repo, and legacy import are all done.
2. **Phase 1: Pipeline & Intelligence (Sections A + B)** — stage handlers wrapped as plugins, compound_quality split into 4 modules, audit auto-select working, memory recall live.
3. **Phase 2: Reliability & Safety Primitives (Section C)** — 9 redaction sites unified through chokepoint, admission-gate ordering documented, JSON corruption recovery wired into hot path, disk-space check on every artifact write, 7 hidden guards lifted.
4. **Phase 3: Daemon & Autonomous Ops (Section D)** — claim-coordinator default plugin live, label-based control plane preserved, triage/patrol/health daemon plugins migrated, peer failover working.
5. **Phase 4: CLI, UX, Skills, Personas (Sections E + F)** — CLI surface matches the legacy E-section behavior, 7 compound-audit lenses migrated as agent plugins, skill registry closed-loop preserved, status JSON / doctor / live-comment marker intact.
6. **Phase 5: Test Migration & Verification (Section G)** — 5-test trial passes for every keeper, golden-file diffing added, multi-daemon claim race test passes, legacy/ has shrunk to zero.

**Wishlist (post-stabilization):** Section L items become a backlog with their own milestone, opened only after Phase 5 stabilizes.

### Labels (19)

- **Phase:** `phase-0`, `phase-1`, `phase-2`, `phase-3`, `phase-4`, `phase-5`
- **Type:** `keeper`, `wishlist`, `foundation`, `legacy-prune`
- **Plugin kind:** `agent-plugin`, `tool-plugin`, `orchestrator-plugin`, `claim-coordinator`, `daemon-plugin`
- **Concern:** `safety-primitive`, `learning-loop`, `test-migration`, `cli-ux`

### Issue counts

Counts are authoritative in `.github/issues/keepers-manifest.yaml` and on GitHub (the manifest-sync workflow from #227/#248 keeps them in lockstep).

- **Phase 0 foundation:** entries labeled `phase-0`.
- **Keepers:** entries labeled `keeper`, split across sections A–G.
- **Wishlist:** entries labeled `wishlist` (Section L).

To get current totals, query the manifest or GitHub directly — don't hard-code numeric snapshots in docs (they drift the moment work ships).

### Top dependencies (modeled as issue links)

1. Plugin registry skeleton blocks every plugin issue.
2. Event bus blocks every daemon and learning-loop issue.
3. Redaction chokepoint blocks all 9 prompt-emitting plugins.
4. Admission gate ordering blocks recovery / self-heal plugins.
5. Resume contract doc blocks any plugin claiming persisted state.

---

## Phase 0 — Final Sequence

When implementation begins, Phase 0 lands in this order:

0. **Create new GitHub repo `zBuild`.** Push initial commit with LICENSE and README.
0.25. **Spec + architecture docs as the FIRST content commits.** Lock the architecture before code arrives. Every subsequent PR cites the relevant ADR or KEEPERS section.
0.5. **Import the upstream source as `legacy/`** (plain copy, sentinel-guarded). Verify legacy scripts cannot pollute new repo state.
1. **Day-1 structural copy:** `package.json`, `install.sh`, `.github/workflows/`, `.claude/settings.json`, `scripts/lib/{helpers,compat,test-helpers}.sh`.
2. **Core safety chokepoints:** `core/redaction/_apply_scope_redaction` wrapper; `CURRENT_ITERATION` persistence in `resume_state`; `check_disk_space` extended to all artifact writes; `validate_json` + `.bak` rotation on every state read.
3. **Plugin registry skeleton:** manifest schema, filesystem-glob discovery, lock file, lifecycle hooks.
4. **Telemetry event bus:** `emit_event` + dual SQLite/JSONL primitive; single-writer JSONL contract.
5. **First agent plugin POC:** migrate the `security` compound-audit lens. Verify 5-test trial. Tombstone the legacy file.
6. **Issue generator + keepers manifest:** `scripts/generate-issues.sh` + `.github/issues/keepers-manifest.yaml` covering Phase 0–5. Run it.
7. **Resume contract documentation:** explicit persisted vs. reconstructed lists; test coverage proves the boundary.

Phase 0 ships when steps 0 through 7 land and Phase 1 issues are unblocked.

---

## Verification (end-to-end smoke for Phase 0)

- `zbuild --version` works from clean checkout.
- `legacy/scripts/sw status` refuses to run (sentinel-guarded).
- `gh issue list --label phase-0 --milestone "Phase 0"` shows the 9 Phase 0 issues, all closed.
- One agent plugin (security lens) is discoverable via `zbuild plugin list`, runs against a fixture goal, emits events to the bus, and its output is identical (modulo structured-event metadata) to running the legacy `compound-audit security` lens against the same fixture.
- Redaction chokepoint observable in event log: every prompt-emit event has a `redaction_applied: true` field; refusing to emit when scope manifest absent is tested.
- Resume across `kill -9` mid-run: `CURRENT_ITERATION` survives.
- `legacy/migrated/security-lens.md` tombstone exists; `legacy/scripts/lib/compound-audit.sh` no longer contains the security lens block.

---

## Critical Files (audited; all paths under `legacy/` after import)

### Engine
- `legacy/scripts/sw-pipeline.sh` — 4309 LoC, 27 sectioned zones, centralized dispatch at `:1572`
- `legacy/scripts/lib/pipeline-stages-{intake,build,review,delivery,monitor}.sh`
- `legacy/scripts/lib/pipeline-intelligence.sh` — 2974 LoC; `stage_compound_quality` at `:1959-2972`; audit auto-select at `:429-508`
- `legacy/scripts/lib/compound-audit.sh` — 7-lens cascade with prompt taxonomy
- `legacy/scripts/lib/loop-convergence.sh` — `check_circuit_breaker` at `:101-132`

### Safety primitives
- `legacy/scripts/lib/helpers.sh` — `_redact_paths_outside_scope`, `safe_git_stage`, `check_disk_space:297`, `validate_json:179`, atomic write/append `:218-272`, ANSI strip `:431-437`, bookkeeping lists `:515-531`, `rotate_jsonl:202-213`, `emit_event:75`
- `legacy/scripts/lib/goal-sanitize.sh` — 18 sentinel strippers at `:11-40`
- `legacy/scripts/lib/gate-signal.sh` — negative-first parser at `:30-46`
- `legacy/scripts/lib/pipeline-state.sh` — atomic state, resume at `:876-1075` (note CURRENT_ITERATION gap)
- `legacy/scripts/sw-pipeline.sh:257-349` — admission gate primitives

### Learning loops
- `legacy/scripts/sw-self-optimize.sh:851-893` (Thompson), `:907-955` (UCB1)
- `legacy/scripts/lib/sw-pipeline-vitals.sh` — composite score with env-tunable weights
- `legacy/scripts/lib/skill-memory.sh:144-176` — closed-loop skill ranking
- `legacy/scripts/lib/ruflo-adapter.sh:2376-2440` — HNSW vector recall

### Daemon
- `legacy/scripts/lib/daemon-{poll,failure,health,patrol,triage,state,dispatch,adaptive}.sh`
- `legacy/scripts/lib/fleet-failover.sh`
- `legacy/scripts/sw-db.sh:312-325` — `memory_failures` schema; `:1147-1167` — record/query failures

### UX
- `legacy/scripts/lib/pipeline-github.sh:97-135` — live-updating comment with marker
- `legacy/scripts/sw-status.sh:75-260` — JSON contract
- `legacy/scripts/sw-doctor.sh:36-243` — check registry
- `legacy/.claude/helpers/statusline.cjs:225-256` — honest-failure pattern

### Plugin surface in legacy today
- `legacy/scripts/lib/skill-registry.sh` + `legacy/scripts/lib/skill-memory.sh` + `legacy/scripts/skills/*.md` — only existing plugin-shaped surface (prompt fragments only). Cost models, audit runners, retry policies, recovery strategies, gates — all hardcoded today. **zBuild's plugin infrastructure is greenfield except this.**
