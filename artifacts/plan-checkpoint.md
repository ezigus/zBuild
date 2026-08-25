# Plan checkpoint — issue #1836 (migrate test plugin to contract v2)

## Files read and what they told me

- `plugins/tool/test/manifest.yaml` — v1 manifest; no `result_contract`; has `valid_verdicts`, `provides.role`, `provides.events` already declared; `primary: true` output already declared; `inputs: []`; hooks `run: test_run` and `cleanup: test_cleanup`. NO router budgets declared.
- `plugins/tool/test/plugin.sh` — 914 lines; `_test_write_result` writes `schema_version: 1` without `result_contract`, `disposition`, or `reason` fields; the RETURN trap does kill the pg but calls `rm -rf` in `test_cleanup`(purge) not in RETURN trap; `test_cleanup` already implements `release` (kill pg, leave staging dir) and `purge` (delete staging dir). The old `rm -rf` in plugin.sh lines 208-210 reference was in ADR text but the RETURN trap only calls `_test_kill_staging_pg`, not rm-rf. staging dir removal is in `test_cleanup(purge)`. This is already the correct separation — release/purge hooks exist.
- `plugins/tool/test/tests/test-test.sh` — 613 lines; existing tests check schema_version:1, verdict, exit_code, diff_applied. No tests for v2 fields (result_contract, disposition, reason).
- `core/contract/version.sh` — defines v2 support; `_ZBUILD_CONTRACT_V2=2`.
- `core/pipeline/disposition.sh` — closed set: complete, interrupted, throttled, exhausted, unavailable, broken.
- `plugins/tool/hydrate/manifest.yaml` — migrated v2 example: `result_contract: 2` under `provides:`.
- `plugins/tool/hydrate/plugin.sh` — writes `{result_contract: 2, verdict: $v, disposition: "complete", reason: $r, data: {...}}`.
- `plugins/tool/teardown/manifest.yaml` — migrated v2 example with `result_contract: 2` under `provides:`.
- `config/templates/deployed.yaml` — test stage IS in `flow:` under `build_test_cycle`. Already wired.

## Conclusions

1. **Manifest changes needed**: add `result_contract: 2` under `provides:`. Router budgets: the test plugin is T0 (no LLM), so no router config needed. `primary: true` already declared. `valid_verdicts` already declared. `provides.role` and `provides.events` already declared. `inputs: []` already fine (no path construction). So manifest change = add `result_contract: 2`.

2. **plugin.sh changes needed**:
   - `_test_write_result`: change `schema_version: 1` → `result_contract: 2`; add mandatory `disposition` and `reason` fields; put plugin-specific data under `data:` namespace.
   - On every exit path, determine disposition: success/fail → `complete`; SIGTERM/interruption → `interrupted`; structural errors (missing patch, config bug) stay `verdict=error` with `disposition=broken` (config bug) or `disposition=interrupted` (SIGTERM). Issue #1747: SIGTERM'd test → `disposition: interrupted`. rc=0 with unrecognized output → `disposition: broken` (real config bug).
   - Remove any artifact path construction in code (there is none — plugin already uses `$output_json` from caller, never constructs a path from manifest).
   - Ensure `release` hook doesn't delete staging dir (already the case — RETURN trap only kills pg, test_cleanup release only kills pg, test_cleanup purge deletes).
   - The `RETURN trap` at line 212 in plugin.sh currently calls `_test_kill_staging_pg` which is correct. No change needed to RETURN trap structure.

3. **Test changes needed** (test-first): new tests for:
   - v2 result: `result_contract=2`, `disposition`, `reason` on each verdict path (pass→complete, fail→complete, error→broken).
   - SIGTERM path (#1747): `disposition=interrupted`, NOT `broken`.
   - Release hook: kill pg, staging tree still on disk.
   - No artifact path construction in plugin.sh (grep assertion).
   - `valid_verdicts` in manifest covers all emittable verdicts.

4. **Template**: test is already in `deployed.yaml` flow → no template change needed.

## What I'd do next

Write tests first (test-test.sh additions), then update plugin.sh (_test_write_result and disposition logic), then update manifest.yaml.
