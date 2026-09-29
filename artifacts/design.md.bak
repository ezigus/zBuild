# Design: Migrate intake plugin to contract v2 (#1837)

## Architectural decision summary

**Goal.** Move `plugins/agent/intake` to the v2 stage contract (ADR-054/ADR-055): write `intake-result.json` on every exit path including SIGTERM, rc ∈ {0,1}, router budgets declared in manifest, `intake-result.json` as primary output, `valid_verdicts: [pass, fail]`, and `result_contract: 2`.

**Context.** Intake is still on the v1 contract. Four behaviors the prior design tagged `[change]` are already present at the current merge-base and must be corrected to `[guard]`: `provides.role: intake` (manifest:76), `provides.events` with 17 entries (manifest:79-97), `emit_event "plugin.result"` (plugin.sh:249-251), and the `ZBUILD_ARTIFACT_DIR` reference (plugin.sh:172). Tagging live behavior as `[change]` would cause the acceptance gate's negative-control step to fail (the test already passes at baseline). SPEC-9, SPEC-10, SPEC-12, and SPEC-13 are corrected to `[guard]`.

The remaining behaviors are genuinely absent: no `result_contract: 2` field, `valid_verdicts: []`, `scope_manifest` carries `primary: true`, no `config.router` block, no `intake-result.json` output written, all failure paths return rc=2, and no SIGTERM trap. These remain `[change]`.

`tests/integration/intake-refuse-on-closed-subprocess-test.sh:81` hard-pins rc=2 (`assert_eq "subprocess: refuse propagates rc=2" "2" "$subprocess_rc"`). This assertion must flip to rc=1 and will fail at baseline — it is the primary [change] test for SPEC-1.

`tests/unit/artifact-type-retirement-test.sh:38` asserts `scope-manifest.md` as intake's result filename (via `manifest_graph_result_filename`). After migration this becomes `intake-result.json`; that assertion needs updating and is currently PASSING at baseline, so it is added to scope as a file the migration breaks.

**Decision.** Implement all v2 requirements in plugin.sh and manifest.yaml: add a SIGTERM trap writing fail/broken before exit, normalize all rc=2 returns to rc=1 in `intake_run` (sub-library functions `lib/issue-state.sh` and `lib/branch-ops.sh` return rc=2 internally; intake_run remaps at the call site), write `intake-result.json` via `atomic_write` on every terminal path, declare router config, update `primary: true`, and update `valid_verdicts`. Golden files for v1 content are created before migration so SPEC-8 can assert byte-identity. Artifact-type-retirement SPEC-1 is updated to assert the new primary filename.

```scope
plugins/agent/intake/manifest.yaml
plugins/agent/intake/plugin.sh
plugins/agent/intake/lib/sanitize.sh
plugins/agent/intake/lib/issue-state.sh
plugins/agent/intake/lib/branch-ops.sh
plugins/agent/intake/tests/intake-test.sh
tests/integration/intake-refuse-on-closed-subprocess-test.sh
tests/unit/artifact-type-retirement-test.sh
tests/golden/parity/artifact-paths.golden
tests/golden/intake-scope-manifest-v1.golden
tests/golden/intake-goal-v1.golden
docs/wiki/plugins/intake.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-017-per-stage-router-config.md
docs/adr/ADR-009-platform-aware-modularity.md
```

```acceptance
SPEC-1[change]: intake_run exits rc=1 (not rc=2) on every failure path — no-goal/no-issue, closed issue, failed fetch, empty-after-sanitization, missing state_file, branch refused
SPEC-2[change]: ${artifact_dir}/intake-result.json is written on every terminal exit path (success, all failure modes, and SIGTERM signal interruption)
SPEC-3[change]: the result file carries result_contract:2, a verdict in {pass,fail}, a disposition in the engine's vocabulary, and a non-empty reason
SPEC-4[change]: manifest declares provides.result_contract: 2
SPEC-5[change]: manifest declares config.valid_verdicts: [pass, fail] (replacing the current [])
SPEC-6[change]: intake-result.json appears in manifest outputs with primary: true; scope_manifest no longer has primary: true
SPEC-7[change]: manifest declares config.router.timeout_s and config.router.max_turns; manifest_router_knob returns non-empty for both
SPEC-8[change]: scope-manifest.md and intake.md content on a passing run is byte-identical to a v1 baseline fixture (golden captures pre-migration content; migration must not alter what downstream sees)
SPEC-9[guard]: plugin.result event with plugin=intake is emitted on every success run (emit_event "plugin.result" already present at plugin.sh:249-251)
SPEC-10[guard]: plugin.sh references ZBUILD_ARTIFACT_DIR when resolving artifact_dir — symbol is already present at plugin.sh:172; grep assertion confirms it is not removed by migration
SPEC-11[change]: manifest hooks section contains a comment explicitly recording that intake holds no live resources and declares no cleanup hook (ADR-054 §7)
SPEC-12[guard]: manifest provides.role: intake is declared and retained after migration — already present at manifest:76 (ADR-009/#1704)
SPEC-13[guard]: manifest provides.events lists at least the 17 intake.* events present before migration; no event is dropped — already present at manifest:79-97
SPEC-14[change]: when template_stage_router_timeout_s() is defined and returns a value that differs from the manifest's declared config.router.timeout_s, _route_resolve_timeout must return the template value (template > manifest config.router.* > constant)
SPEC-15[change]: on a successful run, intake-result.json carries a data object with goal_len (integer, character count of the sanitized goal) and platform_count (integer, number of detected platforms)
SPEC-16[change]: when the intake_run subprocess receives SIGTERM mid-run, intake-result.json is written with verdict=fail, disposition=broken before the process exits
SPEC-17[guard]: plugin.sh contains no hardcoded input artifact path constructions that bypass the engine-provided ZBUILD_ARTIFACT_DIR — grep over plugin.sh for patterns that construct artifact input paths without ZBUILD_ARTIFACT_DIR returns zero matches
WIRING: plugins/agent/intake/manifest.yaml
TESTFILES:
SPEC-1: plugins/agent/intake/tests/intake-test.sh tests/integration/intake-refuse-on-closed-subprocess-test.sh
SPEC-2: plugins/agent/intake/tests/intake-test.sh tests/integration/intake-refuse-on-closed-subprocess-test.sh
SPEC-3: plugins/agent/intake/tests/intake-test.sh
SPEC-4: plugins/agent/intake/tests/intake-test.sh
SPEC-5: plugins/agent/intake/tests/intake-test.sh
SPEC-6: plugins/agent/intake/tests/intake-test.sh
SPEC-7: plugins/agent/intake/tests/intake-test.sh
SPEC-8: plugins/agent/intake/tests/intake-test.sh
SPEC-9: plugins/agent/intake/tests/intake-test.sh
SPEC-10: plugins/agent/intake/tests/intake-test.sh
SPEC-11: plugins/agent/intake/tests/intake-test.sh
SPEC-12: plugins/agent/intake/tests/intake-test.sh
SPEC-13: plugins/agent/intake/tests/intake-test.sh
SPEC-14: plugins/agent/intake/tests/intake-test.sh
SPEC-15: plugins/agent/intake/tests/intake-test.sh
SPEC-16: tests/integration/intake-refuse-on-closed-subprocess-test.sh
SPEC-17: plugins/agent/intake/tests/intake-test.sh
```
