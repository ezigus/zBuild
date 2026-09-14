# Design: gate v2 migration — SPEC-14 + npm test green

## Architectural decision summary

**Goal.** Complete the seven-gate ADR-054/ADR-055 v2 result-contract migration by
adding SPEC-14 assertions to `tests/unit/gate-v2-contract-test.sh` and fixing the
remaining code gaps in `plugins/tool/secret-scan/plugin.sh`.

**Context.** Five prior commits migrated all seven gate plugins: every manifest now
carries `result_contract: 2`, `valid_verdicts`, `primary: true`, `provides.role /
events`, and `required: true` + `summary: true` on a secondary summary output.
SPEC-1 through SPEC-13 cover those manifest fields and the JSON result contract.
Two gaps remain uncovered by tests:

1. **No test asserts the manifest pairing**: SPEC-9..13 check fields individually but
   none asserts that `required: true` AND `summary: true` coexist on the same output
   block (ADR-055 §9 requires both to be present together).

2. **`secret_scan_run` skip paths are silent**: The `no_baseline` and `empty_diff`
   early-return paths in `plugins/tool/secret-scan/plugin.sh` call `atomic_write`
   for the result JSON and then `return 0` without calling `stage_summary_write`.
   ADR-055 §9 mandates the summary output is written on every terminal verdict
   including the earliest bail-out. Because the SPEC-14 file-existence assertion
   uses the `ss-v2` workdir (no_baseline skip path), this is the assertion that
   fails at the merge-base baseline.

3. **`secret_scan_run` pass path has an empty reason**: The pass path calls
   `stage_summary_write ... ""` which renders as `- no findings`. ADR-055 §9
   requires "a summary states what the stage DID" — `"clean diff — no secrets
   found"` names the conclusion; bare absence language does not.

**Decision.** Two files change:

1. `tests/unit/gate-v2-contract-test.sh`: Append SPEC-14 block that
   (a) greps each manifest for the coexistence of `required: true` and
   `summary: true` in any single output block, and (b) asserts the detail/summary
   file exists and is non-empty for every gate using the work directories already
   established by SPEC-2 and SPEC-5.

2. `plugins/tool/secret-scan/plugin.sh`:
   - Add `stage_summary_write` calls to the `no_baseline` and `empty_diff`
     skip paths (so the declared `required: true` summary output is always
     written — making SPEC-14(b) pass for the `ss-v2` workdir).
   - Replace the empty reason string on the pass path with
     `"clean diff — no secrets found"` (ADR-055 §9 non-empty content requirement).

**The red step.** At the merge-base (before commit 6447e3f0), the SPEC-14 assertions
fail because: `[SPEC-14] secret-scan skip → summary file written` fails because
`secret_scan_run` returns from the `no_baseline` path without calling
`stage_summary_write`, so `secret-scan-detail.md` is absent in the `ss-v2` workdir.

No manifest files change; the `required: true` + `summary: true` fields were already
added by the migration commits. SPEC-14(a) (manifest check) would be a [guard] in
isolation, but SPEC-14(b) (file existence for the secret-scan skip path) is the
[change] behavior that fails at baseline, making the overall SPEC-14 tag [change].

```scope
tests/unit/gate-v2-contract-test.sh
plugins/tool/secret-scan/plugin.sh
plugins/tool/coverage-gate/manifest.yaml
plugins/tool/design-gate/manifest.yaml
plugins/tool/gate-aggregator/manifest.yaml
plugins/tool/lint-gate/manifest.yaml
plugins/tool/mutation-gate/manifest.yaml
plugins/tool/secret-scan/manifest.yaml
plugins/tool/shape-floor/manifest.yaml
plugins/tool/coverage-gate/plugin.sh
plugins/tool/design-gate/plugin.sh
plugins/tool/gate-aggregator/plugin.sh
plugins/tool/lint-gate/plugin.sh
plugins/tool/mutation-gate/plugin.sh
plugins/tool/shape-floor/plugin.sh
scripts/lib/stage-summary.sh
scripts/lib/helpers.sh
scripts/lib/test-helpers.sh
scripts/lib/plugin-bootstrap.sh
tests/unit/gate-detail-outputs-test.sh
tests/unit/summary-mandatory-test.sh
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
```

```acceptance
SPEC-14[change]: all seven gate manifests declare exactly one output with both required:true and summary:true (ADR-055 §9 mandatory pairing); every gate's summary/detail file is written and non-empty on every terminal verdict exercised in SPEC-2 workdirs, including secret-scan's no_baseline skip path; secret-scan's pass-path summary names its conclusion rather than stating bare absence
WIRING: plugins/tool/secret-scan/plugin.sh
TESTFILES:
SPEC-14: tests/unit/gate-v2-contract-test.sh
```

LOOP_COMPLETE
