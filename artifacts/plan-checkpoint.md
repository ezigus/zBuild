# Plan checkpoint — issue 1839 (spec-acceptance v2 migration)

## Files read and what they told me

- `plugins/agent/spec-acceptance/manifest.yaml` — plugin already has `provides.role`, `provides.events`, `valid_verdicts` (pass/fail), `primary: true` on gate_result, `tier_default: T1`. Missing: `result_contract: 2`. `acceptance_detail` output is `required: false` (must become true per ADR-055 §9). No cleanup hook (correct — no live resources).
- `plugins/agent/spec-acceptance/plugin.sh` — 565 lines. Three places that write result JSON: (1) `_ag_noop_precondition_unmet` (line 181-182), (2) malformed block path (line 264), (3) final result (lines 549–558). Input path `design_md` is constructed at line 239 as `$artifact_dir/design.md` — violates v2 name-matched inputs. Summary is written only when `summary_lines` is non-empty (line 529-538); not written on precondition_unmet or malformed paths. Summary write has `|| true` (line 538).
- `plugins/agent/spec-coverage/manifest.yaml` + `plugin.sh` — reference v2: manifest has `result_contract: 2` in `provides:`, result JSON has `{result_contract: 2, verdict, disposition, reason, data: {...}}`.
- `plugins/agent/design/plugin.sh` lines 391-404 — shows the ZBUILD_STAGE_INPUTS pattern: `jq -r '.inputs.design // empty' "$ZBUILD_STAGE_INPUTS"` with fallback when index absent.
- `core/plugin-registry/lifecycle.sh` lines 392-393 — confirms engine sets ZBUILD_STAGE_INPUTS to a JSON file path.
- `tests/integration/acceptance-gate-test.sh` — `_run_gate` and `_run_gate_with_summary` both do `cp "$repo/design.md" "$state_dir/artifacts/design.md"` (lines 45, 66) — must be updated to set ZBUILD_STAGE_INPUTS.
- `tests/integration/acceptance-gate-quiet-test.sh` — line 152 also copies design.md to artifacts — must set ZBUILD_STAGE_INPUTS.
- `tests/integration/acceptance-gate-inert-wiring-iter1-test.sh` — line 46 copies design.md — must set ZBUILD_STAGE_INPUTS.
- `tests/integration/acceptance-gate-reachability-test.sh` — line 32 copies design.md — must set ZBUILD_STAGE_INPUTS.
- `tests/integration/acceptance-guard-regressed-routes-design-test.sh` — line 84 copies design.md — must set ZBUILD_STAGE_INPUTS.
- `tests/integration/acceptance-gate-harness-hermeticity-test.sh` — no design.md reference, no update needed.
- `plugins/agent/build/lib/context.sh` — reads `.failures[]` from prior_acceptance_feedback.txt. Keeping `failures` at top-level is correct.
- `plugins/tool/gate-aggregator/plugin.sh` — reads `verdict` and `disposition` from gate result (no `failures`). Compatible.
- `core/pipeline/verdict.sh` — reads `.fault` from gate result at top-level. Compatible.

## Conclusions

PLAN IS READY. All exploration done.

- `result_contract: 2` needs adding to manifest `provides:` and to all three result JSON writes in plugin.sh.
- `acceptance_detail` must be `required: true` and written on ALL terminal paths (precondition_unmet, malformed, pass/fail).
- `design_md` path construction must move from hardcoded `$artifact_dir/design.md` to reading ZBUILD_STAGE_INPUTS JSON (pattern from design/plugin.sh:397-398), with fallback to artifact_dir for tests that haven't been updated yet — BUT the 5 test helpers will also be updated to set ZBUILD_STAGE_INPUTS properly.
- `failures` and `fault` stay at top-level (they are the gate's public contract read by build and verdict.sh).
- Router budgets: `tier_default: T1` already in config; plugin never calls model.route. N/A.
- `primary: true` already on `gate_result`. No change.
- `cleanup` hook absent — correct (no live resources). No change.
- `provides.role` and `provides.events` already declared. No changes.
