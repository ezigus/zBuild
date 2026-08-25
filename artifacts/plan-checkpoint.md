# Plan checkpoint for issue #1833 — build plugin v2 migration

## Files read and what they told me

- `plugins/agent/build/manifest.yaml`: manifest already has valid_verdicts, primary:true, provides.role/events, name-matched inputs (no from:/path), cleanup hook present (no-op). MISSING: result_contract:2 in provides, router: budget section in config.

- `plugins/agent/build/plugin.sh`: 
  - Line 78: hardcoded `scope_manifest="$state_dir/scope-manifest.md"` (the load-bearing path #1825 cites)
  - Line 79: hardcoded `plan_json_path="$artifacts_dir/plan.json"`
  - Line 72-73: missing state_file → return 2 (no result written, but no output path known)
  - Line 110-114: missing plan.json → return 2 with no v2 result
  - Line 291-303: SIGINT → return 130 with no v2 result

- `plugins/agent/build/lib/summary.sh`:
  - jq at line 233: result_contract:2 is CONDITIONAL on build_disposition != ""
  - scope_violation path: sets verdict but NOT build_disposition/build_reason → no v2 fields!
  - normal pass with files changed: also no build_disposition set → no v2 fields!
  - Need: always emit result_contract:2, disposition, reason on every path

- `plugins/agent/build/tests/build-test.sh`: test infrastructure is in place (mock route_to_model_loop, fixtures). Tests call _build_stage_run_inner with explicit paths (not build_stage_run), so test isolation is preserved.

- `plugins/agent/plan/manifest.yaml` router section: uses `router: {retries: 1, retry_on_exhaustion: 1}` shape.

## Conclusions reached

1. Manifest needs `result_contract: 2` in `provides` and a `router:` budget section (retries + retry_on_exhaustion).
2. summary.sh must be fixed so ALL branches set build_disposition/build_reason before jq, then move result_contract:2 into the unconditional main object.
3. plugin.sh build_stage_run must read scope_manifest and plan paths from ZBUILD_STAGE_INPUTS with fallback to current paths for test-harness compat.
4. plugin.sh SIGINT path must write a v2 result then return 1 (not 130).
5. plugin.sh missing plan.json path must write a v2 result then return 1.
6. Tests go FIRST per CLAUDE.md test-first rule.

## What I'd do next if stopped

Emit the plan JSON. All exploration is done.
