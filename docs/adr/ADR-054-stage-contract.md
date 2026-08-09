# ADR-054: Stage Contract

**Status:** Accepted (2026-08-09)
**Date:** 2026-08-09
**Issue:** #1820
**Amends:**
- ADR-001 — hook lifecycle corrected: only `run` and `cleanup` are active at the stage-dispatch layer; `init` and `finalize` are never called there. rc table superseded: plugin rc is binary (0 success, 1 error); the rc=1→recovery routing never existed. See §4.
- ADR-021 — disposition vocabulary (§6) supersedes the informally-inherited `pass|warn|fail|unknown|error|corrupt_diff|block` set.
- ADR-025 — abort/trap ownership clarified: runner owns the trap; plugin `cleanup` hook is the abnormal-exit notification surface, not a second `run`. See §7.
- ADR-045 — disposition vocabulary `pass|warn|fail|error` (§6) replaces the bounded-route verdict set.
**Related:** ADR-001 (plugin contract), ADR-017 (per-stage router config), ADR-047 (stage-agnostic mechanics), ADR-013 (canonical stage list)

## Context

ADR-001 defines the general plugin contract: manifest schema, hooks (`init`, `run`, `finalize`, `cleanup`), and error semantics for all plugin kinds. The stage-specific subset — the `(stage_id, state_file)` dispatch signature, the env-var runtime context table, the fail-closed artifact scanner contract, the per-stage router configuration surface, and the disposition/verdict channel — was never extracted into a dedicated record.

This created two concrete gaps:

**1. Phantom hooks.** ADR-001 §"Lifecycle ordering" declares four hooks (`init`, `run`, `finalize`, `cleanup`), but only `run` and `cleanup` are called at the stage-dispatch layer. `plugin_hook_call` in `core/plugin-registry/registry.sh` has never invoked `init` or `finalize` at the stage-dispatch layer. Plugin authors who implemented `init` or `finalize` for stage-bound work executed dead code.

**2. Phantom rc routing.** ADR-001 §"Error semantics" declared that `rc=1` from a plugin routes to `kind: recovery` plugins for classification + action. No recovery plugin has ever been registered, and the routing path was never implemented at the stage-dispatch layer. `rc=1` has always been treated as a terminal error at that layer.

**3. valid_verdicts.** The manifest schema carried a `valid_verdicts` field that was declared and never read by the engine. The disposition vocabulary is governed by the v2 result file contract, not a per-manifest allowlist.

ADR-054 extracts the stage-bound subclaim from ADR-001, names what was actually implemented, and formally records the gaps between the schema and the code.

## Decision

### 1. Active hooks at the stage-dispatch layer

Exactly **two** hooks are active at the stage-dispatch layer:

| Hook | When called | Purpose |
|------|-------------|---------|
| `run` | Every stage dispatch | Primary work entry point |
| `cleanup` | Abnormal exit (kill, abort, trap signal) | Abnormal-exit notification; release locks, write tombstone event |

`init` and `finalize` are specified in ADR-001 §"Manifest schema" and §"Lifecycle ordering" as part of the general plugin contract. They are **never called** at the stage-dispatch layer. A stage-bound plugin that implements them executes dead code at this layer. The ADR-001 hook lifecycle table and rc table are amended accordingly (back-pointer added to ADR-001).

### 2. Hook function signature

All active stage-bound hooks receive the same two positional arguments:

```
<hook>(stage_id, state_file)
```

- `$1` — `stage_id` (string, informational; most plugins ignore it).
- `$2` — `state_file` (absolute path to `pipeline-state.json`). Plugins derive `state_dir = dirname($2)` and `artifacts_dir = $state_dir/artifacts`.

### 3. Runtime environment

Run-time context is passed via env vars exported by the runner — never via positional args. The current set for stage-bound hooks:

| Env var | Set by | Available to |
|---------|--------|--------------|
| `ZBUILD_GOAL` | runner | all hooks |
| `ZBUILD_ISSUE` | runner | all hooks (empty string when absent) |
| `ZBUILD_RUN_ID` | runner | all hooks |
| `ZBUILD_TARGET_PLATFORM` | runner (fanout strategy) | role-resolved hooks only |
| `ZBUILD_CURRENT_STAGE` | runner | all stage-bound hooks |

