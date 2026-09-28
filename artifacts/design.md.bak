# Design: Migrate intake plugin to contract v2 (#1837)

## Architectural decision summary

**Goal.** Move `plugins/agent/intake` to the v2 stage contract defined by ADR-054/ADR-055: a JSON result file (`intake-result.json`) written on every exit path including signal interruption, rc ∈ {0,1}, router budgets declared in the manifest, `intake-result.json` as the primary output, and `valid_verdicts` enforced.

**Context.** Intake was the last Phase-0 plugin still on the v1 contract (implicit rc, no result file, no disposition vocabulary, empty `valid_verdicts`). Five guard SPECs were mis-tagged — behaviors that were absent at the merge-base and added by this migration — requiring re-tagging to `[change]`. An interruption/SIGTERM path was listed as a third exit category in the issue acceptance checkbox but had no SPEC; SPEC-16 closes that gap. Two downstream test files hardcode intake's primary output as `scope-manifest.md` or omit `intake-result.json` from their golden snapshots and need updating.

**Decision.** Implement all v2 contract requirements in plugin.sh and manifest.yaml; add a SIGTERM trap in `intake_run` that writes a fail/broken result before exiting; create the v1 golden baseline fixtures; update the artifact-type-retirement assertion and parity golden to reflect the new primary output.

```scope
plugins/agent/intake/manifest.yaml
plugins/agent/intake/plugin.sh
plugins/agent/intake/tests/intake-test.sh
plugins/agent/intake/lib/sanitize.sh
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
SPEC-2[change]: ${artifact_dir}/intake-result.json is written on every terminal exit path (success and all failure modes)
SPEC-3[change]: the result file carries result_contract:2, a verdict in {pass,fail}, a disposition in the engine's vocabulary, and a non-empty reason
SPEC-4[change]: manifest declares provides.result_contract: 2
SPEC-5[change]: manifest declares config.valid_verdicts: [pass, fail] (replacing the current [])
SPEC-6[change]: intake-result.json appears in manifest outputs with primary: true; scope_manifest no longer has primary: true
SPEC-7[change]: manifest declares config.router.timeout_s and config.router.max_turns; manifest_router_knob returns non-empty for both
SPEC-8[change]: scope-manifest.md and intake.md content on a passing run is byte-identical to a v1 baseline fixture (the golden captures the existing content; a v2 migration must not alter what downstream sees)
SPEC-9[change]: plugin.result event with plugin=intake is emitted on every success run
SPEC-10[change]: plugin.sh references ZBUILD_ARTIFACT_DIR when resolving artifact_dir — a grep assertion confirms the symbol name is present
SPEC-11[change]: manifest hooks section contains a comment explicitly recording that intake holds no live resources and declares no cleanup hook (ADR-054 §7)
SPEC-12[change]: manifest provides.role: intake is declared and retained after migration (ADR-009/#1704)
SPEC-13[change]: manifest provides.events lists at least the 17 intake.* events present before migration; no event is dropped
SPEC-14[change]: when template_stage_router_timeout_s() is defined and returns a value that differs from the manifest's declared config.router.timeout_s, _route_resolve_timeout must return the template value (template > manifest config.router.* > constant)
SPEC-15[change]: on a successful run, intake-result.json carries a data object with goal_len (integer, character count of the sanitized goal) and platform_count (integer, number of detected platforms)
SPEC-16[change]: when the intake_run subprocess receives SIGTERM mid-run, intake-result.json is written with verdict=fail, disposition=broken before the process exits
WIRING: plugins/agent/intake/manifest.yaml
TESTFILES:
SPEC-1: plugins/agent/intake/tests/intake-test.sh tests/integration/intake-refuse-on-closed-subprocess-test.sh
SPEC-2: plugins/agent/intake/tests/intake-test.sh
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
```
