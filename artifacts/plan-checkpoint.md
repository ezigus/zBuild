# Plan checkpoint — issue 1839 (spec-acceptance v2 migration)

## Files read and what they told me

- `plugins/agent/spec-acceptance/manifest.yaml` — plugin already has `provides.role`, `provides.events`, `valid_verdicts` (pass/fail), `primary: true` on gate_result, `tier_default: T1`. Missing: `result_contract: 2`. `acceptance_detail` output is `required: false` (must become true per ADR-055 §9).
- `plugins/agent/spec-acceptance/plugin.sh` — 565 lines. Three places that write result JSON: (1) `_ag_noop_precondition_unmet` (line 182), (2) malformed block path (line 265), (3) final result (lines 549–558). Input path `design_md` is constructed at line 239 as `$artifact_dir/design.md` — violates v2 name-matched inputs. Summary is written only when `summary_lines` is non-empty (line 529); not written on precondition_unmet or malformed paths.
- `plugins/agent/spec-coverage/manifest.yaml` + `plugin.sh` — reference v2: manifest has `result_contract: 2` in `provides:`, result JSON has `{result_contract: 2, verdict, disposition, reason, data: {...}}`.
- `tests/integration/acceptance-gate-test.sh` — `_run_gate` and `_run_gate_with_summary` both do `cp "$repo/design.md" "$state_dir/artifacts/design.md"` and call `acceptance_gate_run` directly. Neither sets `ZBUILD_STAGE_INPUTS`.
- `tests/integration/acceptance-gate-quiet-test.sh` — `_run_gate_capture` also copies design.md to artifacts. Same problem.
- `tests/integration/acceptance-gate-inert-wiring-iter1-test.sh` — calls `acceptance_gate_run` directly.
- `tests/integration/acceptance-guard-regressed-routes-design-test.sh` — calls `acceptance_gate_run` directly.
- `plugins/agent/build/lib/context.sh` — reads `.failures[]` from prior_acceptance_feedback.txt. If `failures` moves to `data.failures` this breaks. Plan: keep `failures` at top-level (it's the gate's public API), consistent with "nothing else has to move with it."
- `plugins/tool/gate-aggregator/plugin.sh` — reads `verdict` and `disposition` from gate result (no `failures`).
- `core/pipeline/verdict.sh` — reads `.fault` from gate result at top-level.
- `core/plugin-registry/lifecycle.sh` — confirms `ZBUILD_STAGE_INPUTS` is set for all stages before dispatch.

## Conclusions

- `result_contract: 2` needs adding to manifest `provides:` and to all three result JSON writes in plugin.sh.
- `acceptance_detail` must be `required: true` and written on ALL terminal paths (precondition_unmet, malformed, pass, fail).
- `design_md` path construction must move from `$artifact_dir/design.md` to reading `ZBUILD_STAGE_INPUTS` JSON. Test helpers in ≥4 test files must set ZBUILD_STAGE_INPUTS.
- `failures` and `fault` stay at top-level (they are the gate's public contract read by build and verdict.sh).
- Router budgets: `tier_default: T1` already in config — this plugin never calls model.route; record as N/A in notes.
- `primary: true` already on `gate_result` — no change needed.
- `cleanup` hook absent — correct (no live resources); record as intentionally absent.
- `provides.role` and `provides.events` already declared — no changes needed.

## What I would do next

1. Write new test `tests/integration/acceptance-gate-v2-contract-test.sh` — red assertions for result_contract:2 on all paths, summary on all paths.
2. Update manifest: add `result_contract: 2`, change `required: false` → `required: true`.
3. Update plugin.sh: read design from ZBUILD_STAGE_INPUTS; add result_contract:2 to all JSON writes; write summary on precondition_unmet + malformed paths; remove `|| true`.
4. Update test helpers (4–5 test files) to set ZBUILD_STAGE_INPUTS.
5. Run npm test.
