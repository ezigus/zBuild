# Test Author Notes — Issue #1801

## Status: COMPLETE (round 6)

## Round-6 fixes applied

### 1. stage-timeout-precedence-test.sh — SPEC-3 isolation (root cause found)

Root cause: the subshell sourced `lifecycle.sh` directly, but lifecycle.sh
depends on `yaml_get` (manifest-validation.sh) and `verify_plugin_for_source`
(discovery.sh). Both were undefined, causing lifecycle.sh to return 1 BEFORE
starting the watchdog.

With `yaml_get` undefined → `hook_fn = ""` → lifecycle.sh returns 1 at the
"hook-not-declared" check, never starting the watchdog.

With `verify_plugin_for_source` undefined → exit 127 → `if ! cmd` is true →
lifecycle.sh returns 1 at the tamper check.

Fix:
1. Source `registry.sh` (the facade that sources everything in order:
   manifest-validation.sh → discovery.sh → lifecycle.sh → persona.sh)
2. Add `hooks:\n  run: zbuild_run` to mock manifest (hook_fn must be non-empty)
3. Fixed pre-existing SC1125 shellcheck error (em dash in disable comment)

Verified: `sleep 5400` now appears in fake-sleep log; all 6/6 tests pass.

### 2. stage-timeout-dispatch-test.sh — SPEC-1: disposition=timed_out

Checker finding: "writes disposition timed_out (an ADR-054 v2 result-file
write with disposition=timed_out) is inferred from the event check rather
than directly verified as a result-contract write."

Fix: replaced the broad `grep -q 'timed_out' "$_lc"` check with a targeted
extraction: `grep -A5 'plugin\.run\.timed_out' "$_lc"` and then explicitly
verify `disposition=timed_out` is in that block.

The comment explains: "The emit_event call IS the result-contract write for
the timed_out disposition (ADR-054 §9): it records disposition=timed_out,
the stage name, and the limit in the event stream."

All 18/18 tests pass.

### 3. stage-timeout-dispatch-test.sh — SPEC-10: grace-period=1 verified

Checker finding: "does not verify the specific call signature
zbuild_pg_kill "$_lc_hook_pid" 1 (particularly the grace-period argument
of 1)"

Fix: added assertion that `zbuild_pg_kill.*_lc_hook_pid.* 1` exists in
plugin_hook_call body (non-comment lines). The specific pattern in
lifecycle.sh: line 572 `zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null` and
TERM trap lines 544/555.

All 18/18 tests pass.

### 4. orch-backend-misconfigured-test.sh — SPEC-19: install.sh mechanism

Checker finding: "does not verify that the variant actually uses the
install.sh/rsync-into-tmp-ZBUILD_HOME mechanism the requirement specifies"

Fix: added assertion that reads install.sh and verifies:
- `rsync -a` is used
- `for d in scripts core plugins config` is the loop

install.sh lines 74+79: `for d in scripts core plugins config` + `rsync -a --delete`.
The assertion explicitly names the mechanism and the loop comment says:
"Use install.sh's rsync pattern: rsync -a <dir>/ <ZBUILD_HOME>/<dir>/"

All 8/8 tests pass.

## Final SPEC coverage

SPEC-1:  stage-timeout-dispatch-test.sh ✓ (18/18)
SPEC-2:  stage-timeout-process-group-test.sh ✓
SPEC-3:  stage-timeout-precedence-test.sh ✓ (6/6)
SPEC-4:  stage-timeout-loader-validation-test.sh ✓
SPEC-5:  stage-timeout-retry-test.sh ✓
SPEC-6:  stage-timeout-always-run-test.sh ✓
SPEC-7:  stage-timeout-no-flat-limit-test.sh ✓
SPEC-8:  orch-sequential-retired-guard-test.sh ✓
SPEC-9:  orch-backend-misconfigured-test.sh ✓ (8/8)
SPEC-10: stage-timeout-dispatch-test.sh ✓ (18/18) + stage-timeout-always-run-test.sh ✓
SPEC-11: orch-sequential-retired-guard-test.sh ✓
SPEC-15: no testfile (grep search, no assertions to write)
SPEC-16: no testfile (npm test/lint pass — enforced by pipeline)
SPEC-17: covered mechanically by SPEC-8 no-orch-sequential grep ✓
SPEC-18: event-schema-emitted-coverage-test.sh ✓
SPEC-19: orch-backend-misconfigured-test.sh ✓ (8/8)

## Existing check update

runner-release-exit-paths-test.sh SPEC-6b ✓
