# Impact checkpoint — FINAL

## What this change does
Move `_acceptance_timeout_prefix` from `acceptance-block.sh` to new `scripts/lib/timeout-cmd.sh`.
Convert 6 inline gtimeout probes to use the shared helper. Add bare-timeout lint wired into npm run lint.

## Symbols checked
- `_acceptance_timeout_prefix`: referenced in acceptance-negctl.sh (in scope), acceptance-reachability.sh (in scope), summary.sh (in scope), acceptance-negctl-test.sh (in scope). No out-of-scope production callers.
- `_ACCEPTANCE_TOUT`: only in files already in scope.
- `_ACCEPTANCE_TIMEOUT_KILL_OK`: used in acceptance-negctl-signal-test.sh as env override — behavior unchanged after move (bash global, same variable name). NOT a gap.

## Contract lib seam analysis
- `acceptance-block.sh` comment (lines 13-15) says sourcing a sibling joins `_runner_contract_lib_closure` and widens ADR-057 gate 2. The design overrides this deliberately.
- `core/pipeline/runner.sh` `_runner_contract_lib_closure` auto-discovers via source-line regex. No manual list change needed.
- `tests/unit/runner-contract-lib-seam-test.sh` doesn't pin exact closure set — won't break. NOT a gap.
- `docs/adr/ADR-057` doesn't need amendment (widening is a side effect, not a structural override of the ADR).

## Inline probes outside scope
Test files (tests/unit/acceptance-gate-stdin-test.sh, tests/unit/monitor-v2-result-test.sh, tests/unit/env-scrub-test.sh, tests/integration/runner-release-exit-paths-test.sh) have inline `command -v gtimeout` probes. They are in `tests/` which the new lint doesn't scan, and SPEC-8 only checks the 5 production files. These are out of scope BY DESIGN.

## Verdict
complete — missing=[]