`ZBUILD_CURRENT_STAGE` (PR #438) is the key the per-stage router knob resolver uses to look up `router.timeout_s`, `router.max_turns`, `router.max_iterations`, `router.retries`, and `router.tier` (ADR-017).

### 4. Plugin exit codes (rc)

At the stage-dispatch layer, plugin exit codes are **binary**:

| rc | Meaning |
|----|---------|
| `0` | Success |
| `1` | Error |

ADR-001 §"Error semantics" declared `rc=1` routes to `kind: recovery` plugins and `rc=2` is fatal. This routing was **never implemented** at the stage-dispatch layer. No recovery plugin has ever been registered. `rc=1` at the stage-dispatch layer has always been a terminal error. The rc table in ADR-001 is superseded.

The runner synthesizes the following additional codes for its own signalling — these are **not** part of the plugin-to-runner contract:

| Runner rc | Meaning |
|-----------|---------|
| `5` | Scope violation (build stage) |
| `8` | Verdict blocked |
| `9` | LLM unavailable |
| `10` | Contract validation failure |
| `11` | Inert wiring detected |
| `143` | Signal kill (SIGTERM, translated by runner) |

### 5. Verdict channel: v2 result file

Per ADR-047 §3, the canonical verdict channel for a stage is the **v2 result file** — the primary artifact declared in the stage's manifest (`outputs[primary: true]`). The runner reads this file after `run` completes with `rc=0` to derive the stage verdict.

### 6. Disposition vocabulary

The stage disposition set is:

| Disposition | Meaning |
|-------------|---------|
| `pass` | Stage completed successfully |
| `warn` | Stage completed with advisory findings |
| `fail` | Stage completed with blocking findings |
| `error` | Stage encountered a runtime error |

Structural-failure verdicts (`error`, `corrupt_diff`, `block`) are passed through unclassified from the primary artifact field per ADR-020 amendment #550, so the cycle-blocked predicate (`_cycle_detect_blocked`, ADR-021) can distinguish them from `fail`. This disposition set **supersedes** the informally-inherited `pass|warn|fail|unknown|error|corrupt_diff|block` vocabulary that accumulated across ADR-013, ADR-021, ADR-045.

### 7. Abort/trap ownership

The runner owns the process trap (`core/pipeline/runner.sh`). On abnormal exit:
1. The runner's trap fires.
2. The runner calls the current stage plugin's `cleanup` hook (if declared in manifest).
3. `cleanup` is the plugin's abnormal-exit notification surface — it MUST NOT perform the final teardown; that belongs to the runner's trap.

ADR-025 (abort propagation) covers the full trap lifecycle; this ADR amends it to name `cleanup` explicitly as the plugin's notification surface, not a second `run`.

### 8. Fail-closed artifact scanner contract

Per ADR-001 §"Fail-closed scanner contract": if a plugin declares `provides.artifact_type` but no artifact exists at `outputs[].path` after `run` completes with `rc=0`, the engine emits a synthetic blocking finding. Absent evidence IS blocking evidence.

### 9. Per-stage router configuration surface

The following router knobs are available per-stage (resolved via ADR-017):

| Knob | Template field | Env var | Default |
|------|---------------|---------|---------|
| `timeout_s` | `router.timeout_s` | `ZBUILD_ROUTER_TIMEOUT` | 300 |
| `max_turns` | `router.max_turns` | `ZBUILD_ROUTER_MAX_TURNS` | 25 |
| `max_iterations` | `router.max_iterations` | `ZBUILD_ROUTER_MAX_ITERATIONS` | 10 |
| `retries` | `router.retries` | `ZBUILD_ROUTER_RETRIES` | 0 |
| `tier` | `router.tier` | `ZBUILD_<ID>_TIER` | manifest `config.tier_default` |

`router.tier` is resolved through the manifest layer (#1252, ADR-017 §8). The others are resolved via `_route_resolve_knob` in `core/router/route.sh`. As of #1816, per-stage router config is resolved through the manifest-declared data path before falling through to the template/global config tiers (back-pointer added to ADR-017).

### 10. Phantom declarations (for the record)

The following were declared in the manifest schema or contract documentation and were **never read** by the engine:

- **`valid_verdicts`** — declared in the manifest schema; never read by the runner or dispatch layer. Disposition vocabulary is governed by the v2 result file contract (§6), not a per-manifest allowlist.
- **`rc=1 → recovery routing`** — declared in ADR-001 §"Error semantics"; never implemented at the stage-dispatch layer.
- **`init` and `finalize` at stage-dispatch** — declared in ADR-001 §"Lifecycle ordering"; never called at the stage-dispatch layer.

## Consequences

**Positive:**
- Stage-bound plugin authors have a single document specifying the actual call surface.
- The gap between ADR-001's general contract and the stage-bound reality is now explicit.
- Disposition vocabulary is normalized; semantic drift across ADR-013/021/045 is resolved.

**Negative / costs:**
- Plugins that implemented `init`/`finalize` for stage-bound work need to be audited and migrated to `run` or `cleanup` as appropriate.
- Recovery plugins declared in ADR-001 as a target for `rc=1` have never been invoked; the routing path should be explicitly removed or implemented in a follow-up.

## Implementation Notes (issue #1820)

This ADR documents the current state as of 2026-08-09. No code changes are introduced in this issue; the phantom declarations (§10) are recorded as-found. Removal of dead code and recovery-routing implementation are deferred to follow-up issues.

Relevant code sites:
- `core/plugin-registry/registry.sh` — `plugin_hook_call` dispatches `run` and `cleanup` at the stage layer; `init`/`finalize` calls are absent at this layer.
- `core/pipeline/runner.sh` — synthesizes rc 5/8/9/10/11/143; owns the trap; calls `cleanup` on abnormal exit.
- `core/router/route.sh` — `_route_resolve_knob`, `_route_resolve_timeout`, `_route_resolve_max_turns`, `_route_resolve_max_iterations`, `_route_resolve_retries`.
- `core/pipeline/template.sh` — `template_stage_router_*` accessors; name-mangled env vars for per-stage knobs.

## References

- [ADR-001](ADR-001-plugin-contract.md) — general plugin contract; amended by this ADR (hook lifecycle, rc table).
- [ADR-017](ADR-017-per-stage-router-config.md) — per-stage router knobs; amended by this ADR (noting #1816 manifest layer insertion).
- [ADR-021](ADR-021-pipeline-cycle-semantics.md) — cycle semantics; disposition vocabulary cross-reference.
- [ADR-025](ADR-025-abort-propagation.md) — abort/trap lifecycle; amended by this ADR (cleanup hook ownership clarification).
- [ADR-045](ADR-045-bounded-typed-backward-route.md) — bounded route; disposition vocabulary cross-reference.
- [ADR-047](ADR-047-stage-agnostic-mechanics.md) — stage-agnostic mechanics; v2 result file (§3).
