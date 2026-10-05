# Plan Checkpoint — Issue #2035

## Files read and what they told me

- `tests/unit/adr-migration-claims-test.sh`:
  - SPEC-2 (line 56) loops only over `plan security-lens monitor`, checking `plugin.sh` only for `_llm_envelope_(parse|classify)` — missing review-lens and review-report.
  - SPEC-3 (line 74) greps `review-lens/plugin.sh` for `extract_first_json_object` with no comment exclusion — the only match IS a comment at line 394, so the test incorrectly takes the "not migrated" branch.
  - Header comment (lines 2-17) still describes review-lens as the unmigrated counter-example.

- `plugins/agent/review-lens/plugin.sh` (line 394-398):
  - Line 394 is a comment mentioning `extract_first_json_object` (explaining why it was replaced).
  - Line 398 shows `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok` — the plugin IS migrated.

- `plugins/agent/review-report/lib/lenses.sh` (line 162):
  - `_llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok` — also migrated.

- `docs/adr/ADR-028-shared-llm-agent-framework.md`:
  - Line 187: Migration section only lists `plan`, `security-lens`, `monitor` as migrated.
  - Line 189: States review-lens and review-report are "not migrated" — FALSE.
  - Line 193: States "review-lens was not migrated" — FALSE.
  - Lines 181-185: Per-stage gates list doesn't include `_review_lens_envelope_schema_ok` or `_rr_lens_envelope_schema_ok`.

## Plan (two steps)

### Step 1: Fix the test (RED → GREEN)
File: `tests/unit/adr-migration-claims-test.sh`
- Update header comment to reflect review-lens as migrated (not unmigrated counter-example)
- Fix SPEC-2: expand loop to include `review-lens review-report`; search all non-test `.sh` files in plugin dir (not just plugin.sh) to catch review-report's parser in lib/lenses.sh
- Fix SPEC-3: exclude comment lines from the extract_first_json_object grep

### Step 2: Update ADR-028
File: `docs/adr/ADR-028-shared-llm-agent-framework.md`
- Line 187: Add review-lens and review-report to the migrated stages list with note citing #1840/#1843
- Line 189: Replace "not migrated" paragraph with "migrated" statement
- Line 193: Remove "review-lens was not migrated" claim
- Lines 181-185: Add review-lens and review-report gates to Per-stage gates list

## Next if stopped now
Emit the plan JSON.
