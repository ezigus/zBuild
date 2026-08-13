# ADR-055: Inter-Stage Data Contract v2

**Status:** Accepted (2026-08-09)
**Date:** 2026-08-09
**Issue:** #1820
**Supersedes:** ADR-020 (inter-stage data contract) — presented as a clean v2 at the current stable state; ADR-020 is retired in-place for audit history.
**Amended:** 2026-08-12 (#1768) — §1 replaced. A consumer no longer names its producer; it declares the artifact **names** it needs and the engine resolves each to the single stage in the flow that produces it. `source: artifacts` and `source: cycle_feedback` are retired into the one stage-output kind (§4), leaving two kinds total. Amended rather than superseded: this ADR is three days old and unimplemented, so a v3 would create archaeology for a document nothing was built against.
**Related:** ADR-001 (plugin contract), ADR-006 (resume contract), ADR-013 (canonical stages), ADR-015 §v4 (stage I/O capture), ADR-019 (review fail-closed), ADR-042 (stage portability — completed by §1), ADR-045 (bounded typed backward route — legalises a backwards data edge, §1.3), ADR-046 (design-verify shift-left — the cross-cycle feedback edge this ADR previously failed to account for), ADR-047 (stage-agnostic mechanics)

## Context

ADR-020 codified the inter-stage data contract starting from status Proposed (2026-05-30) and grew through eight amendments covering: verdict convention (#507), cycled stages (#512), optional inputs in cycle context (#511), LLM-interpreted verdict stages (#572), diff.patch semantics post-#608 (#660), schema validator diagnostic contract (#661), review merge-base diff (#896), build design.md decision prose (#916).

Two facts about ADR-020's lifetime are worth naming explicitly:

**1. The mismatch check shipped as a stub.** The pre-flight validator at `core/pipeline/contract-validator.sh:289` contains a comment `# in_type captured for future schema-aware checks`. The validator's type-mismatch enforcement was never implemented; the `in_type` variable was captured but never compared to the producer's declared type. Throughout ADR-020's Proposed lifetime, the validator's default was `warn` (not `enforce`), so violations printed and emitted events but did not halt the pipeline.

**2. valid_verdicts was declared and never read.** ADR-020 §"Verdict convention (#507 amendment)" introduced the `primary: true` manifest field, and the upstream schema had carried `valid_verdicts` as a declared field. The engine never read `valid_verdicts`; the verdict vocabulary is governed by the v2 result file contract and the disposition set in ADR-054 §6.

**3. Duplicate ADR-020 number.** `docs/adr/ADR-020-deferred-tracker.md` also exists, created to track deferred content from the same issue wave. The two files share a number. Superseding via ADR-055 (rather than amending ADR-020 further) is cleaner: it produces one authoritative reference at a stable number, retains ADR-020 for audit history, and removes the ambiguity for readers reconciling the deferred-tracker with the contract document.

ADR-055 presents the same contract as a clean v2 at its current stable state. ADR-020 is retired in-place.

## Decision

### 1. Producer–consumer declaration model

**A stage declares the artifact names it needs and the artifacts it produces. It names no other stage.**

A producer declares each output **once**:

```yaml
outputs:
  - id: <output-id>           # the artifact's name, unique across the flow (§5)
    type: <type>
    required: true | false
    primary: true | false     # exactly one output per manifest declares primary: true
    path: ${artifact_dir}/<filename>
```

A consumer declares **only the name and whether it needs it**:

```yaml
inputs:
  - id: <output-id>           # the same artifact name. No stage, no path, no type.
    required: true | false
```

The engine resolves each input name to the single stage in the flow that produces it, verifies presence **before** dispatch, and hands the resolved paths to `run` (#1826). The template declares the flow; **wiring is derived, not written.** A template may bind an input explicitly to disambiguate, but no case in the tree needs it.

#### 1.1 Why the consumer does not name its producer

Two independent reasons.

**It is redundant.** §5 already requires each output `id` to be claimed by exactly one stage across a resolved flow, enforced with violation code `OUTPUT_DUP`. Measured against `simple.yaml`'s resolved flow: 29 output ids, zero duplicates. An input naming `scope_manifest` therefore identifies its producer already. The pre-flight validator confirms the name was always doing the work — it used the producer name only for self-reference, in-template and ordering checks, while the actual match was *does that stage declare an output whose id equals this input's id*.

**It couples a plugin to a flow position.** ADR-042 established that a stage's flow-name need not equal its plugin `id`, so a plugin is portable across templates. A consumer that hardcodes `intake` re-couples it from the other side: the plugin then only works in a template that happens to name a stage `intake`. Naming the artifact instead completes ADR-042 rather than undoing it, and extends ADR-047's thesis — the mechanics already name no stage; now neither do plugins.

**A consumer never restates `path` or `type`.** Restating them is what let `scope-manifest.md` be declared in `intake/manifest.yaml`, redeclared in `build/manifest.yaml` *with a different type*, and hardcoded a third time in `build/plugin.sh` — where only the third was load-bearing. A declaration that can disagree with the thing it declares is not a contract. Under this model there is no second declaration to disagree, which is why #1827's cross-check largely dissolves rather than being implemented.

#### 1.2 Two input kinds

| Kind | Declared as | Meaning |
|---|---|---|
| stage output | `id: <name>` (default) | an artifact some stage in the flow produces |
| external | `id: <name>` + `source: external` | something from outside the pipeline (§3) |

This replaces four kinds plus a large body of undeclared environment reads. `source: artifacts` (9 uses) and `source: cycle_feedback` (6 uses) both become ordinary stage outputs — the only thing that made them distinct was the assumption that data flows forward, which §1.3 removes. The `stage:` prefix on the remaining 33 is dropped.

**Stages stop reading the environment for data.** One stage declares an external input today while ten plugins read `ZBUILD_ISSUE` directly. Data a stage consumes is declared and resolved; **engine context is not data** and stays ambient — run id, current stage, the plugin identity of ADR-054 §3.1, cycle iteration, map element, target platform. The test is whether the value describes *the work* (declare it) or *the invocation* (ambient).

**Prior-run reuse is deliberately not a third kind.** ADR-050 §1 defines it as self-detection: *"A stage knows only ITS OWN artifact. It asks 'is my prior output present in my working area?'"* There is no producer to resolve and no wire to declare, because the producer is the consuming stage itself in an earlier run — the engine restores the artifact area generically and never learns what any artifact means. Modelling it as an input would require the engine to know that `build`'s prior `build_summary` belongs to `build`, which is exactly what ADR-050 §1 forbids. It stays outside the input model.

#### 1.3 Ordering, and the backwards edge

A producer must appear earlier in the resolved flow, **or the template must declare a re-entry that reaches the consumer again after the producer has run.**

The rule is stated over *re-entry*, not over any one construct, because the constructs change. Two satisfy it today:

- **a `route_back` edge** (ADR-045) — `route_back.to` and `route_back.when.stage` already name both ends
- **shared cycle membership** — a cycle re-runs its own members, so any member may consume any other member's output

Either is a declaration the template already carries, so the ordering check reads data that exists rather than needing new vocabulary. **Nothing in this contract depends on `route_back` specifically**: if #1339 retires the primitive once nested cycles replace the jump, the `design_feedback` edge becomes intra-cycle and satisfies the rule through the second clause instead. That is a deliberate choice — an earlier draft of this section named `route_back` alone and would have made this ADR a new blocker on #1339.

The case that motivated it: `design` (flow position 3) consumes a file written by `gate-aggregator` (position 5), which works because a `route_design` verdict rewinds to `design_verify_cycle` and the file is present on the second pass. Forward-ordering alone rejects that as misordered, and the workaround was an untyped `source: artifacts` read — no producer, no ordering, no validation (#1768). ADR-046, which prescribed the workaround, is amended accordingly.

#### 1.4 Map producers

When the producing stage is a `map` group, the consumer receives the set of its members' outputs. This retires the `lens-*.json` wildcard in `review-aggregator` and the corresponding exemption both checkers carry for it.

#### 1.5 Load-time refusal

Every declared input name must resolve to **exactly one** producer in the flow. Zero producers or two is a refused template, not a runtime surprise — consistent with ADR-047 §5's fail-closed preflights.

Delivered by #1825 (name-matched inputs), #1826 (engine resolves and hands inputs to `run`), #1827 (types declared once by the producer, versioned). Until they land, consumers use the current form — `source: stage:<producer-id>` with a restated `path` and `type` — and the engine validates order only. The 17 F-wave migrations (#1833–#1849) move the plugins one per PR.

### 2. Closed templating-var set

Path templates may reference ONLY:

- `${state_dir}` — `$ZBUILD_STATE_DIR`
- `${artifact_dir}` — `$state_dir/artifacts/`
- `${stage_io_dir}` — `$state_dir/artifacts/stage-io/` (ADR-015 v1)
- `${run_id}` — sanitized `$ZBUILD_RUN_ID`
- `${cycle_feedback_dir}` — `$ZBUILD_CYCLE_FEEDBACK_DIR` (ADR-020 #511 amendment)

Any other `${var}` reference is a load-time error.

### 3. External sources allowlist

Inputs declared `source: external` MUST use an id from this hardcoded set:

```
gh_issue_body  gh_issue_view  gh_comments  goal_string  scope_paths  working_tree  git_branch
```

CI lint (`scripts/lib/lint-contract.sh`) rejects `source: external` for ids outside this allowlist.

`gh_comments` added 2026-08-12 (#1768). §1.2 makes `external` the declared route for everything a stage takes from outside the pipeline, replacing direct environment reads. #1729 — *intake reads only the issue title and body, so every correction made in comments is invisible to the pipeline* — is the first consumer: the correction channel becomes a declared input rather than a missing environment variable.

### 4. Cycle feedback — retired into the stage-output kind

**Amended 2026-08-12 (#1768).** `source: cycle_feedback` is retired. Inter-iteration feedback is an ordinary stage output whose wire runs backwards, made legal by §1.3 rather than by a separate kind:

```yaml
inputs:
  - id: prior_test_failures
    required: false
```

The consumer names the artifact; the engine resolves it to the producing stage; the backwards direction is legal because the cycle declares the edge. Requiredness stays the consumer's property, and feedback is `required: false` because it is absent on the first iteration — a property of the data, not of a special kind.

**Why it was separate, and why that reason is gone.** The discriminator existed because a cycle's feedback arrives from a stage that has not run yet in forward order, which the ordering check rejected. §1.3 makes that legal for every backwards edge, so the kind carried no information the wire did not already have.

**What this fixes as a side effect.** Three of the four violation codes below could never fire. `CYCLE_FB_REQUIRED`, `CYCLE_FB_DIR` and `CYCLE_FB_UNWIRED` all sit inside the runtime validator's source switch, which `contract-validator.sh:317` reaches only for `required: true` inputs — and this kind was *required to be optional*. `CYCLE_FB_UNWIRED` was the worst case: `scripts/lib/lint-contract.sh:236-239` explicitly delegates it to the runtime validator (*"runtime validator owns that"*), which could never reach it, so it was enforced by neither. Only `CYCLE_FB_UNDECLARED` — in a separate pass over cycles — was live.

**Superseded codes:** `CYCLE_FB_REQUIRED`, `CYCLE_FB_DIR`, `CYCLE_FB_UNWIRED`, `CYCLE_FB_UNDECLARED`. The wiring integrity they were meant to protect is now §1.5's single rule: every declared input name resolves to exactly one producer, checked for every input regardless of requiredness.

The `${cycle_feedback_dir}` templating var (§2) is retained for the producer side while cycle feedback is written there.

### 5. Output-uniqueness rule

Each output `id` value MUST be claimed by exactly one stage manifest across the template's resolved stage set. Duplicate output declarations across two stages are refused at pre-flight. Violation code: `OUTPUT_DUP`.

**Amended 2026-08-12 (#1768): this rule is now load-bearing.** It was a de-duplication guard; §1 makes it the mechanism by which an input name identifies its producer. Two consequences follow.

First, `OUTPUT_DUP` can no longer be relaxed without replacing the resolution model — it is the reason a consumer need not name a stage.

Second, uniqueness is scoped to a **resolved flow**, not to the plugin tree. `pr_url` is declared by `merge`, `pr` and `pr-delivery`; `review_report` by both `review-aggregator` and `review-report`. These are alternative implementations selected per template, so each resolved flow still claims every id exactly once — verified: `simple.yaml`'s flow has 29 output ids and no duplicates. A template that admits two producers of one name is refused, which is the correct outcome: the name would be ambiguous.

### 6. Resume-mode artifact-existence check

When the runner resumes a pipeline, the pre-flight validator runs the same contract check, plus: for every input whose producer is marked `stage_statuses[producer] == "complete"`, the artifact file at the declared `path:` MUST also exist on disk. Stale-artifact silent-pass (state thinks a stage produced its output but the artifact was deleted between runs) is caught here. ADR-006 §"preflight_failed status" covers the pipeline status written on enforcement failure.

### 7. Pre-flight validator

`_contract_validate_pipeline` in `core/pipeline/contract-validator.sh` runs in `core/pipeline/runner.sh:main()` immediately after `load_template` succeeds and before the `--dry-run` short-circuit. Controlled by `ZBUILD_CONTRACT_VALIDATOR` env var:

- `warn` — violations print and emit events; pipeline continues.
- `enforce` — violations write `status: preflight_failed` (ADR-006) and return rc=2. The runner halts BEFORE intake fires.
- `off` — validator skipped.

The keystone integration test that verifies enforce-mode behavior is `tests/integration/pipeline-preflight-missing-stage-test.sh`.

### 8. ADR-020 stubs not carried forward

The following ADR-020 content is **not** carried forward into the v2 contract and is noted here for clarity:

- **Type-mismatch check stub** (`contract-validator.sh:289`, `# in_type captured for future schema-aware checks`) — the validator captured the input type but never compared it against the producer's declared type. ~~This remains unimplemented; a follow-up issue will either implement it or remove the stub.~~ **Amended 2026-08-12 (#1768): the stub is to be removed, not implemented.** §1 removes the consumer-declared type, so there is no second declaration to compare against and the mismatch it guarded cannot occur. #1827 shrinks accordingly — from building a cross-check to versioning the producer's single declaration.
- **`valid_verdicts` field** — declared in the manifest schema under `outputs:`; never read by the runner or the pre-flight validator. The verdict vocabulary is governed by the v2 result file contract and ADR-054 §6.
- **`warn` default note** — ADR-020 originally shipped with `warn` as the first-release default and a note to flip to `enforce`. The flip landed in Wave 12-E (#664). The v2 contract treats `enforce` as the operative default.

## Consequences

**Positive:**
- A single authoritative reference at a stable ADR number, without the accumulated amendment noise of ADR-020.
- The stub content (type-mismatch check, `valid_verdicts`) is explicitly named and deferred rather than silently inherited.
- The duplicate-number ambiguity (ADR-020-deferred-tracker.md vs ADR-020-inter-stage-data-contract.md) is resolved by retiring ADR-020 under the new superseded status.

**Negative / costs:**
- Existing cross-references to ADR-020 remain valid (the file is kept for history); new references should cite ADR-055.
- The type-mismatch check stub is still open; this ADR records the gap but does not close it.

## Implementation Notes (issue #1820)

No code changes are introduced in this issue. ADR-055 documents the contract at its current stable state as of 2026-08-09.

Relevant code sites:
- `core/pipeline/contract-validator.sh` — pre-flight validator; type-mismatch stub at line 289.
- `scripts/lib/manifest-graph.sh` — shared YAML manifest parser used by both the runtime validator and the CI lint.
- `scripts/lib/lint-contract.sh` — CI lint; wired into `npm run lint`.
- `core/pipeline/runner.sh` — validator integration point after `load_template`.
- `tests/integration/pipeline-preflight-missing-stage-test.sh` — keystone integration test for enforce-mode behavior.
- `tests/unit/core-pipeline-contract-validator-test.sh` — unit coverage of the validator.
- `tests/unit/preflight-lint-parity-test.sh` — **this claim was wrong and is corrected 2026-08-12 (#1768).** The test does *not* compare the two implementations' results. It asserts that both files contain the string `manifest-graph.sh` and that the shared parser returns non-empty output for one fixture. It is a parser-wiring check, not a parity check — which is why the two implementations were free to diverge on the source vocabulary and on which inputs they validate at all, undetected. #1768 makes it compare verdicts.

## References

- [ADR-001](ADR-001-plugin-contract.md) — plugin contract; this ADR extends the manifest schema.
- [ADR-006](ADR-006-resume-contract.md) — resume contract; `preflight_failed` pipeline status; resume-mode artifact-existence check (§6).
- [ADR-013](ADR-013-canonical-stage-list.md) — canonical stage list.
- [ADR-015](ADR-015-stage-io-capture.md) §v4 — stage I/O ordering; same chokepoint pattern.
- [ADR-019](ADR-019-review-fail-closed-on-test-failure.md) — fail-closed precedent.
- [ADR-020](ADR-020-inter-stage-data-contract.md) — superseded; kept for audit history.
- [ADR-047](ADR-047-stage-agnostic-mechanics.md) — stage-agnostic mechanics; the parent principle (mechanics read declared data, not stage names).
- [ADR-054](ADR-054-stage-contract.md) — stage contract; disposition vocabulary and v2 result file channel.
- `core/pipeline/contract-validator.sh` — runtime entry point.
- `scripts/lib/manifest-graph.sh` — shared parser.
- `scripts/lib/lint-contract.sh` — CI lint.
- `tests/integration/pipeline-preflight-missing-stage-test.sh` — keystone test.
