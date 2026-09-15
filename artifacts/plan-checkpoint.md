# Plan checkpoint — issue 1841 security-lens v2 migration

## Files read and what they told me

- `plugins/agent/security-lens/manifest.yaml` (74 lines): already has `primary: true` on findings output, `provides.role: security-auditor`, `valid_verdicts: []`. MISSING: `result_contract: 2`, `provides.events:`, `config.router:` budget block. `valid_verdicts` must be `[pass, error]` not `[]`.
- `plugins/agent/security-lens/plugin.sh` (193 lines): has two `return 2` calls (must become `return 1`), findings.json missing `result_contract/verdict/disposition/reason` fields, `security_lens_cleanup` stub exists as a comment only (need real function). `security_lens_run` constructs `$state_dir/scope-manifest.md` hardcoded.
- `plugins/agent/security-lens/tests/security-lens-test.sh` (410 lines): extensive existing tests checking `schema_version=1`, `plugin_id`, `stub` — these need updating for v2 shape. No v2 result assertions yet.
- `plugins/agent/review-lens/manifest.yaml`: reference for v2 manifest patterns
- `plugins/agent/design/manifest.yaml`: shows `result_contract: 2` under provides, `config.router:` block, `provides.events:`
- `plugins/agent/spec-acceptance/manifest.yaml` + plugin.sh: shows v2 result writing pattern with `{result_contract:2, verdict, disposition, reason, data}`
- `plugins/agent/spec-coverage/plugin.sh`: recently migrated, shows `_scv_write` helper pattern for v2 results. Still hardcodes `state_dir/intake.md` (acceptable per current migration state).
- `core/pipeline/input-resolve.sh`: engine resolves input paths to `${state_dir}/stage-inputs/<stage>.json` — not yet consumed by most plugins.

## Conclusions

v2 contract requires 3 file changes:
1. manifest.yaml: add result_contract, events, router budgets, fix valid_verdicts
2. plugin.sh: write v2 result on every exit, fix rc=2→1, add cleanup function, update findings.json schema
3. test file: update assertions for v2 fields, add new tests for fatal/cleanup paths, add golden diff

## Next steps if budget runs out

- Test file first (TDD), then manifest, then plugin.sh
- The findings.json shape changes: top-level gets result_contract/verdict/disposition/reason; plugin-specific data moves under `data:{}`
- Cleanup function: `security_lens_cleanup() { return 0; }` with ADR-056 comment
- Exit code change: both `return 2` become `return 1` after writing v2 result to artifact dir
