# Design: Migrate validate plugin to contract v2

## Architectural Decision Summary

**Goal:** Adopt the ADR-054/ADR-055 v2 stage contract in `plugins/agent/validate`:
v2 result file shape (`result_contract:2`, `verdict`, `disposition`, `reason`, `data:{}`),
disposition on every exit path, rc ∈ {0,1}, name-matched input resolution via
`ZBUILD_STAGE_INPUTS`, and `result_contract: 2` in the manifest `provides:` block.
Tests written first (red→green).

**Context:** The validate plugin pre-migration writes result files with
`{"schema_version":1,"verdict":"..."}` on all exits — no `result_contract`,
`disposition`, or `reason`. It resolves the deploy-result path via a hardcoded
`$artifacts_dir/deploy-result.json` construction, never consulting `ZBUILD_STAGE_INPUTS`.
Three exit paths return `rc=2` (no state_file arg, missing deploy-result.json, missing
health-check plugin); the health-probe failure path propagates `$hc_rc` directly (may
be >1). ADR-054 §4b mandates rc ∈ {0,1} for v2 plugins; ADR-054 §5 mandates the four
mandatory result keys; ADR-055 §1 mandates name-matched input resolution. The
fail-closed probe-rc propagation (#757) must be preserved.

**ADR-055 amendment 2026-09-27 (since prior design):** §9 now adds three rules keyed on
`capabilities.writes_repository` — how a non-writer stage is framed when receiving stage
summaries from other stages. Validate makes no LLM calls and receives no LLM prompt, so
prompt-framing rules are inert for this plugin. The amendment also does not require
validate to declare `capabilities.writes_repository: true` (validate writes only to its
declared pipeline artifacts, not the git working tree). No scope or SPEC change required
from this amendment.

**ADR-058 C12 context (2026-09-27 amendment):** The C12 amendment introduces undo-and-retry
for first-offense write-boundary violations. Validate already writes only to its two declared
outputs (`validate-result.json`, `validate-summary.md`) under `$artifacts_dir/`, so no
write-boundary changes are required for this migration.

ADR-003 (models-as-data) is retained in scope as a reference for `tier_default: T2`
confirmation only — validate makes no LLM calls.

**Manifest current state (verified):** The manifest already carries the correct v2 input
declaration form (`inputs: - id: deploy_result / required: true` — no `source:`, `path:`,
or `type:` on the input); a `summary: true` output (`validate_summary`); and `primary: true`
on `validate_result`. It is missing only `result_contract: 2` in the `provides:` block.

**Scope corrections from prior design (preserved):**
- `tests/integration/per-run-state-isolation-test.sh` remains EXCLUDED. That file
  uses a two-stage minimal template (intake → build) with mock plugins and neither
  sources the validate plugin nor places `deploy-result.json`.
- `docs/adr/ADR-058-engine-write-boundary.md` is ADDED to scope (changed since prior
  design; referenced as context for write-boundary correctness).

**Decision:** Rewrite `_validate_agent_run_inner` and `validate_agent_run` to emit v2 result
files on every terminal exit via a helper `_validate_write_result`, resolve the deploy_result
input path from `ZBUILD_STAGE_INPUTS` (jq `.inputs.deploy_result`), write output to
`${ZBUILD_ARTIFACT_DIR}/validate-result.json`, clamp all non-zero returns to rc=1, and add
`result_contract: 2` to the manifest `provides:` block. Disposition mappings: missing input
→ `broken`; dry-run → `complete`; healthy probe → `complete`; failed probe → `complete`;
missing hc-plugin → `broken`. Tests written first (red→green). `deployed-template-e2e-test.sh`
must export `ZBUILD_STAGE_INPUTS` and `ZBUILD_ARTIFACT_DIR` before calling validate_agent_run
for SPEC-9 to remain green under v2.

```scope
plugins/agent/validate/manifest.yaml
plugins/agent/validate/plugin.sh
plugins/agent/validate/tests/validate-test.sh
tests/integration/deployed-template-e2e-test.sh
tests/unit/sigpipe-antipattern-guard-test.sh
docs/wiki/plugins/validate.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-058-engine-write-boundary.md
docs/adr/ADR-017-per-stage-router-config.md
docs/adr/ADR-003-models-as-data.md
config/templates/deployed.yaml
scripts/lib/lint-disposition-words.sh
scripts/lib/lint-verdict-classify.sh
core/pipeline/disposition.sh
```

```acceptance
SPEC-14[change]: every terminal exit path of _validate_agent_run_inner writes a result file containing all four mandatory v2 keys — result_contract=2, verdict, disposition, and reason
SPEC-15[change]: manifest provides block carries result_contract: 2
SPEC-16[change]: plugin.sh resolves the deploy_result input path from ZBUILD_STAGE_INPUTS (jq .inputs.deploy_result) — no hardcoded $artifacts_dir/deploy-result.json path construction
SPEC-17[guard]: a failed health probe (hc_rc != 0) causes validate_agent_run to return non-zero — the #757 fail-closed invariant is preserved under v2
SPEC-18[change]: all non-zero exits from plugin.sh use rc=1 — no exit path returns rc=2 or higher
SPEC-19[guard]: manifest config.valid_verdicts declares exactly [healthy, error]; validate-test.sh covers healthy and error via passing assertions
SPEC-20[guard]: manifest has no config.router block — manifest_router_knob returns empty string for timeout_s and max_turns (correct non-routing-stage posture, ADR-017)
SPEC-21[change]: a dry-run invocation with a valid deploy-result writes validate-result.json with result_contract=2, verdict=healthy, disposition=complete, reason present, and data={}; schema_version key is absent
SPEC-22[guard]: manifest outputs array declares validate_result with primary: true — this invariant must not regress under v2 migration
WIRING: plugins/agent/validate/manifest.yaml
TESTFILES:
SPEC-14: plugins/agent/validate/tests/validate-test.sh
SPEC-15: plugins/agent/validate/tests/validate-test.sh
SPEC-16: plugins/agent/validate/tests/validate-test.sh
SPEC-17: plugins/agent/validate/tests/validate-test.sh
SPEC-18: plugins/agent/validate/tests/validate-test.sh
SPEC-19: plugins/agent/validate/tests/validate-test.sh
SPEC-20: plugins/agent/validate/tests/validate-test.sh
SPEC-21: plugins/agent/validate/tests/validate-test.sh
SPEC-22: plugins/agent/validate/tests/validate-test.sh
```

LOOP_COMPLETE
