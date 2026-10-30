# test-author notes — correspondence-judging pass (third pass)

## What changed this pass

Both SPEC-1 and SPEC-2 had false positives caused by `plugins/tool/pr-open` declaring
`plugin.pr_open.branch_fallback_used` and `plugin.pr_open.preflight_remote_has_work`.
These are ADR-001 exception events — the pr-open plugin is allowed to own the
`plugin.pr_open.*` sub-namespace. The assertions incorrectly treated the top-level
`plugin` namespace as plugin-owned.

### SPEC-1 fix (lines ~183, ~199, ~210)

Root cause: `%%.*` (greedy strip) extracts only the first dot-delimited token.
`plugin.pr_open.branch_fallback_used` → `plugin`, which put `plugin` in the
plugin-owned namespace set, causing all 16 `plugin.*` engine-schema entries to
be flagged as violations.

Fix: change to `%.*` (shortest strip — removes only the last component).
`plugin.pr_open.branch_fallback_used` → `plugin.pr_open` (a distinct namespace).
The engine-type comparison likewise uses `%.*` so `plugin.run.start` → `plugin.run`,
which does NOT match `plugin.pr_open` → no false violation.

Verification of "fails before":
- persist plugin manifest provides `persist.start` → namespace `persist`
- event-schema.json has `persist.start` → namespace `persist`
- Match → violation → SPEC-1 fails before the code change ✓

Verification of "passes after":
- SPEC-3 removes `persist.*`/`hydrate.*` from event-schema.json
- `plugin.run.start` → namespace `plugin.run`; no manifest has `plugin.run.*` → no match
- `plugin.result` → namespace `plugin`; no manifest has `plugin.*` (only `plugin.pr_open`) → no match
- No violations → SPEC-1 passes ✓

### SPEC-2 fix (lines ~235–248)

Root cause: the engine-namespace regex `^plugin\.` matches `plugin.pr_open.*` events
from pr-open, producing false violations.

Fix: before the grep check, skip events matching `plugin.${plugin_basename_underscored}.*`
where the basename is derived from the plugin directory name (dashes → underscores).
For `plugins/tool/pr-open`, pattern = `plugin.pr_open.*` → events match → skipped.
For `plugins/agent/security-lens`, pattern = `plugin.security_lens.*` → `plugin.result`
does NOT match → still checked → violation.

Verification of "fails before":
- security-lens provides `plugin.result` → not `plugin.security_lens.*` → violation ✓
- merge provides `plugin.result` → not `plugin.merge.*` → violation ✓
- SPEC-2 fails before code change ✓

Verification of "passes after":
- SPEC-4 removes `plugin.result` from both manifests
- pr-open's `plugin.pr_open.*` events are excepted
- No other plugin declares engine-namespace events
- SPEC-2 passes ✓

## What I read

1. `tests/unit/event-schema-emitted-coverage-test.sh` — all 314 lines; the SPEC-1
   through SPEC-4 assertions are at lines 160–309.
2. `tests/unit/lint-adr-enforced-by-test.sh` — lines 140–181; SPEC-5 assertions
   at lines 152–176.

## Per-SPEC status

- SPEC-1: FIXED — all-but-last namespace extraction; false positives from pr-open eliminated
- SPEC-2: FIXED — ADR-001 `plugin.<plugin_name>.*` exception added
- SPEC-3: unchanged (correct)
- SPEC-4: unchanged (correct)
- SPEC-5: unchanged (correct, in lint-adr-enforced-by-test.sh)

## Out-of-scope issue

issue-acceptance finding 2 flagged pre-existing tests in:
- `plugins/agent/security-lens/tests/security-lens-test.sh [SPEC-16]`
- `tests/unit/merge-v2-result-test.sh [SPEC-1]`

Both assert `plugin.result` IS present in those manifests. After the implementation
removes `plugin.result` (SPEC-4), these pre-existing tests fail. These files are NOT in
my named testfiles scope; I cannot modify them. The issue-acceptance stage correctly
identified this as a scope gap — those tests need updating in a separate change.

## Final SPEC-correspondence verdicts (this pass)

I verified the file content at lines 160-314 (event-schema test) and 152-176 (lint-adr test)
matches the assertion code shown in the prompt exactly.

SPEC-1 — corresponds
  %.*  (shortest match) extracts all-but-last namespace component from plugin manifest events.
  plugin.pr_open.branch_fallback_used → plugin.pr_open; plugin.run.start → plugin.run.
  No false positives. persist.start → persist matches persist plugin → violation flagged.
  assert_fail → FAIL++ → exit non-zero. Directly establishes the requirement.

SPEC-2 — corresponds
  Engine-namespace regex checked after skipping plugin.<plugin_name>.* exception events.
  plugin.result in security-lens does NOT match plugin.security_lens.* → checked → violation.
  assert_fail → FAIL++ → exit non-zero. Directly establishes the requirement.

SPEC-3 — corresponds
  Four checks: absent from schema (persist.*), absent from schema (hydrate.*), present in
  persist manifest (canonical), present in hydrate manifest (canonical). All four required
  clauses are covered. assert_fail on any failure → non-zero exit.

SPEC-4 — corresponds
  grep -qxF "plugin.result" on each manifest; absent → assert_pass; present → assert_fail.
  Directly checks the two specific files named in the requirement.

SPEC-5 — corresponds
  Three checks: (1) ## Enforced by section exists, (2) section body names the test file
  (awk extracts within-section content to avoid false positives), (3) ADR-001 not in baseline.
  All three requirement clauses are independently verified. All three must pass for exit 0.
