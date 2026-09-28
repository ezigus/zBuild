# Plan stage checkpoint — issue #1835

## Files read
- plugins/agent/plan/plugin.sh (932 lines) — v1 plugin; emits `plugin.result` via event, no result file; constructs `scope_manifest` path in code
- plugins/agent/plan/manifest.yaml — has `provides.role: planner`, `provides.events`, `valid_verdicts: []`, `result_contract` absent; plan.json output already has `primary: true`
- plugins/agent/plan/tests/plan-test.sh (843 lines) — existing tests; asserts on events and plan.json; no v2 result file assertions yet
- plugins/agent/design/manifest.yaml — reference v2 manifest: `result_contract: 2`, `valid_verdicts: [pass, error, incomplete]`, `router: timeout_s+max_turns`, inputs name-matched
- plugins/agent/design/plugin.sh — writes `design-verdict.json` on all exits; reads `ZBUILD_STAGE_INPUTS` for scope_manifest path
- plugins/tool/teardown/manifest.yaml+plugin.sh — another v2 reference: `result_contract: 2`, `teardown-result.json` primary output

## Conclusions
1. manifest.yaml needs: `result_contract: 2` in provides; `valid_verdicts: [pass, error]`; `router: timeout_s: 300, max_turns: 45`; `plan-result` output entry; scope_manifest input stays (no source:artifacts to convert); cleanup absent = nothing to free.
2. plugin.sh needs: `_plan_write_result` helper writing `plan-result.json` with result_contract:2/verdict/disposition/reason/data; called on every exit path (success, error, scope_too_large, missing-state-file, missing-goal); ZBUILD_STAGE_INPUTS check for scope_manifest path resolution (like design).
3. tests/plan-test.sh needs: new tests asserting v2 result file written on success (verdict=pass, disposition=complete); on error (verdict=error, disposition=unusable); on scope_too_large (verdict=error, disposition=out_of_turns); manifest declares valid_verdicts correctly; no path construction in plugin code (grep test).

## Next if stopped
Write tests first (failing), then manifest, then plugin.sh implementation.
