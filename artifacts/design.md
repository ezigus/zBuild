# Design: Migrate validate plugin to contract v2

## Architectural Decision Summary

**Goal:** Adopt the ADR-054/ADR-055 v2 stage contract in `plugins/agent/validate`:
v2 result file shape (`result_contract:2`, `verdict`, `disposition`, `reason`, `data`),
disposition on every exit path, rc ∈ {0,1}, name-matched input resolution via
`ZBUILD_STAGE_INPUTS`, and `result_contract: 2` in the manifest `provides:` block.

**Context:** The validate plugin pre-migration writes result files with
`{"schema_version":1,"verdict":"..."}` on all exits — no `result_contract`,
`disposition`, or `reason`. It resolves the deploy-result path via a hardcoded
`$artifacts_dir/deploy-result.json` construction, never consulting `ZBUILD_STAGE_INPUTS`.
Three exit paths return `rc=2` (missing state_file, missing deploy-result.json, missing
health-check plugin); the health-probe failure path propagates `$hc_rc` directly (may
be >1). ADR-054 §4b mandates rc ∈ {0,1} for v2 plugins; ADR-054 §5 mandates the four
mandatory result keys; ADR-055 §1 mandates name-matched input resolution. The
fail-closed probe-rc propagation (#757) must be preserved.

ADR-058 C12 (#2211) — "the write boundary attributes by ownership, never by time" — is
noted context only: validate already writes only to its declared output path
(`$artifacts_dir/validate-result.json`), so no write-boundary changes are required.

ADR-003 (models-as-data) and ADR-032 (per-repo prompt overrides) were amended since
the prior design but do not affect this migration: validate makes no LLM calls.
ADR-003 is retained in scope as a reference for `tier_default: T2` confirmation
only.

**Scope corrections from prior design:**
- `tests/integration/per-run-state-isolation-test.sh` is REMOVED from scope. That
  file uses a two-stage minimal template (intake → build) with mock plugins and
  neither sources the validate plugin nor places `deploy-result.json`. The prior
  design's claim that it needed fixing for the input-resolution change was incorrect.
  The file was changed by a later commit (#1845 runner-log diagnostics, ADR-058 C12)
  for unrelated reasons.

**Decision:** Rewrite `_validate_agent_run_inner` and `validate_agent_run` to write
v2 result files on every terminal exit, resolve inputs via `ZBUILD_STAGE_INPUTS`,
clamp all non-zero returns to rc=1, and add `result_contract: 2` to the manifest
`provides:` block. Tests are written first (red→green). `deployed-template-e2e-test.sh`
must set `ZBUILD_STAGE_INPUTS` (a JSON file with `.inputs.deploy_result` pointing to
the deploy-result.json path) before calling the validate plugin.

```scope
plugins/agent/validate/manifest.yaml
plugins/agent/validate/plugin.sh
plugins/agent/validate/tests/validate-test.sh
tests/integration/deployed-template-e2e-test.sh
tests/unit/sigpipe-antipattern-guard-test.sh
docs/wiki/plugins/validate.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
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
