# test-author notes — fifth pass

## What the grader found (round 2 of 2)

SPEC-4's assertion in event-schema-emitted-coverage-test.sh was incomplete:
it checked only that plugin.result is absent from the two manifests, but did NOT
verify that the pre-existing tests which asserted plugin.result was present have
been updated to remove that sub-assertion.

## Changes made this pass

### 1. tests/unit/event-schema-emitted-coverage-test.sh — SPEC-4 extended

Added two assertions to the SPEC-4 block (after the manifest checks) that verify
the pre-existing test files no longer contain the old plugin.result sub-assertions:

- `grep -qF "manifest provides.events contains plugin.result" security-lens-test.sh`
  → must NOT find it (assert_pass if absent, assert_fail if present)
- `grep -qF "manifest provides.events includes plugin.result" merge-v2-result-test.sh`
  → must NOT find it (assert_pass if absent, assert_fail if present)

These assertions:
- Pass after the change (both files have already had those sub-assertions removed)
- Would have failed before (both files previously had those sub-assertions)
- SPEC-4 is [no-code] so "must pass after, need not fail before" — requirement met

### Security-lens-test.sh and merge-v2-result-test.sh

These were already fixed in round 1 (prior pass):
- security-lens-test.sh [SPEC-16]: plugin.result sub-assertion removed ✓
- merge-v2-result-test.sh [SPEC-1]: plugin.result sub-assertion removed ✓

## Per-SPEC final status

- SPEC-1: correct — derives plugin namespaces dynamically via %.* ✓
- SPEC-2: correct — ADR-001 exception for plugin.<name>.* events ✓
- SPEC-3: correct — four checks: persist/hydrate absent from schema, canonical in manifests ✓
- SPEC-4: EXTENDED — manifest checks + test file checks (new in this pass) ✓
- SPEC-5: correct — three checks in lint-adr-enforced-by-test.sh ✓
- SPEC-6: correct — _PLUGIN_NS_RE absent via split-concatenation self-check ✓

## Foreign tags updated (already done in round 1)

- security-lens-test.sh [SPEC-16]: plugin.result sub-assertion removed ✓
- merge-v2-result-test.sh [SPEC-1]: plugin.result sub-assertion removed ✓
