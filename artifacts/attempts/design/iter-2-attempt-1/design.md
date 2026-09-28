# Design: Migrate intake plugin to contract v2 (issue #1837)

## Architectural Decision Summary

**Goal.** Move `plugins/agent/intake` to the v2 stage contract (ADR-054 §4/§5/§6, ADR-055): rc ∈ {0,1} on every `intake_run` exit path; `intake-result.json` written atomically on every terminal path; `result_contract: 2` declared in the manifest; `valid_verdicts: [pass, fail]` replacing the v1 `[]`; router budget knobs declared so the template layer can override them; `primary: true` moved from the markdown `scope_manifest` output to the new JSON result output.

**Context.** Today `intake_run` returns rc=2 on nine distinct failure paths, has no result file, and carries `valid_verdicts: []` — a declaration meaning the verdict vocabulary is unconstrained. The manifest marks `scope-manifest.md` as `primary: true`, conflicting with ADR-054 §5's requirement that the primary output is the v2 JSON result file. Lib functions (`_intake_create_workspace_branch` and friends in `lib/`) return their own error codes; those are internal and are NOT narrowed by this issue — only `intake_run`'s engine-facing rc is narrowed.

`scope_manifest` and `intake_goal` keep their declared IDs, types, and paths. Downstream consumers (build, plan, review-lens, review-report, security-lens, impact) declare these inputs by ID and are unaffected. `inputs: []` is unchanged; `platforms.json` is a runtime side-channel, not a declared input.

`provides.role: intake` and all 17 `provides.events` entries are already declared in the manifest and must be preserved as-is (guards). The manifest currently has no `hooks.cleanup` key and no comment recording that absence; ADR-054 §7 requires the absence be recorded explicitly with a comment — the deploy-release pattern is the model. The current plugin.sh constructs `_intake_art="$(dirname "${2:-}")/artifacts"` — after migration this resolves from `ZBUILD_ARTIFACT_DIR` (engine-provided) with the dirname expression as a fallback only.

**Decision.** Migrate test-first per CLAUDE.md:
1. **`intake-test.sh`** — write failing assertions (rc=1, result file on all paths, manifest structure, golden snapshot, router-knob wiring, cleanup-comment grep, provides-role/events guards, no-consumer-path-construction grep) before touching any implementation.
2. **`manifest.yaml`** — add `result_contract: 2` under `provides:`, add `config.router.{timeout_s: 120, max_turns: 0}`, replace `valid_verdicts: []` with `[pass, fail]`, add new `intake-result.json` output (`primary: true`) before `scope_manifest`, remove `primary: true` from `scope_manifest`, add ADR-054 §7 comment in `hooks:` recording cleanup absence.
3. **`plugin.sh`** — add `_intake_write_result` helper; resolve `artifact_dir` from `ZBUILD_ARTIFACT_DIR` env var with dirname fallback; call `_intake_write_result` on all six exit paths with correct verdict/disposition; change all `return 2` in `intake_run` to `return 1`.

Exit-path verdict/disposition mapping: no-goal+no-issue → fail/misconfigured; closed/locked issue → fail/unavailable; failed fetch → fail/unavailable; missing state_file → fail/broken; empty-after-sanitization → fail/broken; branch refused → fail/misconfigured; success → pass/complete.

```scope
plugins/agent/intake/manifest.yaml
plugins/agent/intake/plugin.sh
plugins/agent/intake/tests/intake-test.sh
plugins/agent/intake/tests/intake-branch-test.sh
plugins/agent/intake/tests/intake-lib-extraction-test.sh
plugins/agent/intake/lib/sanitize.sh
plugins/agent/intake/lib/issue-state.sh
plugins/agent/intake/lib/branch-names.sh
plugins/agent/intake/lib/branch-ops.sh
tests/integration/intake-refuse-on-closed-subprocess-test.sh
scripts/lib/lint-verdict-classify.sh
scripts/lib/lint-disposition-words.sh
tests/unit/lint-verdict-classify-test.sh
tests/golden/parity/artifact-paths.golden
tests/e2e/parity-local-vs-ci-test.sh
docs/wiki/plugins/intake.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-017-per-stage-router-config.md
config/templates/simple.yaml
config/templates/deployed.yaml
core/contract/version.sh
core/pipeline/dispatch-rc.sh
core/plugin-registry/manifest-router-budget.sh
core/router/route.sh
```

```acceptance
SPEC-1[change]: intake_run exits rc=1 (not rc=2) on every failure path — no-goal/no-issue, closed issue, failed fetch, missing state_file, empty-after-sanitization, branch refused
SPEC-2[change]: ${artifact_dir}/intake-result.json is written on every terminal exit path (both success and all failure modes)
SPEC-3[change]: the result file carries result_contract:2, a verdict in {pass,fail}, a disposition in the engine's vocabulary, and a non-empty reason field
SPEC-4[change]: manifest declares provides.result_contract: 2
SPEC-5[change]: manifest declares config.valid_verdicts: [pass, fail] (replacing the current [])
SPEC-6[change]: intake-result.json appears in manifest outputs with primary: true; scope_manifest no longer has primary: true
SPEC-7[change]: manifest declares config.router.timeout_s and config.router.max_turns; manifest_router_knob returns non-empty for both knobs
SPEC-8[guard]: scope-manifest.md and intake.md content on a passing run is byte-identical to a v1 baseline fixture
SPEC-9[guard]: plugin.result event with plugin=intake is emitted on every success run
SPEC-10[change]: plugin.sh references ZBUILD_ARTIFACT_DIR when resolving artifact_dir — a grep assertion confirms the env var name appears in the implementation (no dirname-only path construction)
SPEC-11[change]: manifest hooks section contains a comment explicitly recording that intake holds no live resources and declares no cleanup hook (ADR-054 §7 recording requirement, #1829)
SPEC-12[guard]: manifest provides.role: intake is declared and retained after migration (ADR-009/#1704)
SPEC-13[guard]: manifest provides.events lists at least the 17 intake.* events present before migration; no event is silently dropped (ADR-001/#1717)
SPEC-14[guard]: when template_stage_router_timeout_s() is defined and returns a value that differs from the manifest default, _route_resolve_timeout returns the template value — template layer wins over manifest config.router.timeout_s
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
```

LOOP_COMPLETE
