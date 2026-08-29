# Plan checkpoint — issue #1836 (migrate test plugin to contract v2)

## Files read and what they told me

- `plugins/tool/test/manifest.yaml` — v1 manifest; no `result_contract`; has `valid_verdicts`, `provides.role`, `provides.events` already declared; `primary: true` output already declared; `inputs: []`; hooks `run: test_run` and `cleanup: test_cleanup`. NO router budgets declared.
- `plugins/tool/test/plugin.sh` — 914+ lines; `_test_write_result` writes `schema_version: 1` at baseline; `_test_disposition_from_rc` function added for signal mapping; `result_contract: 2`, `disposition`, `reason`, `data` fields in updated version. Setsid-wrapped spawn mentioned for #1748.
- `plugins/tool/test/tests/test-test.sh` — 674 lines; SPEC-1..10 tests for v2 contract already added. SPEC-1..8 tagged as CHANGE assertions (fail at baseline). SPEC-9..10 tagged as GUARD assertions.
- `config/templates/deployed.yaml` — test stage already in flow under build_test_cycle.
- `plugins/tool/test/manifest.yaml` line 32 — `result_contract: 2` confirmed present.

## Conclusions

1. Manifest: `result_contract: 2` added under provides. primary, valid_verdicts, provides.role/events already present. T0 plugin — no router budget needed.
2. plugin.sh: `_test_write_result` updated to v2; `_test_disposition_from_rc` added (rc>=128+signal → interrupted, else broken); setsid-wrapped spawn for #1748 (process group isolation).
3. test-test.sh: SPEC-1..10 covering result_contract, disposition on pass/fail/error, reason on error, data block fields, signal→interrupted mapping, no-path-construction grep, valid_verdicts manifest guard.
4. Release hook test (kill mid-run, staging still on disk) may be in a separate test run or not fully integrated.
5. Plan is complete — emit JSON.

## What to do next

Emit the final plan JSON.
