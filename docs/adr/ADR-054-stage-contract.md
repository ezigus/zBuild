# ADR-054: Stage Contract

**Status:** Accepted (2026-08-09)
**Date:** 2026-08-09
**Issue:** #1820
**Amended:** 2026-08-12 (#1862) — §3.1 added: the engine exports dispatch identity (`ZBUILD_CURRENT_STAGE`, `ZBUILD_PLUGIN`, `ZBUILD_PLUGIN_KIND`, `ZBUILD_PLUGIN_DIR`) at `plugin_hook_call`, scoped to one dispatch. A plugin is self-defining about what it is and can never be self-defining about which stage it serves. `ZBUILD_PLUGINS_ROOT` is explicitly excluded; identity is scrubbed by `env-scrub` per ADR-024, not exempted from it.
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
| `ZBUILD_CURRENT_STAGE` | `plugin_hook_call` (§3.1) | all stage-bound hooks |
| `ZBUILD_PLUGIN` | `plugin_hook_call` (§3.1) | all stage-bound hooks |
| `ZBUILD_PLUGIN_KIND` | `plugin_hook_call` (§3.1) | all stage-bound hooks |
| `ZBUILD_PLUGIN_DIR` | `plugin_hook_call` (§3.1) | all stage-bound hooks |

`ZBUILD_CURRENT_STAGE` (PR #438) is the key the per-stage router knob resolver uses to look up `router.timeout_s`, `router.max_turns`, `router.max_iterations`, `router.retries`, and `router.tier` (ADR-017).

#### 3.1 Dispatch identity — amended 2026-08-12 (#1862)

**The engine states, for exactly the span of one dispatch, which stage this is and which plugin serves it.** The single export point is `plugin_hook_call` (`core/plugin-registry/lifecycle.sh`).

| Variable | Value | Source |
|---|---|---|
| `ZBUILD_CURRENT_STAGE` | the dispatching stage's name | `stage_id` — `$1` of the hook signature (§2) |
| `ZBUILD_PLUGIN` | the serving plugin's `id` | `$plugin_dir/manifest.yaml` |
| `ZBUILD_PLUGIN_KIND` | the serving plugin's `kind` | `$plugin_dir/manifest.yaml` |
| `ZBUILD_PLUGIN_DIR` | the serving plugin's directory | `$1` of `plugin_hook_call` |

**Why the engine and not the plugin.** A plugin is self-defining about *what it is* — `scripts/lib/plugin-bootstrap.sh` resolves `_ZBUILD_PLUGIN_DIR` from the plugin's own `BASH_SOURCE`, needing no engine. It can never be self-defining about *which stage it is currently serving*. Stage name, role and plugin id are three distinct namespaces and only the template holds the mapping: `review_lenses` (stage) is served by `review-lens` (plugin id) via role `review_lens`, and under `map:` all six lens members receive that one stage name. Everything keyed to the flow — the run timeline, `stage_statuses`, the per-stage router knobs — needs the stage name; introspection yields only the plugin id.

The engine's answer cannot differ from the plugin's own: `plugin_hook_call` sources `plugin.sh` from the same directory it stamps, and reads `id`/`kind` from the same manifest the plugin would. It is the plugin's answer plus the axis the plugin cannot reach.

**Why `plugin_hook_call`.** It is the only site reaching all four dispatch arms. The `map:` arm executes a generated standalone script (`core/pipeline/strategies/common.sh`) that the runner cannot export into — but `plugin_hook_call` is that script's last line.

**Lifetime is one dispatch.** Declared `local -x`, not `export`. This reaches the lifecycle's own `plugin.*` emits (which fire outside the plugin subshell), reaches the subshell and anything it spawns, and unsets on return. Identity from stage *N* must not be visible during stage *N+1*; a plain `export` would trade a blank field for a stale one.

**Two owners, two questions, deliberately not merged.** `_ZBUILD_PLUGIN_DIR` (plugin-owned, set at source time) answers *where are my files on disk* and must keep working when a plugin is sourced with no engine present. `ZBUILD_PLUGIN_DIR` (engine-owned, set at dispatch) answers *who is this dispatch for*. In production they are always equal. Plugin code uses the former to locate its own assets; shared engine libraries use the latter to know whom they serve.

**`ZBUILD_PLUGINS_ROOT` is not identity and is not set here.** Every reader spells it `${ZBUILD_PLUGINS_ROOT:-<repo default>}` — it is an operator override, and ADR-024 / `scripts/lib/persona-resolve.sh` forbid relying on it as a root. Engine-setting it would convert an override into a permanent pin. Derive from `ZBUILD_PLUGIN_DIR`.

**Identity does not survive `env-scrub`.** Per ADR-024 the claude spawn is a fresh-user-shell subprocess that must not see `ZBUILD_*` pipeline state, and identity is pipeline state. Every consumer — the router's knob resolver, `stage_io_begin`, envelope stamping — runs in the parent scope before the spawn. `_zbuild_make_fresh_shell` scrubs identity along with everything else, and a regression guard asserts it.

#### 3.2 Context is not data — added 2026-08-12 (#1768)

The variables in §3 and §3.1 are **engine context**: they describe *the invocation*, not *the work*. Everything a stage consumes that describes the work is a **declared input**, resolved by the engine and handed to `run` (ADR-055 §1).

| | Examples | How a stage gets it |
|---|---|---|
| **Context** — describes the invocation | run id, issue number, current stage, plugin identity (§3.1), cycle iteration, map element, target platform, state dir | ambient environment |
| **Data** — describes the work | a scope manifest, a plan, a diff, gate results, the issue body, the goal, the working tree | a declared input |

The discriminator: **would a different template give this a different value for the same work?** Yes → context. No → data.

This line matters because it was not drawn. Exactly one stage declares an external input today while ten plugins read `ZBUILD_ISSUE` straight from the environment — the issue body and the goal are *data*, arriving through the context channel, declared nowhere and checkable by nothing. ADR-055 §1.2 moves them; the variables above stay where they are.

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

#### 4a. Where each signal goes (delivered by #1823)

The destination is never new. Every one of these already had a declared channel the engine was setting alongside the number; the re-homing is to *read the word instead of the integer*, which is why `dispatch_rc_legacy_reason` names the vocabulary rather than inventing one.

| rc | Re-homes onto | Owner |
|----|---------------|-------|
| `130`/`143` signal | `interrupted` (§6) — and the ADR-025 `.abort.signal` sentinel, which already carries abort across subshells | #1823 |
| `124` timeout | `interrupted` (§6). Never reaches the runner today: the router absorbs it and publishes `_ROUTE_LOOP_TERMINATED_REASON=router_timeout` | #1823 |
| rate limit | `throttled` (§6), via the detector's second caller on the loop path (#1723) | #1823 |
| `9` llm_unavailable | `unavailable` (§6) — "halt; operator action required" is what rc=9 already meant | #1823 |
| `10` scope_too_large | `exhausted` (§6) — "more budget, or the work must shrink". The matching *verdict* string migrates in #1832 | #1823 / #1832 |
| `11` route_back | ADR-045 routing state (`_CYCLE_ROUTE_BACK_*`, `cycle.route_back`). The `route_target` vocabulary is #1767 | ADR-045 / #1767 |
| `8` blocking_member_failure | ADR-013's `blocking:true` halt and ADR-021's `disposition: terminal` member contract | ADR-013 / ADR-021 |
| `5` blocked | `_CYCLE_LAST_TERMINATED_REASON ∈ {blocked, no_committed_changes}` + `cycle.blocked` (ADR-021 #528/#1265) | ADR-021 |
| `6` cycle_abort | `_CYCLE_LAST_TERMINATED_REASON=cycle_abort` + `cycle.complete reason=` | ADR-021 |
| `4` config_invalid | `cycle.config.invalid` at load; the runtime collapse-to-4 catch-all has no channel and is a known gap | ADR-021 |

**`5`, `6`, `8`, `11` and `4` deliberately map to NO disposition.** They are control-flow decisions the cycle made, not statements about whether a stage got far enough to produce a verdict worth reading. Forcing them into §6's set would be exactly the invented default this ADR forbids.

**Two recorded discrepancies, neither resolved here.** ADR-026 says `cycle_abort` is rc=5 in four places, while ADR-045, this ADR and the code all say 6 — no issue owns the correction. And `_cycle_handle_terminal_rc` has a `130)` arm but no `143)` arm, so a SIGTERM falls to `*) reason="error"` and is reported as an ordinary error; `dispatch_rc_legacy_reason` maps both to `aborted` so the two signals agree at the boundary, but the orchestrator's own table is still asymmetric.

#### 4b. Coexistence: v1 keeps its rc, v2 is narrowed

**The narrowing is gated on `result_contract`, not applied to every plugin at once.**

A v1 plugin's exit code is still its *only* channel. `plan` reports `scope_too_large` as rc=10 and has no result field in which to say it; `design`, `validate` and `monitor` all `return 2` for a missing `state_file` per ADR-001 §Runtime. Narrowing every plugin today would delete the meaning of all 25 in a single step, and the engine would keep running past conditions that currently stop it — an oversized scope would no longer abort.

So:

| Stage speaks | rc | Held to the `disposition` dictionary? |
|---|---|---|
| `result_contract: 1` (today's 25 plugins) | passes through **unchanged** | No — it declares no disposition, and absence is not an off-set word |
| `result_contract: 2` | narrowed to **{0,1}** | Yes — an off-set word is a structural failure carrying `contract_violation:unknown_disposition:<word>` |

A v2 stage has somewhere else to say everything its rc was carrying, which is precisely what makes narrowing safe for it and unsafe for the others. This is the same versioned coexistence §6 already uses for the vocabulary — consulted at `result_contract >= 2` and nowhere else — and the same one §5 uses for strictness.

The classification of an `rc=1` that left no result (§4a) is **additive and applies to both versions**: an unmigrated stage gets an honest `interrupted`/`throttled`/`broken` on the disposition channel today, with no change to the rc it reports.

**End state.** #1850 drops the v1 reader, the version gate and the legacy mapping together. At that point narrowing is unconditional, every stage is held to the dictionary, and the guard's enumerated inventory goes to zero — becoming the plain rule stated in §4. Until then `tests/unit/dispatch-rc-guard-test.sh` ratchets it: a count may fall, never rise, so the vocabulary cannot grow while it is being retired.

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

The engine owns the response table and every predicate derived from it (`core/pipeline/disposition.sh`, #1822). **Retry is a property of the disposition, not of the stage** — no plugin declares its own retry policy. An off-set word is a structural failure carrying `contract_violation:unknown_disposition:<word>`; the reader returns the declared word unchanged rather than substituting a valid member, because a substituted default is the same unenforced-declaration failure one layer down. A dispatch that returned non-zero and left no readable result resolves to `broken` — the engine's own conclusion, held on the reader's return and the dispatch event. **The engine never writes a disposition into a stage's artifact.**

**Field-name collision (recorded, not yet resolved).** ADR-021's member-disposition contract already writes `.disposition` on plugin primaries with an unrelated closed set — `terminal|recoverable|advisory|none` — read by `_cycle_member_terminal_failure` and produced by `spec-acceptance` and `gate-aggregator`. The two axes genuinely differ: ADR-021 asks *"this member's verdict was `fail` — does that stop the cycle?"*, §6 asks *"did the stage get far enough to produce a verdict worth reading?"*. They chain; neither maps onto the other (`terminal` would have to become `complete`, since the stage itself ran fine). The collision is **inert today** because §6's vocabulary is only consulted at `result_contract >= 2` and every ADR-021 producer is v1. Freeing the field name belongs with the plugin migration (#1832), which is where the two would otherwise meet head-on.

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
| 4 | rc ∈ {0,1}; classify an `rc=1` that left no result | #1823 — landed; legacy mapping removed by #1850 |
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
