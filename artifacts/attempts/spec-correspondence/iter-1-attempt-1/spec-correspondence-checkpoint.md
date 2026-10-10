# Spec Correspondence Checkpoint

## Files read
- design.md: 7 SPECs defined, covering R-1 through R-8. Scope: run-cap.sh, runner.sh, ADR-059, event-schema.json, tests/unit/run-cap-test.sh.

## Key observation about test framework
SPEC-4 and SPEC-5 use explicit `_s4_stderr_file` / `_s5_stderr_file` variables to capture stderr separately (they *expect* stderr content). SPEC-1 and SPEC-6 only check `_s1_out` / `_s6_out` with no equivalent stderr capture — suggesting `_out` is stdout only, not combined stdout+stderr. This means "no cap-related output" is only partially verified (stdout only, not stderr).

## Conclusions per SPEC

### SPEC-1
- Returns 0: checked ✓
- No slot file: checked ✓ (counts files in ZBUILD_STATE_ROOT)
- No cap-related output: only stdout checked (`_s1_out`), stderr NOT checked
- → PARTIAL

### SPEC-2
- Returns 1: checked ✓
- _ZBUILD_RUN_CAP_BLOCKERS names both run-s2-a and run-s2-b: checked ✓
- stderr refusal names both run-s2-a and run-s2-b: checked ✓
- → CORRESPONDS

### SPEC-3
- Stale slot reaped: admission returns 0 ✓ + no file containing run-s3-dead found ✓
- Control confirms live slots still block ✓
- → CORRESPONDS

### SPEC-4
- Returns 0: checked ✓
- Warning emitted to stderr: checked (non-empty stderr) ✓
- "regardless of cap value and live slot count": tested in one presumably-at-cap scenario — acceptable for "regardless" invariant
- → CORRESPONDS

### SPEC-5
- Returns 0: checked ✓
- Warning emitted to stderr: checked (non-empty stderr) ✓
- → CORRESPONDS

### SPEC-6
- Returns 0: checked ✓
- Slot file written for run-s6-new: checked ✓
- No cap-related output: same issue as SPEC-1 — `_s6_out` stdout only, stderr not checked
- → PARTIAL

### SPEC-7
Requirement: §7 "under Decision", Enforced-by bullet naming test file AND its six spec statements, event-schema entry.
Assertion checks:
- File exists ✓
- "Host-wide run cap, off unless configured" text present ✓ (but NOT verified to be "under Decision")
- "tests/unit/run-cap-test.sh" text present ✓ (but NOT verified to be in an Enforced-by bullet)
- "pipeline.refused.run_cap" in event-schema.json ✓
Missing: structural placement check, "six spec statements" named check
- → PARTIAL

## Final status: all 7 pairs analyzed, ready to emit verdicts
