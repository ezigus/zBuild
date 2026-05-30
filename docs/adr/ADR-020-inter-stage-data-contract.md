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
| review  | `scope_manifest`, `plan`, `diff_patch`, `test_results` | `review` → `review.json`                                       |
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
