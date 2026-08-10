# ADR-054: Stage Contract

**Status:** Accepted (2026-08-09)
**Date:** 2026-08-09
**Issue:** #1820
**Amends:**
- ADR-001 — the stage contract is two hooks (§1), rc ∈ {0,1} (§4), and one result file (§5). The rc=1→`kind: recovery` routing is deleted; it was never implemented and no recovery plugin was ever registered.
- ADR-021 — verdict and disposition are separated (§6); the informally-inherited `pass|warn|fail|unknown|error|corrupt_diff|block` set, which carried both axes in one string, is replaced.
- ADR-025 — the runner still owns the trap, but `cleanup` is no longer an abort-only notification: it is dispatched by a `teardown` stage with a `scope` (§7).
- ADR-045 — superseded by the same verdict/disposition split (§6).
**Related:** ADR-001 (plugin contract), ADR-013 (canonical stage list), ADR-017 (per-stage router config), ADR-047 (stage-agnostic mechanics — the parent principle this extends), ADR-055 (inter-stage data contract v2), ADR-056 (run+cleanup-only lifecycle)

## Context

**This ADR is a specification, not a description.** It states the contract Phase 0 (#1819) implements; each section names the issue that delivers it. Where the engine does not yet behave this way, that is recorded as the gap it is — the whole reason for writing it down.

ADR-001 defined the general plugin contract for all plugin kinds. The stage-bound subset was never extracted, and the parts of ADR-001 that touched it were aspirational in a way nothing ever reconciled:

| ADR-001 said | The engine did |
|---|---|
| Four hooks: `init`, `run`, `finalize`, `cleanup` | Five `plugin_hook_call` sites, **all `run`**. Three of the four were never called — including `cleanup`, which 20+ plugins nevertheless implement. |
| `rc=1` routes to `kind: recovery` plugins; `rc=2` is fatal | **No recovery plugin has ever been registered.** Stages return 5, 8, 9, 10, 11, 143. |
| `valid_verdicts` declares a plugin's vocabulary | **No engine code reads it.** Adoption: 1 of 25. |

The pattern is one defect, not three: **a declaration nothing enforces.** An unknown verdict draws a yellow glyph; an undeclared hook returns `0` silently; a zero-byte artifact passes the fail-closed scanner. Unrecognized is never a failure, so the document and the engine were free to drift apart for the life of the project.

ADR-054 fixes the call and response surfaces — hooks, arguments, exit codes, the result file, and the verdict/disposition split. ADR-055 fixes the data and declaration surfaces. Together they are the interface Phase 0 enforces.

### Why this precedes the rest of Initiative 1.3

Initiative 1.3 (#1818) is one defect wearing different clothes across seven phases: the engine and its stages have no enforced interface. Phase 1 (#1794) makes a failing leaf stage stop the run — the single most valuable change in the milestone, and **unshippable without this contract**.

Today a router timeout surfaces as `verdict=error`. Make a failing verdict terminal without first separating *what happened* from *what to do about it*, and a network hiccup on `intake` or `impact` becomes a dead run. `interrupted` and `throttled` exist so that the same event can stop a run that is genuinely broken and retry one that merely stalled. That is the whole reason the disposition vocabulary (§6) is a declared field rather than a string the engine re-interprets.

The same dependency runs through the rest: Phase 3 cannot enforce declarations that were never load-bearing (ADR-055), Phase 4 cannot safely delete code whose reachability nothing can prove, and Phase 5's acceptance work measures assertions against a result file whose shape this ADR fixes. **Every phase either depends on this contract or is a consequence of not having had one.**

## Decision

### 1. The call surface: two hooks

The contract has exactly **two** hooks:

| Hook | Required | Invoked by |
|------|----------|------------|
| `run` | Yes | Every stage dispatch |
| `cleanup` | No | A `teardown` stage, with a `scope` (§7) |

`init` and `finalize` are deleted from the contract. ADR-056 (#1828) carries out that deletion and owns the resulting lifecycle — including registration-time enforcement of `run` and the `rc=3` sentinel that distinguishes an absent optional hook from one that ran. This ADR does not restate those rules; it specifies the two surviving hooks' arguments (§2) and `cleanup`'s trigger and scope (§7).

**What was true before this contract.** Three of the four hooks ADR-001 documented were never called: there are five `plugin_hook_call` sites in the engine and every one passes `run`. `init` and `finalize` were dead. `cleanup` was also dead — never dispatched by anything — yet **20+ plugins ship one**, written to a documented interface and drifting untested for the life of the project. That is the failure mode this ADR exists to end: a document describing a lifecycle the engine implemented one fifth of, with nothing reconciling the two.

### 2. Hook signatures

```
run(stage_id, state_file, resolved_inputs)
cleanup(stage_id, state_file, scope)
```

- `stage_id` — the dispatching stage's id.
- `state_file` — absolute path to `pipeline-state.json`. Plugins derive `state_dir = dirname($2)` and `artifacts_dir = $state_dir/artifacts`.
- `resolved_inputs` — the engine resolves every input the manifest declares and hands them over. **A plugin never rebuilds a path.** Delivered by #1826; until then a plugin reads its declared inputs itself.
- `scope` — `release` or `purge` (§7).

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

### 4. Exit codes (rc)

Exit codes are **binary — everywhere, not only at the plugin boundary**:

| rc | Meaning |
|----|---------|
| `0` | Success |
| `1` | Error |

ADR-001 §"Error semantics" declared `rc=1` routes to `kind: recovery` plugins and `rc=2` is fatal. This routing was **never implemented** at the stage-dispatch layer. No recovery plugin has ever been registered. `rc=1` at the stage-dispatch layer has always been a terminal error. The rc table in ADR-001 is superseded.

`rc=0` means "my result file is on disk, read it." `rc=1` means "I failed — read my result if present; if it is absent I died, and I am `broken`." **`rc=0` with a missing or unparseable result is a structural failure, not a warning.**

Everything anything needs to say beyond those two facts belongs in the result file (§5), not in an exit code.

**This binds engine-internal paths too.** The engine currently signals through a private rc vocabulary — `5` blocked, `6` cycle_abort, `8` blocking_member_failure, `9` llm_unavailable, `10` scope_too_large, `11` route_back, `130`/`143` signal. It is a vocabulary that grew one caller at a time, each reader mapping it differently, and it fails the same way the plugin-side table did: `cycle_orchestrator_run` special-cases only `8`, `11` and `130` and collapses every other abort rc to `4` (`config_invalid`), so a `cycle_abort` and a SIGTERM both surface as a configuration error. #1225 fixed that collapse for `11` alone.

An integer channel with no declared vocabulary cannot be enforced, which is the defect this whole ADR exists to remove — exempting the engine from its own contract would reproduce it one layer down.

So the control flow those codes carry moves onto declared channels: `disposition` (§6) for recoverability, and explicit routing state for the bounded backward edge (ADR-045) and blocking-member halt (ADR-013). Those mechanisms keep working; what changes is that a reader consults a declared field instead of re-interpreting a number. **#1823 owns the narrowing and the designs that re-home each signal**, and its acceptance is the enforcing check: no engine path returns or interprets an rc outside {0,1}, with a guard test enumerating the call sites.

### 5. The result file

One file. The primary artifact declared in the stage's manifest (`outputs[primary: true]`), read after `run` returns. Mandatory keys:

| Key | Meaning |
|-----|---------|
| `result_contract` | Version of **this contract** the file speaks |
| `verdict` | The stage's own word for what happened (§6) |
| `disposition` | What the engine should do about it (§6) |
| `reason` | Mandatory free text — rendered to logs and terminal, **never branched on** |

Plus `data: {}` — open, namespaced, and never interpreted by the engine.

`result_contract` is **not** `schema_version`. `schema_version` is the artifact's own schema version and is independent: `build-summary.json` has been at `4` since #602. Conflating the two silently reinterprets every existing artifact.

Delivered by #1821 (landed); version negotiation by #1824.

### 6. Verdict and disposition are different axes

Conflating these is the defect this section exists to prevent — `pass|warn|fail|error` is the **verdict class**, and naming it "disposition" is what left the engine re-deriving recoverability from a word that never encoded it.

**`verdict`** is the stage's own vocabulary — `approve`, `request_changes`, `incomplete`, `empty_diff`, whatever that stage means. It is **declared per-plugin** in the manifest's `valid_verdicts`, and a verdict outside a plugin's declared set is a structural failure (#1708). The engine does not hold a global verdict list.

**`disposition`** is a closed set, owned by the engine. Each word exists only because the engine acts differently on it:

| Disposition | Engine response |
|-------------|-----------------|
| `complete` | Nothing went wrong |
| `interrupted` | Retry as-is |
| `throttled` | Wait, then retry |
| `exhausted` | More budget, or the work must shrink |
| `unavailable` | Halt; operator action required |
| `broken` | Halt; it is a defect |

Recoverability is therefore a **declared field**, not a guess re-derived from a verdict string. `did_not_finish`, `empty_diff`, `scope_too_large` and `inert_build` migrate out of `verdict` into `disposition` (#1832).

This is the section Phase 1 (#1794) waits on. A stage that timed out and a stage that is broken both surface as `verdict=error` today; make that terminal without this split and a transient failure on `intake` kills the run. `interrupted`/`throttled` are what let the engine retry the first and halt the second — and #1823 gates on it for exactly that reason.

This supersedes the informally-inherited `pass|warn|fail|unknown|error|corrupt_diff|block` vocabulary that accumulated across ADR-013, ADR-021 and ADR-045, in which one string had to carry both axes at once. Delivered by #1822.

### 7. Teardown and clean: one code path, two triggers

`cleanup` is **not** an abnormal-exit notification. Scoping it to aborts is precisely what forces every plugin to invent a second teardown path — one for the normal end of work, one for the trap — and the two then drift.

```
plugin.cleanup(scope)      ← only the stage knows what it spawned
      ↑ invoked by
  teardown stage           ← an ordinary plugin, dispatched like any other
      ↑ composed by
  clean.yaml               ← a template
```

Two scopes, one discriminator — **can this be done tomorrow?**

| Scope | Trigger | Does | Never does |
|-------|---------|------|------------|
| `release` | Automatic, at end of work | Frees live resources: kills spawned process groups, closes handles, releases locks | **Deletes nothing** |
| `purge` | Operator-invoked only | Deletes artifacts and staging trees | — |

No → `release`. Yes → `purge`. The rule exists because the inverse destroys evidence: `plugins/tool/test/plugin.sh` `rm -rf`s its staging dir on return and kills nothing, which is exactly backwards — orphaned suites keep running against a deleted tree (#1748).

The runner still owns the process trap (ADR-025); a trap firing does not turn into a `cleanup` dispatch by itself. Delivered by #1829, which depends on #1759 giving the signal traps a single owner.

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

Declared somewhere and read by nothing. Recording them is the point of this ADR: an unenforced declaration is how the contract became fiction.

| Declaration | Status |
|-------------|--------|
| `valid_verdicts` | In manifests, adoption 1 of 25, **no engine code reads it**. This contract makes it load-bearing (§6) — enforced by #1708. It is a gap to close, **not** a field to delete. |
| `rc=1 → recovery routing` | ADR-001 §"Error semantics". No `kind: recovery` plugin has ever been registered; the path was never implemented. Deleted by §4. |
| `init`, `finalize` | ADR-001 §"Lifecycle ordering". Never called. Deleted by ADR-056 (#1828). |
| `cleanup` | Documented since ADR-001 and implemented by 20+ plugins; **never dispatched**. Given a caller by #1829 (§7). |
| `in_type` mismatch check | `contract-validator.sh:289` — parsed, assigned, deliberately unused. Activated by #1827 (ADR-055). |

The distinction that matters: `rc=1` routing and `init`/`finalize` are deleted because nothing needs them. `valid_verdicts`, `cleanup` and the `in_type` check are **kept and wired up**, because the contract depends on each. Deleting an unenforced declaration and enforcing it are both honest; leaving it declared and unread is not.

## Consequences

**Positive:**
- One document specifies the stage call and response surface; every Phase 0 issue cites it instead of re-deriving it.
- Recoverability becomes a declared field (`disposition`) rather than a guess re-derived from a verdict string.
- `verdict` becomes per-plugin data (`valid_verdicts`) instead of a global list the engine has to keep guessing at.
- Unrecognized stops being free: an undeclared verdict, an absent required hook, and an `rc=0` with no result are all structural failures.

**Negative / costs:**
- Every plugin manifest and most `plugin.sh` files change. The F-wave migrations (#1833–#1849) carry that, one plugin per PR.
- The engine must read v1 and v2 results concurrently until the last plugin migrates; #1850 removes the v1 path and the no-result fallbacks together.
- Stricter contracts surface latent breakage: runs that previously continued on an unparseable result now fail. That is the intent, and it is why #1821–#1823 gate #1798.

## Implementation Notes (issue #1820)

**No code changes in this issue.** This ADR is the specification; the table below is the delivery map. A section describing behaviour the engine does not yet have is a specification, not a claim about today.

| § | Contract | Delivered by |
|---|----------|--------------|
| 1 | Two hooks; `init`/`finalize` deleted | ADR-056 / #1828 — landed |
| 2 | `run(stage_id, state_file, resolved_inputs)` | #1826 |
| 4 | rc ∈ {0,1}; classify an `rc=1` that left no result | #1823 |
| 5 | One result file, `result_contract` version key | #1821 — landed; negotiation #1824 |
| 6 | Disposition vocabulary + engine response table | #1822; verdict migration #1832; `valid_verdicts` enforcement #1708 |
| 7 | `cleanup(scope)`; teardown stage; `clean.yaml` | #1829, after single-owner traps #1759 |

Relevant code sites as of writing:
- `core/plugin-registry/lifecycle.sh` — `plugin_hook_call`; the only hook dispatcher.
- `core/pipeline/verdict.sh` — result reading and verdict classification.
- `core/pipeline/runner.sh` — owns the signal traps; synthesizes the runner-internal rcs listed in §4.
- `core/router/route.sh` — `_route_resolve_knob` and the per-knob resolvers (§9).
- `core/pipeline/template.sh` — `template_stage_router_*` accessors.

## References

- [ADR-001](ADR-001-plugin-contract.md) — general plugin contract; amended by this ADR (hook lifecycle, rc table).
- [ADR-017](ADR-017-per-stage-router-config.md) — per-stage router knobs; amended by this ADR (noting #1816 manifest layer insertion).
- [ADR-021](ADR-021-pipeline-cycle-semantics.md) — cycle semantics; disposition vocabulary cross-reference.
- [ADR-025](ADR-025-abort-propagation.md) — abort/trap lifecycle; amended by this ADR (cleanup hook ownership clarification).
- [ADR-045](ADR-045-bounded-typed-backward-route.md) — bounded route; disposition vocabulary cross-reference.
- [ADR-047](ADR-047-stage-agnostic-mechanics.md) — stage-agnostic mechanics; the parent principle. Its thesis — the mechanics read declared data, never stage names — is this contract one level up.
- [ADR-055](ADR-055-inter-stage-data-contract-v2.md) — the data and declaration surfaces; written with this ADR.
- [ADR-056](ADR-056-run-cleanup-only-lifecycle.md) — carries out the `init`/`finalize` deletion and owns the resulting hook lifecycle (§1).
