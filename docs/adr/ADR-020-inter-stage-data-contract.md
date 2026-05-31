# ADR-020: Inter-Stage Data Contract + Pre-flight Validator

**Status:** Proposed (2026-05-30)
**Issue:** #496
**Date:** 2026-05-30
**Related:** ADR-001 (plugin contract), ADR-006 (resume contract), ADR-013
(canonical stages), ADR-015 §v4 (stage I/O capture and ordering), ADR-019
(review fail-closed precedent)

## Context

zBuild stages communicate by leaving typed files at well-known paths under
`$ZBUILD_STATE_DIR/artifacts/`. The producer–consumer contract has existed
implicitly across the codebase since Phase 0.5: `build` reads `plan.json`,
`review` reads `plan.json` + `diff.patch` + `test-results.json`, `pr-open`
reads `review.json`, and so on. But the contract was never formal:

- Plugin manifests declared `inputs:` and `outputs:` as a free-form list of
  `{name, type, path}` triples with no relationship between consumer names
  and producer names. A consumer's input "plan" had no machine-checkable
  link to the producer's output "plan".
- Templates declare which stages run (and in what order), but the runner
  had no way to know whether the stage list was *coherent* before
  execution began. The class of bug fixed by ADR-019 (#485) — `standard.yaml`
  was missing the `test` stage and `review` silently approved diffs that
  had never been tested — is exactly the failure mode this contract closes
  at the engine layer rather than the prompt layer.
- A typo in a manifest path template (`${artifac_dir}/foo.json`) was a
  silent runtime miss instead of a load-time error.

This ADR codifies the inter-stage data flow into manifest schema and
adds a pre-flight validator that runs at pipeline start. It mirrors ADR-004
(redaction chokepoint) and ADR-015 (stage I/O capture): one chokepoint, one
contract, one place to enforce the safety property.

## Decision

### Schema

Plugin manifests grow three fields inside `inputs:` and `outputs:` entries:

```yaml
inputs:
  - id: <consumer-local-id, matches producer output id>
    type: <type>
    source: stage:<producer-id> | external
    required: true | false
    path: ${artifact_dir}/<filename>      # optional; for file-typed inputs

outputs:
  - id: <output-id, referenced by downstream consumers>
    type: <type>
    required: true | false
    path: ${artifact_dir}/<filename>
```

Rename: the previous `- name:` key inside each list entry becomes `- id:`.
The top-level `name:` (human-readable plugin name) is unchanged.

**Empty inputs blocks are malformed.** A plugin with zero stage inputs
MUST declare `inputs: []` explicitly. A missing `inputs:` block is a
schema violation; CI lint and the runtime validator both reject it.

**`required:` defaults to `true` at parse time.** Empty `required:` value
(key present, no value) is malformed. Use `required: false` for optional
inputs (e.g., security-lens's `diff_patch` side-channel from build —
present in main pipeline but not when compound_quality runs standalone).

### Closed templating-var set

Path templates may reference ONLY:

- `${state_dir}` — `$ZBUILD_STATE_DIR` (e.g., `~/.zbuild/state`)
- `${artifact_dir}` — `$state_dir/artifacts/`
- `${stage_io_dir}` — `$state_dir/artifacts/stage-io/` (ADR-015 v1)
- `${run_id}` — sanitized `$ZBUILD_RUN_ID`

Any other `${var}` reference is a load-time error. This is decision #5 of
the consensus.

### External sources allowlist

Inputs declared `source: external` MUST use an id from this hardcoded set:

```
gh_issue_body  gh_issue_view  goal_string  scope_paths  working_tree  git_branch
```

CI lint rejects `source: external` for ids outside this allowlist —
prevents future drift where a plugin author invents a new "external" id
that doesn't actually have a producer anywhere.

### Data flow table

The canonical inter-stage data flow as of Phase 1:

| Stage   | Reads                                                 | Writes                                                          |
|---------|-------------------------------------------------------|-----------------------------------------------------------------|
| intake  | external: `gh_issue_view` / `gh_issue_body`           | `scope_manifest` → `scope-manifest.md`, `intake_goal` → `intake.md` |
| plan    | `scope_manifest` (intake), `goal_string` (external)   | `plan` → `plan.json`                                            |
| build   | `scope_manifest` (intake), `plan` (plan)              | `diff_patch` → `diff.patch`, `build_summary` → `build-summary.json` |
| test    | `diff_patch` (build)                                  | `test_results` → `test-results.json`                            |
| test_assessment | `test_results` (test), `diff_patch` (build, optional) | `test_assessment` → `test-assessment.json`              |
| review  | `scope_manifest`, `plan`, `diff_patch`, `test_results`, `test_assessment` (optional, ADR-022) | `review` → `review.json` |
| pr      | `review` (review)                                     | `pr_url` → `pr-url.txt`, `pr_result` → `pr-result.json`         |

### Pre-flight algorithm

`_contract_validate_pipeline <stage_list_nl> <plugins_root> <state_file>`
lives in `core/pipeline/contract-validator.sh` and runs in
`core/pipeline/runner.sh:main()` immediately after `load_template`
succeeds and before the `--dry-run` short-circuit:

1. Resolve `mode` from `ZBUILD_CONTRACT_VALIDATOR` (default `warn`).
2. Build `_CV_STAGE_MANIFEST[stage_id]` → manifest path by walking
   `plugins_root` and matching each `id:`. Distinguish manifest-absent
   from manifest-unparseable via `manifest_graph_probe_sentinel`
   (decision #4 — high silent-failure mitigation).
3. Build `_CV_STAGE_OUTPUTS_OK[stage_id:output_id]` → 1 for every output
   any stage declares.
4. Walk stages in template order. For each stage:
   - For each input (sorted by id for stable error output):
     - Default `required` to `true` if absent; reject empty `required:` value.
     - Check path template variables against the closed set.
     - If `required: false`, skip the source check.
     - If `source: external`, assert id is on the allowlist.
     - If `source: stage:X`, assert (a) X != self, (b) X is in the template,
       (c) X precedes the current stage in the template, (d) X declares an
       output with the same id.
5. On any violation: emit `pipeline.preflight.fail reason=missing_input`
   with `mode=warn|enforce`. In `warn`, print the structured error and
   return 0 (allow the pipeline to proceed). In `enforce`, write a minimal
   state.json with `status: preflight_failed` and return rc=2.

The runner halts BEFORE intake's `plugin.run.start` fires when the
validator returns rc=2 — verified by the keystone integration test
`tests/integration/pipeline-preflight-missing-stage-test.sh`.

### Rollout escape hatch

`ZBUILD_CONTRACT_VALIDATOR` env var (decision #2):

- `warn` (default for first release) — violations print and emit events,
  pipeline continues. Used to surface drift in real runs while operators
  fix manifests without breaking active pipelines.
- `enforce` — violations halt the pipeline before any stage runs.
- `off` — validator skipped entirely (escape hatch for emergencies).

A follow-up issue flips the default from `warn` to `enforce` after one
release cycle. Removal path documented here so the migration is greppable.

### Resume mode validation (decision #7)

When the runner resumes a pipeline, the pre-flight validator runs the same
contract check, plus a stricter resume-mode assertion: for every input
whose producer is marked `stage_statuses[producer] == "complete"`, the
artifact file at the declared `path:` MUST also exist on disk. This
avoids the stale-artifact silent-pass where state thinks a stage produced
its output but the artifact has been deleted between runs.

Resume-mode artifact-existence checks are deferred to a follow-up issue
(tracked in the implementation notes below); the schema and runtime gate
are shipped in this PR.

### compound_quality dynamic fan-in (decision #8)

`compound_quality` is an orchestrator that fans out to lens plugins
selected at runtime (`security-lens`, future `logic-lens`, etc.). The
inter-stage contract codified here is for the *linear* stage list; the
orchestrator's per-lens fan-out is NOT validated by this MVP. A
follow-up issue will add `dynamic_inputs: from_role: <role>` for
compound_quality's `inputs:` block so the validator can verify the lens
role has at least one registered provider. Until then, security-lens
declares its inputs against the runtime sources (`stage:intake`,
`stage:build`) with `required: false` on the diff side-channel so the
plugin can run standalone outside the compound_quality orchestrator.

### Pre-flight error format

```
✗ Pipeline cannot start — inputs missing for declared stages:

  review: expects 'test_results' (path: ${artifact_dir}/test-results.json)
    source declared: stage:test
    status: stage 'test' is NOT in template 'standard' — add it before 'review'

  review: expects 'diff_patch' (path: ${artifact_dir}/diff.patch)
    source declared: stage:build
    status: OK (produced by 'build')

Fix: edit config/templates/standard.yaml OR override stage list with --stages.
```

Ordering: by template position (stages walked in template order), then
alphabetical by input id within a stage. Golden snapshot:
`tests/golden/contract-errors/missing-test-results.txt`.

Path redaction (decision #12): pre-flight runs before scope-manifest is
finalized, so error messages render absolute paths as `$ZBUILD_STATE_DIR/...`
rather than user-system paths.

### Shared parser

`scripts/lib/manifest-graph.sh` is the single YAML manifest reader used by
BOTH the runtime validator and the CI lint. A parity meta-test
(`tests/unit/preflight-lint-parity-test.sh`) asserts that both callers
produce identical results on the same fixture set; if they ever drift, the
test fails.

### CI lint

`scripts/lib/lint-contract.sh` wired into `npm run lint`:

- Indexes every plugin manifest in `plugins/` matching a canonical stage id.
- For each input with `source: stage:X`: asserts X exists, X declares the
  output id, X is not self.
- For each input with `source: external`: asserts id is on the allowlist.
- Rejects malformed `required:` values and missing `inputs:` blocks.
- Backend plugins (cache/memory/orchestrator/claim-coordinator) are NOT
  in scope — they don't participate in the inter-stage data contract.

### Contract-bypass paths (audit follow-up)

Two existing fail-open fallbacks in `runner.sh` bypass the contract and
are NOT modified in this PR:

- **Template-missing fallback** (runner.sh:158-165) — when the template
  YAML can't be parsed, the runner falls back to the built-in stage list
  `(intake, security-lens, output)`. The pre-flight validator only sees
  what `load_template` produced, so this fallback path is contract-bypass
  by construction.
- **Strategy rc=4 fallback** (runner.sh:444-465) — when the role-based
  strategy dispatch finds no plugin for any role, the runner falls back
  to ID-based resolution. A successful fallback dispatches a plugin whose
  inputs were never declared in any template's roles.

Both are documented here as known contract-bypass paths to audit in a
follow-up. They were intentionally preserved in this PR to keep the
behavior change scoped to the explicit-violation path.

> _Tracking-issue creation for the bypass-path audit is pending; the
> two known bypasses (template-missing fallback at runner.sh:158-165
> and strategy rc=4 fallback) remain documented here until then._

## Consequences

**Positive:**

- A misconfigured pipeline fails at pre-flight, not midway through stage
  execution. Operators see one structured error instead of a partial run
  that left half-written artifacts.
- Plugin authors have a machine-checkable contract: rename an output id
  and CI tells you which consumers need to update.
- The class-of-failure that ADR-019 closed at the plugin layer (review
  approving untested diffs because `test` was missing from `standard.yaml`)
  can also be caught at the engine layer by the pre-flight validator.
- The single chokepoint (`manifest-graph.sh`) means runtime + lint can't
  disagree on what the manifest says.

**Negative / cost:**

- Manifest authorship friction: every input/output now needs `source:`
  and `required:`. The CI lint pushes back at PR time, so the friction
  is front-loaded rather than discovered at pipeline runtime.
- The closed templating-var set blocks legitimate uses (e.g., a future
  plugin that wants `${working_dir}`). Each new var requires an ADR
  amendment.
- The `warn`-default rollout means real deployments will see violations
  in stderr without hard failure for one release cycle; ops needs to
  read the warnings rather than skipping them.

**Open follow-ups:**

- Flip default from `warn` to `enforce` after one release cycle.
- Resume-mode artifact-existence check (decision #7 — stricter check on
  disk, beyond stage_statuses).
- `dynamic_inputs: from_role:` for compound_quality fan-in (decision #8).
- Audit the two known contract-bypass paths (template-missing fallback,
  strategy rc=4 fallback) and either bring them under the contract or
  document them in ADR-001.

## Implementation Notes (Phase 1, issue #496)

Files touched in #496:

- **NEW** `scripts/lib/manifest-graph.sh` — shared YAML parser + graph builder.
- **NEW** `core/pipeline/contract-validator.sh` — runtime pre-flight validator.
- **NEW** `scripts/lib/lint-contract.sh` — CI lint, wired into `npm run lint`.
- `core/pipeline/runner.sh` — integrated validator after `load_template`,
  before `--dry-run` branch.
- `package.json` — `lint` script now invokes `bash scripts/lib/lint-contract.sh`.
- Manifest migration (7 files):
  - `plugins/agent/intake/manifest.yaml`
  - `plugins/agent/plan/manifest.yaml`
  - `plugins/agent/build/manifest.yaml`
  - `plugins/agent/review/manifest.yaml`
  - `plugins/agent/security-lens/manifest.yaml`
  - `plugins/tool/test/manifest.yaml`
  - `plugins/tool/pr-open/manifest.yaml`
- `docs/adr/ADR-006-resume-contract.md` — amended with `preflight_failed`
  pipeline status enum.
- `docs/ARCHITECTURE.md` — cross-link to this ADR.
- Tests (NEW):
  - `tests/integration/pipeline-preflight-missing-stage-test.sh` (keystone)
  - `tests/unit/core-pipeline-contract-validator-test.sh`
  - `tests/unit/lint-contract-test.sh`
  - `tests/unit/plugin-manifest-contract-audit-test.sh`
  - `tests/unit/docs-adr-020-references-test.sh` (meta-test, mirrors #491)
  - `tests/unit/preflight-lint-parity-test.sh` (shared-parser parity)
  - `tests/golden/contract-errors/missing-test-results.txt`

### v1 status pin

ADR-020 ships in **Proposed** with the validator gated by
`ZBUILD_CONTRACT_VALIDATOR=warn` as the first-release default. Status flips
to **Accepted** when the warn → enforce default-flip issue lands.

## References

- [ADR-001](ADR-001-plugin-contract.md) — plugin contract; this ADR extends
  the manifest schema with `source:` + `required:` on inputs/outputs.
- [ADR-006](ADR-006-resume-contract.md) — resume contract; amended with
  `preflight_failed` pipeline status.
- [ADR-013](ADR-013-canonical-stage-list.md) — canonical stage list.
- [ADR-015](ADR-015-stage-io-capture.md) §v4 — stage I/O ordering; this ADR
  follows the same chokepoint pattern for inter-stage data flow.
- [ADR-019](ADR-019-review-fail-closed-on-test-failure.md) — fail-closed
  precedent; this ADR closes the same class of bug at the engine layer.
- `core/pipeline/contract-validator.sh` — runtime entry point.
- `scripts/lib/manifest-graph.sh` — shared parser.
- `scripts/lib/lint-contract.sh` — CI lint.
- `tests/integration/pipeline-preflight-missing-stage-test.sh` — keystone test.

## Verdict convention (#507 amendment)

Every stage-bound plugin's manifest MUST mark exactly ONE entry in `outputs:`
with `primary: true`. The primary output is the canonical artifact the
runner reads to derive the stage-complete indicator (`✓ ⚠ ✗`).

### `outputs[].primary` schema

```yaml
outputs:
  - id: review                       # required
    path: ${artifact_dir}/review.json  # required (path or templated path)
    type: review.json                # required
    required: true                   # required (true|false)
    primary: true                    # NEW (#507) — exactly one per manifest
```

Enforced by `scripts/lib/lint-contract.sh` (fail-closed; `npm run lint`).

### Per-stage verdict source

| Stage         | Primary artifact            | Verdict field            |
| ------------- | --------------------------- | ------------------------ |
| intake        | scope-manifest.md           | rc-fallback (presence)   |
| plan          | plan.json                   | rc-fallback (no field)   |
| build         | build-summary.json          | `.verdict` (schema v3; values: `pass` \| `scope_violation` \| `corrupt_diff`) — falls back to `.scope_violation` for v≤2. Schema v3 also carries optional `.apply_check.{ok,reason,stderr_first_line,truncation_observed,diff_bytes}` populated by the #509 corrupt-diff gate. |
| test          | test-results.json           | `.verdict`               |
| review        | review.json                 | `.verdict`               |
| security-lens | security-findings.json      | informational — always pass on presence (ADR-019) |
| pr            | pr-url.txt                  | rc-fallback (presence)   |

### Verdict → indicator class table

(See ADR-019 Implementation Notes for the canonical table — `pass | warn |
fail | unknown`.)

### Events

#507 registers three new event types (`config/event-schema.json`):

- `stage.verdict.missing` — declared primary artifact absent or malformed.
- `stage.verdict.stale_artifact` — resume found the stage marked complete
  in state but the primary artifact is no longer on disk.
- `pipeline.indicator.unknown_verdict` — `.verdict` field carried an
  unrecognised value (out-of-table); indicator degrades to `⚠`.

### State (`stage_verdicts`)

The runner persists `.stage_verdicts[<stage>]` (one of
`pass|warn|fail|unknown` OR a raw structural-failure verdict
`error|corrupt_diff|block`) alongside `.stage_statuses` for
observability and resume. Schema-additive; older state files are
upgraded in place.

Amendment (#550): the structural-failure raw verdicts
`error|corrupt_diff|block` are preserved unclassified so the cycle
blocked predicate (`_cycle_detect_blocked`, ADR-021) can distinguish
them from generic `fail` (which means "test ran and failed — keep
iterating"). Without this pass-through, `verdict_classify` collapses
all three to `fail` and structural failures silently retry instead of
aborting the cycle.

## Amendment — Cycled stages (issue #512, ADR-021)

The pre-flight contract validator recognises stages declared inside a
`cycles:` block exactly the same way as linear stages: it walks
`_TPL_STAGES[]` in canonical order, resolves each stage's plugin manifest,
and checks `requires.inputs[]` against the producer-output map. Cycle
membership is invisible to the validator — overlay, not replacement.

Cycle `feedback` declarations introduce a new class of input wiring:

```yaml
feedback:
  - from: { stage: test, output: primary.txt }
    to:   { stage: build, input: prior_test_result, required: false }
```

When `required: false`, the validator MUST NOT flag the `to` input as a
missing producer — feedback is delivered file-side at runtime via
`ZBUILD_CYCLE_FEEDBACK_DIR`, not at template-load time. When
`required: true`, the validator confirms the `from` stage actually
produces the named output (existing producer-output map lookup); a
runtime `cycle.feedback.missing` event fires loud if the artifact is
absent at iteration boundary.

## Amendment — Optional inputs in cycle context (issue #511, F2)

Inter-iter feedback flows through a NEW input `source:` discriminator —
`cycle_feedback` — rather than via a sibling `optional_inputs:` block.
This keeps the inputs schema single-rooted and re-uses the existing
graph-walk / lint pipeline:

```yaml
# plugins/agent/build/manifest.yaml
inputs:
  - id: prior_test_failures
    type: text/plain
    path: "${cycle_feedback_dir}/prior_test_failures.txt"
    source: cycle_feedback
    required: false
```

Rules (enforced by both `scripts/lib/lint-contract.sh` and
`core/pipeline/contract-validator.sh`):

1. `source: cycle_feedback` with `required: true` is a contradiction —
   cross-iter feedback is best-effort by definition.
2. `path:` MUST use the new `${cycle_feedback_dir}` canonical var
   (resolves to `$ZBUILD_CYCLE_FEEDBACK_DIR` at expansion time);
   `${artifact_dir}` is rejected — cross-iter data must not pollute the
   artifact namespace.
3. Every `cycle_feedback` input MUST be referenced by some
   `cycles[].feedback.to.input==<id>` — otherwise the input is
   declared-but-unwired (silent failure).
4. Every `cycles[].feedback.to.input=<X>` MUST land on a consumer
   manifest whose `inputs[].id==X` AND `source==cycle_feedback`;
   otherwise the wiring is undeclared (data flows nowhere).

Validator violation codes: `CYCLE_FB_REQUIRED`, `CYCLE_FB_DIR`,
`CYCLE_FB_UNWIRED`, `CYCLE_FB_UNDECLARED`.

The closed templating-var set (decision #5) grows by ONE entry:
`cycle_feedback_dir`. No other var is added; rejection of unknown
`${var}` in input paths still fires for everything else.

> **Cross-reference:** the feedback-path resolution mechanism itself
> (manifest-driven, not hardcoded `<stage>/<output>`) is pinned in
> ADR-021 §"Feedback-path resolution (#511 Pin 2)". F2 (#511) clarified
> this after F1 (#512) shipped with a hardcoded shape that didn't match
> real plugin manifests.

## Amendment — LLM-interpreted verdict stages (#572, ADR-022)

ADR-020's primary-output contract (#507 amendment) recognises a sibling
class of Pattern-1 stages whose primary artifact's `.verdict` is an LLM
**interpretation** rather than a deterministic gate. `test_assessment`
(ADR-022) is the first such stage: its `test-assessment.json` declares
`primary: true`, `type: test_assessment.json`, and the manifest input
contract is:

```yaml
inputs:
  - id: test_results
    type: test_results.json
    source: stage:test
    required: true
    path: ${artifact_dir}/test-results.json
  - id: diff_patch
    type: text/diff
    source: stage:build
    required: false
    path: ${artifact_dir}/diff.patch
outputs:
  - id: test_assessment
    type: test_assessment.json
    primary: true
    required: true
    path: ${artifact_dir}/test-assessment.json
```

The `extract_first_json_object` helper + `ZBUILD_ROUTER_JSON_OUTPUT=1`
wrapping rules (ADR-018 decision #8) apply unchanged. CI lint
(`scripts/lib/lint-contract.sh`) enforces the `primary: true` invariant
on the assessment's output exactly as it does for other Pattern-1
stage-bound manifests.

The verdict enum is broader than the structural `pass|fail|error` set: an
additional value `inconclusive` is permitted to signal LLM uncertainty.
Per-consumer mapping is owned by the consumer (ADR-019 §7 for review;
ADR-021 §"test_assessment as until: source" for the cycle), not by this
schema layer.

Feedback wiring from the assessment's `failure_summary_md` field into
build's `prior_test_failures` input flows through `source: cycle_feedback`
exactly as codified in the #511 amendment above; no new var or
discriminator is introduced.
