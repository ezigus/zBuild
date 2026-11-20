# Test Author Notes — DSCLA tests (issue 1764)

## Status: COMPLETE (iteration 7 — fixed DSCLA-18 and DSCLA-20 assertions to distinguish add vs remove)

All test files are written and in place. All SPECs have assertions.

## Changes made in this run (iteration 7)

### Fixed DSCLA-18 and DSCLA-20 assertions

**File:** `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`

**Problem:** The gh mock writes each argument on its own line (`printf '%s\n' "$@"`). Both DSCLA-18 and DSCLA-20 were checking only for `zbuild:claimed` in the calls file, which would match whether `--add-label` or `--remove-label` was used.

**Fix for DSCLA-18:** Added check that `--add-label` is also present in the calls file:
```bash
grep -qF "zbuild:claimed" "$_dscla18_calls" && grep -qF -- "--add-label" "$_dscla18_calls"
```

**Fix for DSCLA-20:** Added check that `--remove-label` is also present in the calls file:
```bash
grep -qF "zbuild:claimed" "$_dscla20_calls" && grep -qF -- "--remove-label" "$_dscla20_calls"
```

**Why these still fail on base code:** Base code adds/removes `claimed:<machine>` not `zbuild:claimed`, so the first `grep -qF "zbuild:claimed"` already fails. The new `--add-label`/`--remove-label` check is an additional guard catching a future implementation that swaps add for remove or vice versa.

## Changes made in earlier runs (iteration 6)

### Added DSCLA-18, DSCLA-19, DSCLA-20, DSCLA-21

**File:** `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`

**DSCLA-18** — `claim_coordinator_claim` adds `zbuild:claimed` via `gh issue edit`
- Given: plugin.sh sourced (top of file); gh backend; no zbuild:claimed on issue
- When: `claim_coordinator_claim "2018"` is called
- Then:
  1. `grep -qF "zbuild:claimed"` in gh calls file → fails on base code (adds `claimed:test-machine-dscla18`)
  2. `! grep -qE "^claimed:[a-zA-Z0-9_-]"` → fails on base code (finds `claimed:test-machine-dscla18`)
- Base code red step: gh call file has `claimed:test-machine-dscla18` not `zbuild:claimed`

**DSCLA-20** — `claim_coordinator_release` removes `zbuild:claimed` via `gh issue edit`
- Given: plugin.sh sourced; gh backend; mock returns `zbuild:claimed` for view
- When: `claim_coordinator_release "2020"` is called
- Then:
  1. `grep -qF "zbuild:claimed"` in gh calls file → fails on base code (removes `claimed:test-machine-dscla20`)
  2. `! grep -qE "^claimed:[a-zA-Z0-9_-]"` → fails on base code
- Base code red step: gh call file has `claimed:test-machine-dscla20` not `zbuild:claimed`

**DSCLA-19** — `zbuild_claim_acquire` delegates to coordinator hook; no direct gh calls
- Given: `core/claim/claim.sh` must exist (fails on base code — file absent)
- When: `zbuild_claim_acquire "2019"` called with local-fs backend, gh mocked
- Then:
  1. `grep -Fxq "zbuild:claimed" labels.txt` → coordinator was called
  2. 0 gh calls → no direct gh in zbuild_claim_acquire
- Base code red step: `core/claim/claim.sh` absent → `assert_fail "[DSCLA-19] core/claim/claim.sh must exist"`

**DSCLA-21** — `zbuild_claim_release` delegates to coordinator hook; no direct gh calls
- Given: `core/claim/claim.sh` must exist (fails on base code — file absent)
  - Labels.txt pre-populated with `zbuild:claimed`; `_ZBUILD_CLAIM_ACQUIRED=1`; `_ZBUILD_CLAIM_ISSUE` set
- When: `zbuild_claim_release "2021"` called with local-fs backend, gh mocked
- Then:
  1. `! grep -Fxq "zbuild:claimed" labels.txt` → coordinator hook removed the label
  2. 0 gh calls → no direct gh in zbuild_claim_release
- Base code red step: `core/claim/claim.sh` absent → `assert_fail "[DSCLA-21] core/claim/claim.sh must exist"`

### Added DSCLA-22

**File:** `tests/integration/teardown-repeat-signal-test.sh`

**DSCLA-22** — stub claim coordinator in discovery tree; claim called before stage; release on exit
- Given: stub plugin created in `$PLUGINS_ROOT/claim-coordinator/stub/`
  - Stub's `stub_dscla22_claim` writes `dscla22-claim-called` marker and returns `{"acquired": true}`
  - Stub's `stub_dscla22_release` writes `dscla22-release-called` marker
  - Stage `outcome_run` writes `dscla22-stage-started` marker ONLY if claim marker already exists
    (this proves ordering: claim before stage)
