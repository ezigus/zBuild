# Spec Correspondence Checkpoint

## Files read
- Assertions read inline from the prompt (no external files needed).
- Prior checkpoint noted SPEC-1 and SPEC-6 as PARTIAL due to stdout-only check — CORRECTED.
  Re-reading the prompt assertions directly: SPEC-1 uses `_s1_stdout` AND `_s1_stderr`; SPEC-6 uses `_s6_stdout` AND `_s6_stderr`. Both stdout and stderr are checked. Corrected to CORRESPONDS.
- Prior checkpoint noted SPEC-7 structural checks as absent — CORRECTED.
  The awk for "Host-wide run cap..." scopes to `## Decision` block (structural). The bullet check uses `grep -q "^[-*]"` scoped to `## Enforced by` (structural). SPEC-1 through SPEC-6 tags verified in Enforced-by section. Gap: "dated" (date stamp not verified) and "§7" (section number not verified).

## Conclusions per SPEC

### SPEC-1
- Returns 0: checked ✓
- No slot file: checked ✓
- No cap-related output: stdout checked ✓ AND stderr checked ✓
- → CORRESPONDS

### SPEC-2: CORRESPONDS
### SPEC-3: CORRESPONDS
### SPEC-4: CORRESPONDS
### SPEC-5: CORRESPONDS
### SPEC-6: CORRESPONDS

### SPEC-7
- File exists ✓
- Title text under Decision block: awk-scoped structural check ✓
- BUT "dated": no date stamp verified ✗
- BUT "§7": section number not verified ✗
- Enforced-by bullet naming run-cap-test.sh: structural bullet check ✓
- SPEC-1 through SPEC-6 tags in Enforced-by: checked ✓
- pipeline.refused.run_cap in event-schema.json: checked ✓
- → PARTIAL

## Acceptance-gate finding
Nothing to do for this stage — spec-assertion correspondence only; wiring identification is outside scope.
