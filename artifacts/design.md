# Design: Migrate validate plugin to stage contract v2 (issue #1845)

## Architectural Decision Summary

**Goal.** Adopt the ADR-054 / ADR-055 v2 stage contract in `plugins/agent/validate`:
v2 result file shape (`result_contract:2`, `verdict`, `disposition`, `reason`, `data:{}`),
`ZBUILD_STAGE_INPUTS` for input path resolution, rc ∈ {0,1} on every exit path,
and `result_contract: 2` in the `provides:` block of the manifest.

**Context.** The validate plugin currently writes `schema_version:1` result JSON with no
`disposition` field, constructs the deploy_result input path as a hardcoded
`$artifacts_dir/deploy-result.json` (bypassing the engine's name-matched resolution), and
returns `rc=2` on three error paths — all of which violate the v2 contract enforced by
the engine's versioned reader for stages that declare `result_contract: 2`. The plugin
makes no LLM calls, so router/turn-budget fields are not applicable. Template wiring in
`deployed.yaml` already exists; no template change is needed.

**Decision.** Tests-first:
1. Add SPEC-14..18 to `validate-test.sh` and confirm each FAILS at the merge-base before
   touching any implementation.
2. Update existing SPEC-9/11/12 test fixtures to export a minimal `ZBUILD_STAGE_INPUTS`
   JSON so they resolve `deploy_result` correctly after the v2 input path change.
3. Add `result_contract: 2` to the manifest `provides:` block.
4. Rewrite `_validate_agent_run_inner`: resolve `deploy_result` path from
   `ZBUILD_STAGE_INPUTS` (`jq .inputs.deploy_result`); add a `_validate_write_result`
   helper that writes `{result_contract:2, verdict, disposition, reason, data:{}}` via
   `atomic_write`; replace every `printf/jq` result write with helper calls using correct
   disposition words; clamp all `return 2` exits to `return 1`; guard
   `validate_agent_run` to emit a v2 error result when `state_file` is absent.
5. Update the deployed-template e2e integration test to export a minimal
   `ZBUILD_STAGE_INPUTS` JSON before calling `validate_agent_run`.
6. Update `docs/wiki/plugins/validate.md` to reflect the v2 manifest shape.

Disposition mappings: missing required input (`deploy_result` not found) or missing
health-check plugin binary → `broken`; healthy probe or failed probe (ran to completion)
→ `complete`; dry-run → `complete`.

```scope
plugins/agent/validate/manifest.yaml
plugins/agent/validate/plugin.sh
plugins/agent/validate/tests/validate-test.sh
tests/integration/deployed-template-e2e-test.sh
docs/wiki/plugins/validate.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
config/templates/deployed.yaml
scripts/lib/lint-disposition-words.sh
core/pipeline/disposition.sh
```

```acceptance
SPEC-14[change]: every terminal exit path of _validate_agent_run_inner writes a result file containing all four mandatory v2 keys — result_contract=2, verdict, disposition, and reason
SPEC-15[change]: manifest provides block carries result_contract: 2
SPEC-16[change]: plugin.sh resolves the deploy_result input path from ZBUILD_STAGE_INPUTS (jq .inputs.deploy_result) — no hardcoded $artifacts_dir/deploy-result.json path construction remains
SPEC-17[guard]: a failed health probe (hc_rc != 0) causes validate_agent_run to return non-zero — the #757 fail-closed invariant is preserved under v2
SPEC-18[change]: all non-zero exits from plugin.sh use rc=1 — no exit path returns rc=2 or higher
WIRING: plugins/agent/validate/manifest.yaml
TESTFILES:
SPEC-14: plugins/agent/validate/tests/validate-test.sh
SPEC-15: plugins/agent/validate/tests/validate-test.sh
SPEC-16: plugins/agent/validate/tests/validate-test.sh
SPEC-17: plugins/agent/validate/tests/validate-test.sh
SPEC-18: plugins/agent/validate/tests/validate-test.sh
```

LOOP_COMPLETE