- When: runner executed with `--issue 90001772`
- Then:
  1. `[[ -e "$_DSCLA22_CLAIM_CALLED" ]]` → stub's claim hook was called
  2. `[[ -e "$_DSCLA22_STAGE_STARTED" ]]` → claim marker existed when stage ran (ordering proved)
  3. `[[ -e "$_DSCLA22_RELEASE_CALLED" ]]` → stub's release hook called on exit
- Base code red step: runner.sh never calls `zbuild_claim_acquire` → `_DSCLA22_CLAIM_CALLED` never created → stage check sees no claim marker → all 3 assertions fail

## Full SPEC coverage

- DSCLA-1: unit test + teardown (claim present before first stage)
- DSCLA-2: unit test (rsc_render_header with holder, CI URL in holder)
- DSCLA-3: unit test + teardown (non-zero exit, no stage dispatched, event emitted)
- DSCLA-5: teardown (zbuild:claimed absent after normal completion)
- DSCLA-6: teardown (zbuild:claimed absent after failure)
- DSCLA-7: teardown (zbuild:claimed absent after TERM)
- DSCLA-8: unit test (zbuild_claim_acquire "" → 0, no gh calls)
- DSCLA-9: teardown (holder in output; fixture generated by rsc_render_header)
- DSCLA-10: unit test (Given check via eb_compose_known_types fails on base code)
- DSCLA-11: teardown ([done] requirement — passes on old and new code)
- DSCLA-12: unit test (CI URL in zbuild-holder comment)
- DSCLA-13: teardown (zbuild:claimed absent after second SIGTERM during abort trap)
- DSCLA-15: teardown (literal \n preserved in output)
- DSCLA-16: teardown (zbuild:claimed absent after _runner_enter_worktree failure)
- DSCLA-17: unit test (no gh calls when _ZBUILD_CLAIM_ACQUIRED not set)
- DSCLA-18: unit test (claim_coordinator_claim adds zbuild:claimed, no hostname)
- DSCLA-19: unit test (zbuild_claim_acquire delegates to coordinator, no direct gh)
- DSCLA-20: unit test (claim_coordinator_release removes zbuild:claimed, no hostname)
- DSCLA-21: unit test (zbuild_claim_release delegates to coordinator, no direct gh)
- DSCLA-22: teardown integration (stub in ZBUILD_PLUGINS_ROOT; claim before stage; release on exit)
- DSADR-7: lint-adr-enforced-by-test.sh (ADR-005 has Enforced by, not in baseline)

## Test files

- `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
  DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-8, DSCLA-10, DSCLA-12, DSCLA-17, DSCLA-18, DSCLA-19, DSCLA-20, DSCLA-21
- `tests/integration/teardown-repeat-signal-test.sh`
  DSCLA-1, DSCLA-3, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-9, DSCLA-11, DSCLA-13, DSCLA-15, DSCLA-16, DSCLA-22
- `tests/unit/lint-adr-enforced-by-test.sh`
  [#1764/DSADR-7]

## Key design notes

### DSCLA-19 and DSCLA-21
Both use the `if [[ ! -f core/claim/claim.sh ]]` guard as the base-code red step.
On new code, `plugin.sh` likely sources `core/claim/claim.sh` transitively (since
DSCLA-1's existing test calls `zbuild_claim_acquire` right after sourcing `plugin.sh`).

For DSCLA-19: local-fs backend means coordinator itself doesn't call gh; any gh call
would be direct from `zbuild_claim_acquire`. The side-effect check (labels.txt has
`zbuild:claimed`) proves the coordinator's hook ran. 0 gh calls proves no direct gh.

For DSCLA-21: pre-populate labels.txt, set `_ZBUILD_CLAIM_ACQUIRED=1` and
`_ZBUILD_CLAIM_ISSUE`, call `zbuild_claim_release`. Absence of `zbuild:claimed`
in labels.txt afterwards proves the coordinator's release hook ran.

### DSCLA-22
The stub manifest defines all 4 required hooks for `claim-coordinator` kind.
The stub returns `{"acquired": true}` from claim, so the runner proceeds to
dispatch the first stage. The stage's conditional-write pattern
(`if [[ -e claim_marker ]]; then write stage_marker`) proves ordering without
timestamps. The stub is added to `$PLUGINS_ROOT/claim-coordinator/stub/` and
removed in cleanup.
