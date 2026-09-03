# Plan Checkpoint — FINAL

## Files Read
- plugins/agent/design/plugin.sh — current design plugin; uses `design-verdict.json` sidecar only on timeout path (#1261); success/error paths have no result file. rc can be 0, 1, 2 (→ must become 0 or 1 only under v2). No cleanup function (just a comment).
- plugins/agent/design/manifest.yaml — has `primary: true` on design.md (DONE), `provides.role: designer` (DONE), `provides.events` (DONE). Lacks `result_contract: 2`, router budget in config, valid_verdicts only has [incomplete].
- plugins/agent/test-author/manifest.yaml + plugin.sh — v2 reference. Shows result_contract:2, _ta_write_result on every exit path.
- plugins/agent/plan/manifest.yaml — shows config.router.{retries, retry_on_exhaustion} pattern.
- plugins/agent/plan/plugin.sh:49-93 — _plan_budget_guidance and _plan_wallclock_guidance that inject timeout/max_turns into prompt.
- core/router/route.sh:659,671 — _route_resolve_timeout() and _route_resolve_max_turns().
- core/pipeline/verdict.sh:260-281 — _verdict_read_stage_sidecar reads ${stage}-verdict.json generically; design-verdict.json is already the right name.
- config/templates/deployed.yaml:138-146 — design stage has timeout_s:600, max_turns:0 in template (overrides manifest defaults).

## Plan
1. Write test: design-v2-result-contract-test.sh (TDD, fails at baseline — success/error paths don't write result today)
2. Write test: design-budget-prompt-injection-test.sh (TDD, fails at baseline — prompt has no timeout/max_turns today)
3. Update manifest.yaml — result_contract:2, valid_verdicts:[pass,incomplete,error], config.router.{timeout_s,max_turns}, declare design_result output
4. Update plugin.sh — _design_write_result helper + budget guidance functions + write result on all exit paths + ADR-063 prompt injection + fix return 2→1

Existing tests that touch the sidecar (design-timeout-exhaustion-halt, design-router-timeout-reiter) will still pass because the sidecar content is identical — _design_write_result writes the same JSON.
