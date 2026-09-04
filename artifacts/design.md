# Design — Migrate spec-acceptance to contract v2

## Architectural Decision Summary

**Goal.** Adopt the ADR-055 v2 inter-stage data contract in `plugins/agent/spec-acceptance`,
bringing it into parity with the other F-wave plugin migrations (#1833–#1849). The gate's
observable behavior — verdict semantics, disposition classification, event emission, negctl/
reachability levels — is unchanged; only the result file envelope, input-resolution pattern,
and summary-completeness move.

**Context.** The v2 contract requires four things spec-acceptance currently lacks:
(1) `result_contract:2` in the emitted JSON on every exit path;
(2) a `disposition` field on the precondition_unmet and malformed paths (already present on the
    main pass/fail path);
(3) a summary artifact (`acceptance-summary.txt`) on every terminal path — ADR-055 §9 mandates
    this unconditionally; the plugin currently skips the write on precondition_unmet and malformed
    exits, leaving `acceptance_detail` legitimately `required: false`; after this change both paths
    write a summary, so `required: false` becomes `required: true`;
(4) name-matched input resolution via `ZBUILD_STAGE_INPUTS` (ADR-055 §1) instead of the hardcoded
    `local design_md="$artifact_dir/design.md"` at plugin.sh:239.

Additionally, the `|| true` on the main summary write (plugin.sh:538) must be removed — under
`set -euo pipefail`, a bare atomic_write failure is a genuine error, not a silent skip.

Backwards compatibility: `failures` and `fault` stay at the top level of the result JSON (not
moved under `data:`), because `plugins/agent/build/lib/context.sh` and `core/pipeline/verdict.sh`
read them there and neither is in this migration's scope.

**Decision.** Two focused manifest edits, ~40 lines of plugin.sh edits across four change sites,
and five test-helper updates to set ZBUILD_STAGE_INPUTS alongside the existing `cp design.md`.
A new integration test (`acceptance-gate-v2-contract-test.sh`) is the TDD red step and bears all
four [change] SPEC assertions.

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
docs/adr/ADR-036-acceptance-contract-teeth.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/wiki/plugins/spec-acceptance.md
```

### Scope rationale

**`tests/unit/summary-producers-test.sh`** — line 53–54 pins the `required` field for
`acceptance_detail`:
```bash
assert_eq "[SPEC-1] declared optional — a no-op run writes no summary" "false" \
    "$(manifest_graph_get_outputs "$ACC_M" | grep '^acceptance_detail|' | cut -d'|' -f4)"
```
This asserts the OLD value `false`. Changing `acceptance_detail` to `required: true` in the
manifest makes this assertion fail — not because any constant was grepped away, but because the
4th pipe-delimited field (the `required` column) changes from `false` to `true`. The test label
("declared optional") and expected value both become wrong. In scope: the file must be updated
to assert `true` and reflect the new rationale.

**`docs/wiki/plugins/spec-acceptance.md`** — embeds a verbatim manifest YAML block that shows
the old shape (no `result_contract:`, no `acceptance_detail`, stale `source: stage:design` input
form). lint-doc-freshness validates prose structure, not manifest content, so CI will not fail;
nevertheless this is a contract-describing doc and must be updated for accuracy.

**`docs/adr/ADR-036-acceptance-contract-teeth.md`** — references the summary write path and
the acceptance_detail declaration; no edit required but cited by this PR.

**`docs/adr/ADR-054-stage-contract.md`** — defines the v2 result file contract; authoritative
reference; no edit.

**`docs/adr/ADR-055-inter-stage-data-contract-v2.md`** — §9 uses `acceptance-summary.txt` as
the worked example of an undeclared output; names this migration's exact changes as the
obligation. No edit; governs the migration.

**Files NOT in scope:** `plugins/agent/build/lib/context.sh` and `core/pipeline/verdict.sh`
read `failures`/`fault` at the top level — those fields are unchanged. `config/templates/simple.yaml`
references the `acceptance_gate` role (not the plugin id) — unchanged. `tests/integration/
self-host-contract-lib-redirect-test.sh` sources `plugin.sh` but does not call `acceptance_gate_run`
or inspect result JSON. `tests/unit/acceptance-disposition-classify-test.sh` and
`acceptance-negctl-test.sh` source internal helpers only — no result-shape assertions.

---

```acceptance
SPEC-1[change]: result_contract:2 is present on every terminal exit path of acceptance_gate_run — precondition_unmet (both preconditions), malformed_acceptance_block, pass, and fail
SPEC-2[change]: acceptance-summary.txt is written on the precondition_unmet path and on the malformed_acceptance_block path, so acceptance_detail exists on every terminal verdict (making required:true correct)
SPEC-3[change]: design_md is resolved from ZBUILD_STAGE_INPUTS JSON index (jq -r .inputs.design) rather than the hardcoded $artifact_dir/design.md path — plugin.sh has zero grep hits for the literal string '$artifact_dir/design.md' after this change
SPEC-4[guard]: all existing acceptance-gate behavioral contracts are unchanged — verdict semantics, disposition classification, event emission, negctl/reachability levels, fault routing
WIRING:
plugins/agent/spec-acceptance/plugin.sh
TESTFILES:
SPEC-1: tests/integration/acceptance-gate-v2-contract-test.sh
SPEC-2: tests/integration/acceptance-gate-v2-contract-test.sh
SPEC-3: tests/integration/acceptance-gate-v2-contract-test.sh
SPEC-4: tests/integration/acceptance-gate-test.sh tests/integration/acceptance-gate-reachability-test.sh tests/integration/acceptance-gate-quiet-test.sh tests/integration/acceptance-gate-inert-wiring-iter1-test.sh tests/integration/acceptance-guard-regressed-routes-design-test.sh
```

LOOP_COMPLETE
