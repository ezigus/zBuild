# Design — Migrate spec-acceptance to contract v2

## Architectural Decision Summary

**Goal.** Adopt the ADR-055 v2 inter-stage data contract in `plugins/agent/spec-acceptance`,
bringing it into parity with the other F-wave plugin migrations (#1833–#1849). The gate's
observable behavior — verdict semantics, disposition classification, event emission, negctl/
reachability levels — is unchanged; only the result file envelope, input-resolution pattern,
and summary-completeness move.

**Context.** The v2 contract requires four things spec-acceptance previously lacked:
(1) `result_contract:2` in the emitted JSON on every exit path;
(2) a `disposition` field on the precondition_unmet and malformed paths (already present on the
    main pass/fail path);
(3) a summary artifact (`acceptance-summary.txt`) on every terminal path — ADR-055 §9 mandates
    this unconditionally; the plugin previously skipped the write on precondition_unmet and
    malformed exits, so `acceptance_detail` was legitimately `required: false`; with both paths
    writing a summary, `required: false` becomes `required: true`;
(4) name-matched input resolution via `ZBUILD_STAGE_INPUTS` (ADR-055 §1) instead of the
    previously hardcoded `local design_md="$artifact_dir/design.md"`.

Additionally, the manifest must declare `valid_verdicts: [pass, fail]` (the only two verdicts
acceptance_gate_run emits), `tier_default: T1` (schema-conformance for a non-routing agent), and
`gate_result` must carry `primary: true`. All are new to this migration; the manifest previously
had none of these v2-required fields. The `|| true` on the main summary write was removed —
under `set -euo pipefail`, a bare `atomic_write` failure is a genuine error, not a silent skip.

Backwards compatibility: `failures` and `fault` stay at the top level of the result JSON (not
moved under `data:`), because `plugins/agent/build/lib/context.sh` and `core/pipeline/verdict.sh`
read them there and neither is in this migration's scope.

**Decision.** Manifest edits to add `result_contract: 2`, `valid_verdicts: [pass, fail]`,
`tier_default: T1`, and declare `acceptance_detail` as `required: true` with `summary: true`;
~40 lines of plugin.sh edits across four change sites; test-helper updates to set
`ZBUILD_STAGE_INPUTS`. A new integration test (`acceptance-gate-v2-contract-test.sh`) is the TDD
red step and bears all four [change] SPEC assertions plus dedicated tests for the new manifest
fields. The `docs/wiki/plugins/spec-acceptance.md` page embeds the old manifest shape and must
be updated.

---

```scope
plugins/agent/spec-acceptance/manifest.yaml
plugins/agent/spec-acceptance/plugin.sh
tests/integration/acceptance-gate-v2-contract-test.sh
tests/integration/acceptance-gate-test.sh
tests/integration/acceptance-gate-quiet-test.sh
tests/integration/acceptance-gate-inert-wiring-iter1-test.sh
tests/integration/acceptance-gate-reachability-test.sh
tests/integration/acceptance-guard-regressed-routes-design-test.sh
tests/unit/summary-producers-test.sh
tests/unit/summary-mandatory-test.sh
tests/unit/lint-verdict-classify-test.sh
tests/unit/impact-tier-test.sh
tests/unit/plugin-primary-output-atomic-test.sh
docs/adr/ADR-036-acceptance-contract-teeth.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/wiki/plugins/spec-acceptance.md
```

### Scope rationale

**`tests/unit/summary-producers-test.sh`** — SPEC-1 asserts that `acceptance_detail` is
declared as the stage's summary with `required: true`. Both assertions pin the manifest shape
this change introduces.

**`tests/unit/summary-mandatory-test.sh`** — sweeps `plugins/*/*/manifest.yaml` and fails if
any stage-bound plugin has zero `summary: true` outputs. Before this migration,
spec-acceptance had no such output; after, `acceptance_detail` carries `summary: true`.

**`tests/unit/lint-verdict-classify-test.sh`** — sweeps all plugin manifests for declared
`valid_verdicts` entries and checks each against ADR-019's verdict table. Adding
`valid_verdicts: [pass, fail]` to spec-acceptance's manifest means spec-acceptance now
contributes entries to that sweep.

**`tests/unit/impact-tier-test.sh`** — sweeps all `plugins/agent/*/manifest.yaml` for
`tier_default` and verifies `resolve_tier` agrees. Before this migration, spec-acceptance had
no `tier_default` (non-routing) so was skipped. After, it declares `tier_default: T1` and
enters the sweep — absence-by-omission gap: the set of tier-declaring plugins GREW.

**`tests/unit/plugin-primary-output-atomic-test.sh`** — sweeps all manifests for
`primary: true` outputs and verifies each is written via `atomic_write` in the plugin's
plugin.sh. spec-acceptance's `gate_result` now carries `primary: true`, adding it to this
sweep. The guard passes (gate_result is already written via atomic_write) but the file is in
scope because it enumerates a set this migration grows.

**`docs/wiki/plugins/spec-acceptance.md`** — embeds a verbatim manifest YAML block. The block
must reflect the new shape: `result_contract: 2`, `valid_verdicts`, `tier_default: T1`,
`acceptance_detail` with `required: true` and `summary: true`, and the input declaration
without a stale `source:` form.

**`docs/adr/ADR-036-acceptance-contract-teeth.md`** — references the summary write path and
the `acceptance_detail` declaration; no edit required but cited by this PR.

**`docs/adr/ADR-054-stage-contract.md`** — defines the v2 result file contract; authoritative
reference; no edit.

**`docs/adr/ADR-055-inter-stage-data-contract-v2.md`** — §9 uses `acceptance-summary.txt` as
the worked example of an undeclared output and names this migration's obligations explicitly.
No edit; governs the migration.

**Files NOT in scope:** `plugins/agent/build/lib/context.sh` and `core/pipeline/verdict.sh`
read `failures`/`fault` at the top level — those fields are unchanged.
`config/templates/simple.yaml` and `config/templates/deployed.yaml` reference the
`acceptance_gate` role (not the plugin id) — unchanged.
`tests/integration/self-host-contract-lib-redirect-test.sh` sources `plugin.sh` but does not
call `acceptance_gate_run` or inspect result JSON.
`tests/integration/cycle-acceptance-terminal-failure-test.sh` mocks the gate with fake JSON
and does not exercise `acceptance_gate_run`.
`tests/unit/acceptance-disposition-classify-test.sh` and `acceptance-negctl-test.sh` source
internal helpers only — no result-shape assertions.

---

```acceptance
SPEC-1[change]: result_contract:2 is present on every terminal exit path of acceptance_gate_run — precondition_unmet (all three preconditions), malformed_acceptance_block, pass, and fail
SPEC-2[change]: acceptance-summary.txt is written on the precondition_unmet path and on the malformed_acceptance_block path, so acceptance_detail exists on every terminal verdict (making required:true correct in the manifest)
SPEC-3[change]: design_md is resolved from ZBUILD_STAGE_INPUTS JSON index (jq -r .inputs.design) rather than the hardcoded $artifact_dir/design.md path — plugin.sh has zero grep hits for the literal string '$artifact_dir/design.md' after this change
SPEC-4[guard]: all existing acceptance-gate behavioral contracts are unchanged — verdict semantics, disposition classification, event emission, negctl/reachability levels, fault routing
SPEC-5[change]: the manifest declares valid_verdicts: [pass, fail] — the only two values acceptance_gate_run emits — and each verdict is exercised by a dedicated test case (pass path and fail path)
SPEC-6[change]: the manifest declares tier_default: T1 as a schema-conformance field for this non-routing agent; plugin.sh makes no model.route call and the router budget checkpoint is structurally inapplicable to this mechanical gate
SPEC-7[change]: the manifest declares exactly one primary: true output (gate_result) — a convergence gate must name its primary result artifact
WIRING:
plugins/agent/spec-acceptance/plugin.sh
TESTFILES:
SPEC-1: tests/integration/acceptance-gate-v2-contract-test.sh
SPEC-2: tests/integration/acceptance-gate-v2-contract-test.sh
SPEC-3: tests/integration/acceptance-gate-v2-contract-test.sh
SPEC-4: tests/integration/acceptance-gate-test.sh tests/integration/acceptance-gate-reachability-test.sh tests/integration/acceptance-gate-quiet-test.sh tests/integration/acceptance-gate-inert-wiring-iter1-test.sh tests/integration/acceptance-guard-regressed-routes-design-test.sh
SPEC-5: tests/integration/acceptance-gate-v2-contract-test.sh
SPEC-6: tests/integration/acceptance-gate-v2-contract-test.sh
SPEC-7: tests/integration/acceptance-gate-v2-contract-test.sh
```

LOOP_COMPLETE
