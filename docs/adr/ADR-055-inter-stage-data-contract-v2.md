# ADR-055: Inter-Stage Data Contract v2

**Status:** Accepted (2026-08-09)
**Date:** 2026-08-09
**Issue:** #1820
**Supersedes:** ADR-020 (inter-stage data contract) — presented as a clean v2 at the current stable state; ADR-020 is retired in-place for audit history.
**Related:** ADR-001 (plugin contract), ADR-006 (resume contract), ADR-013 (canonical stages), ADR-015 §v4 (stage I/O capture), ADR-019 (review fail-closed), ADR-047 (stage-agnostic mechanics)

## Context

ADR-020 codified the inter-stage data contract starting from status Proposed (2026-05-30) and grew through eight amendments covering: verdict convention (#507), cycled stages (#512), optional inputs in cycle context (#511), LLM-interpreted verdict stages (#572), diff.patch semantics post-#608 (#660), schema validator diagnostic contract (#661), review merge-base diff (#896), build design.md decision prose (#916).

Two facts about ADR-020's lifetime are worth naming explicitly:

**1. The mismatch check shipped as a stub.** The pre-flight validator at `core/pipeline/contract-validator.sh:289` contains a comment `# in_type captured for future schema-aware checks`. The validator's type-mismatch enforcement was never implemented; the `in_type` variable was captured but never compared to the producer's declared type. Throughout ADR-020's Proposed lifetime, the validator's default was `warn` (not `enforce`), so violations printed and emitted events but did not halt the pipeline.

**2. valid_verdicts was declared and never read.** ADR-020 §"Verdict convention (#507 amendment)" introduced the `primary: true` manifest field, and the upstream schema had carried `valid_verdicts` as a declared field. The engine never read `valid_verdicts`; the verdict vocabulary is governed by the v2 result file contract and the disposition set in ADR-054 §6.

**3. Duplicate ADR-020 number.** `docs/adr/ADR-020-deferred-tracker.md` also exists, created to track deferred content from the same issue wave. The two files share a number. Superseding via ADR-055 (rather than amending ADR-020 further) is cleaner: it produces one authoritative reference at a stable number, retains ADR-020 for audit history, and removes the ambiguity for readers reconciling the deferred-tracker with the contract document.

ADR-055 presents the same contract as a clean v2 at its current stable state. ADR-020 is retired in-place.

## Decision

### 1. Producer–consumer declaration model

A producer stage declares each output **once** in its manifest:

```yaml
outputs:
  - id: <output-id>           # referenced by downstream consumers
    type: <type>
    required: true | false
    primary: true | false     # exactly one output per manifest declares primary: true
    path: ${artifact_dir}/<filename>
```

A consumer stage references a producer output by `source: stage:<producer-id>` in its inputs block:

```yaml
inputs:
  - id: <consumer-local-id>   # matches the producer's output id
    type: <type>
    source: stage:<producer-id> | external | cycle_feedback
    required: true | false
    path: ${artifact_dir}/<filename>   # optional; for file-typed inputs
```

The engine resolves, validates order, and enforces the graph at load time via the pre-flight validator (`core/pipeline/contract-validator.sh`).

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
gh_issue_body  gh_issue_view  goal_string  scope_paths  working_tree  git_branch
```

CI lint (`scripts/lib/lint-contract.sh`) rejects `source: external` for ids outside this allowlist.

### 4. Cycle feedback discriminator

Inter-iter feedback uses `source: cycle_feedback`:

```yaml
inputs:
  - id: prior_test_failures
    type: text/plain
    path: "${cycle_feedback_dir}/prior_test_failures.txt"
    source: cycle_feedback
    required: false
```

Rules: `source: cycle_feedback` with `required: true` is a contradiction. The path MUST use `${cycle_feedback_dir}`. Every `cycle_feedback` input MUST be referenced by a `cycles[].feedback.to.input` binding, and every such binding MUST land on a declared `cycle_feedback` input. Violation codes: `CYCLE_FB_REQUIRED`, `CYCLE_FB_DIR`, `CYCLE_FB_UNWIRED`, `CYCLE_FB_UNDECLARED`.

### 5. Output-uniqueness rule

Each output `id` value MUST be claimed by exactly one stage manifest across the template's resolved stage set. Duplicate output declarations across two stages are refused at pre-flight. Violation code: `OUTPUT_DUP`.

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

- **Type-mismatch check stub** (`contract-validator.sh:289`, `# in_type captured for future schema-aware checks`) — the validator captured the input type but never compared it against the producer's declared type. This remains unimplemented; a follow-up issue will either implement it or remove the stub.
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
- `tests/unit/preflight-lint-parity-test.sh` — asserts runtime and CI lint produce identical results on the same fixture set.

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
