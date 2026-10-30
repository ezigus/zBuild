# test-author notes — sixth pass (final)

## What the test stage found (inert_wiring finding)

The acceptance gate's REACHABILITY check reported:
  REACHABILITY FAIL inert_wiring tests/unit/event-schema-emitted-coverage-test.sh

The finding message: "tests/unit/event-schema-emitted-coverage-test.sh was put back to its
old version and every test still passed, so it is not what runs the new behaviour —
name the file whose code calls it, or write WIRING: none"

## Root cause analysis

The design declared:
  WIRING:
  tests/unit/event-schema-emitted-coverage-test.sh

The reachability check logic (_reachability_revert_one in acceptance-reachability.sh):
1. Creates a worktree at the merge-base
2. Overlays all changed files from HEAD, EXCEPT the WIRING target
3. Overlays ALL testfiles from HEAD (unconditionally)
4. Runs the testfiles and checks for a pass→fail flip

The TESTFILES section of design.md includes tests/unit/event-schema-emitted-coverage-test.sh
for SPEC-1, SPEC-2, SPEC-3, SPEC-4, and SPEC-6. Since this file is both the WIRING target
AND a testfile, step 3 unconditionally overlays it from HEAD — overwriting the reverted
merge-base version. The test always runs at HEAD. Both "reverted" and "head" runs show
all 16 assertions passing. No flip → inert_wiring.

This is confirmed by the reachability log: every "reverted" run output shows
[#1951/SPEC-1] and [#1951/SPEC-2] PASSING, because the testfile-overlay step
restored the HEAD version of the file before running it.

## Fix applied this pass

Updated /home/runner/work/_temp/zbuild-state/artifacts/design.md via Python:
  Changed WIRING block from:
    WIRING:
    tests/unit/event-schema-emitted-coverage-test.sh
  To:
    WIRING: none

This is correct because:
- event-schema-emitted-coverage-test.sh is BOTH the implementation of the new check
  AND the testfile for SPEC-1/SPEC-2. As a testfile it can never be a load-bearing
  WIRING target (it always gets HEAD via testfile-overlay).
- NEGCTL already correctly checks SPEC-1/SPEC-2: NEGCTL PASS SPEC-1 and NEGCTL PASS
  SPEC-2 confirm the assertions DO fail on old code (config files at merge-base).
- Part 2 of the reachability check already passes for all 4 changed production files:
    REACHABILITY PASS change config/adr-enforcement-baseline.txt
    REACHABILITY PASS change config/event-schema.json
    REACHABILITY PASS change plugins/agent/security-lens/manifest.yaml
    REACHABILITY PASS change plugins/tool/merge/manifest.yaml
- tests/unit/event-schema-emitted-coverage-test.sh is a test path; _acceptance_is_production_path
  returns false for it, so it is skipped in Part 2 anyway.
- With WIRING: none, the acceptance check prints REACHABILITY EXEMPT none (Part 1 passes)
  and Part 2 continues to check the 4 production files (all pass).

## Per-SPEC final status (all testfiles unchanged from prior passes)

- SPEC-1: correct in event-schema-emitted-coverage-test.sh — derives plugin namespaces
  dynamically via %.* pattern from manifests ✓
- SPEC-2: correct in event-schema-emitted-coverage-test.sh — ADR-001 exception for
  plugin.<name>.* events ✓
- SPEC-3: correct in event-schema-emitted-coverage-test.sh — four checks: persist/hydrate
  absent from schema, canonical in manifests ✓
- SPEC-4: complete in event-schema-emitted-coverage-test.sh — manifest checks + test file
  checks (verified sub-assertions removed from security-lens-test.sh and merge-v2-result-test.sh) ✓
- SPEC-5: correct in lint-adr-enforced-by-test.sh — three checks ✓
- SPEC-6: correct in event-schema-emitted-coverage-test.sh — _PLUGIN_NS_RE absent via
  split-concatenation self-check ✓

## Foreign tags updated (done in earlier passes)

- security-lens-test.sh [SPEC-16]: plugin.result sub-assertion removed ✓
- merge-v2-result-test.sh [SPEC-1]: plugin.result sub-assertion removed ✓
