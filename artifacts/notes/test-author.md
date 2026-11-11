# test-author notes — issue #1805 (round 58)

## Status: ALL TESTS PASSING

All test files pass. The only remaining issue was `tests/unit/status-row-findings-test.sh`
which had a W8 fixture with empty backtick labels `\`\`` instead of `\`CMBR-1\`` and `\`FRSH-2\``.

## Round 58 — Fixed status-row-findings-test.sh W8 fixture

### Root cause
The W8 fixture in `status-row-findings-test.sh` (lines 104-107) used empty
backtick labels `\`\`` for the two test finding texts. The extraction regex
`[A-Z][A-Z0-9]{2,5}-[0-9]+` requires an actual SPEC ID to be present. With empty
labels, no ID was matched and the output was "what failed: 2 findings" instead of
"what failed: `CMBR-1`, `FRSH-2`".

### Fix
Changed the two finding texts to use backtick labels with the SPEC IDs directly:
- `'tests/integration/resume-loop-state-test.sh fails: ✗ \`CMBR-1\` no stage.start for build in iter 2 — expected: 0, got: 1'`
- `'tests/integration/resume-rehydrate-test.sh fails: ✗ \`FRSH-2\` fresh run cycle member emits exactly one stage.start — expected: 1, got: 0'`

The extraction regex in `run-status-text.sh` applies `(?<![A-Za-z0-9-])[A-Z][A-Z0-9]{2,5}-[0-9]+(?![0-9])`
to each finding's first line. With the backtick labels `\`CMBR-1\`` and `\`FRSH-2\``,
the backtick character before the ID is a non-alphanum character, so the lookbehind
passes and `CMBR-1`/`FRSH-2` are correctly extracted.

## All SPECs coverage

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓, DSSKIP-1 ✓, DSFRSH-2 ✓, DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓, DSFSTG-2 ✓, DSFSTG-3 ✓, DSFSTG-4 ✓, DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓, DSCMBR-1 ✓, DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓

### tests/unit/status-row-findings-test.sh
- All 19 tests pass (W8 fixture fixed in this round)

## Findings answered

### acceptance-gate finding 1: DSFSTG-4 passes on before-code
DSFSTG-4 is classified `[done]` in the design — its test must pass on before-code
(the code from before this change already implements the guard). The acceptance gate
finding is not applicable to `[done]` requirements.

### test-related findings
All previous findings resolved in prior rounds.

## Open findings

None outstanding.
