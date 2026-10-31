# test-author notes

---

## Round 9 — SPEC-8 explicit exclusion assertions (current run)

### Checker findings addressed

**SPEC-5 checker finding** ("fixture has no shebang, placing atomic_write on line 3"):
The current file at lines 95-101 clearly shows `#!/usr/bin/env bash` as line 1 of the
fixture heredoc, placing the atomic_write call on fixture line 4. The assertion
`grep -qF "${_spec5_fixture_base}:4"` is correct. This feedback is from before the
round-5 shebang fix. No change needed.

**SPEC-8 checker finding** ("does not establish that core/state/resume.sh and
core/output/stage-io.sh are excluded from the || true requirement"):
Added two explicit assertions to `tests/unit/plugin-primary-output-atomic-test.sh`
after the own-checks.sh block:
- Asserts `grep -q '| atomic_write' core/state/resume.sh` passes (file has calls)
- Asserts `grep -q '| atomic_write' core/output/stage-io.sh` passes (file has calls)
Both assertions carry the `[#1754/SPEC-8]` tag and say "excluded from || true
requirement (has | atomic_write — uses PIPESTATUS)". If either file's calls were
removed, the exclusion in the while-loop would be dead code and the assertion fails —
this proves the exclusion is non-vacuous and explicitly establishes it in the test.

### Findings answered

- test finding 1 (SPEC-4 returns 0): nothing to do — implementation bug, test is correct
- test finding 2 (lint-disposition-words): nothing to do — implementation regression, out of scope
- test finding 3 (SPEC-8 violations): done — the prior round added exclusions; this round adds the explicit assertions
- test finding 4 (stage-signal [G5]): nothing to do — unrelated to #1754
- acceptance-gate finding 1 (SPEC-1/SPEC-2 already pass): nothing to do — before-check timed out; old code cannot produce outcome=broken from PIPESTATUS[1] failure
- acceptance-gate finding 2 (SPEC-4 not passing): nothing to do — implementation bug
- acceptance-gate finding 3 (SPEC-5/6/7 timeout): nothing to do — pipeline problem
- acceptance-gate finding 4 (file revert timeout): nothing to do — pipeline problem

---

## Round 8 — SPEC-8 named-site checks (prior run)

### Changes made

**`tests/unit/plugin-primary-output-atomic-test.sh`** — SPEC-8 section, after the
`_s8_violations` assertion:

Added two new per-file assertion blocks that check the specifically named sites from the SPEC:

1. **secrets.sh check**: counts `| atomic_write` lines in
   `plugins/agent/build/lib/secrets.sh` that also carry `|| true`. Asserts `>= 1`.
   Fails before the implementation (line 172 is bare); passes after (`|| true` added).

2. **own-checks.sh check**: counts `| atomic_write` lines in
   `plugins/tool/test/lib/own-checks.sh` that also carry `|| true`. Asserts `>= 3`.
   Fails before the implementation (lines 72, 96, 101 are bare); passes after.

### Why this is needed

The `>= 17` count proves the calls weren't wholesale removed. But if some original
calls were removed while new annotated ones were added elsewhere, the count would still
pass. The named-file checks close that gap: removing a call from secrets.sh or
own-checks.sh directly fails those assertions regardless of total count.

### Findings disposition (round 2 of 2 checker)

- **SPEC-5 checker finding**: "fixture has no shebang, placing atomic_write on line 3".
  The current file clearly has `#!/usr/bin/env bash` on line 95 (fixture line 1),
  making atomic_write on fixture line 4. The `:4` check is correct. The checker
  appears to have been running on a pre-round-5 snapshot. No change made to SPEC-5.

- **SPEC-8 checker finding**: "assertion establishes only part of the requirement".
  FIXED by adding per-file checks for the named sites (secrets.sh, own-checks.sh).

### Earlier findings (carried forward)

- test finding 1 (SPEC-4 returns 0): implementation bug, test is correct.
- test finding 2 (lint-disposition-words): implementation regression, not test issue.
- test finding 3 (SPEC-8 violations): implementation not done yet (expected test-first).
- test finding 4 (stage-signal [G5]): unrelated to #1754.
- acceptance-gate findings 1-4: pipeline timeouts or implementation issues; tests correct.

---

## Round 7 — SPEC-8 exclusion and count fix (prior run)

### Changes made

**`tests/unit/plugin-primary-output-atomic-test.sh`** — SPEC-8 section:

1. Added two new exclusion lines in the `while` loop, after the existing
   `*/lint-atomic-write-unchecked.sh` exclusion:
   ```bash
   # Exclude files already handled with proper PIPESTATUS checking (not || true)
   [[ "$_s8_f" == */core/state/resume.sh ]] && continue
   [[ "$_s8_f" == */core/output/stage-io.sh ]] && continue
   ```
   SPEC-8 text says "the SPEC-8 test excludes core/state/resume.sh and
   core/output/stage-io.sh (already handled)". Those files use PIPESTATUS
   checking, not `|| true`; they were falsely appearing in `_s8_violations`.

2. Changed count threshold from `>= 13` to `>= 17` (and updated the comment
   and error message). SPEC-8 text says "counts >= 17 annotated calls
   (13 original sites in 9 files plus secrets.sh:172 and own-checks.sh:72,96,101)".
   The `>= 13` threshold was too low — it allowed original calls to be removed
   while new ones were added to reach 13.

### SPEC-8 after fix

After excluding resume.sh and stage-io.sh (2 calls), the remaining
`| atomic_write` calls are exactly the 17 needing `|| true`:
- 13 original sites (various files)
- secrets.sh:172 (1 site)
- own-checks.sh:72, 96, 101 (3 sites)

The test still fails on unimplemented code because secrets.sh:172 and
own-checks.sh:72,96,101 are still missing `|| true` (implementation work).
It will pass once the implementation annotates all 17 sites.

### Findings disposition

- **test finding 1** (SPEC-4 fails): Test is correct — it fails because
  implementation of the intake.md write-check is broken, not the test.
  Test-first behavior.

- **test finding 2** (lint-disposition-words plugin.sh:1209): Implementation
  regression in plugins/tool/test/plugin.sh. Not a test issue; another stage
  must fix the plugin.

- **test finding 3** (SPEC-8 missing || true): Partly test, partly impl.
  The exclusion bug (resume.sh, stage-io.sh falsely flagged) is fixed here.
  The remaining violations (secrets.sh, own-checks.sh) are implementation work.

- **test finding 4** (stage-signal [G5]): Unrelated to #1754. Not my tag.

- **acceptance-gate finding 1** (SPEC-1/SPEC-2 already pass on old code):
  The before-check timed out (finding 3 confirms). My analysis of the old code
  logic: on old code, `_jq_rc` captures only PIPESTATUS[0]; atomic_write failure
  is ignored; `stage_result_add` writes `outcome=pass`; assertion
  `outcome=broken` gets "pass" → FAILS. The test correctly fails on old code.
  issue-acceptance finding 4 independently agrees ("my reading of the old code
  logic supports the REQUIREMENTS assessment"). Nothing to change.

- **acceptance-gate finding 2** (SPEC-4 doesn't pass on new code):
  Test is correct. Implementation bug as confirmed by issue-acceptance finding 1.

- **acceptance-gate findings 3 and 4** (timeouts): Pipeline issues, not test issues.

- **test-author finding 1** (SPEC-8 count >= 13 insufficient): Fixed by
  raising to >= 17.

---

## Round 6 — verdict judgement (prior run)

### SPEC-1
→ CORRESPONDS

### SPEC-2
→ CORRESPONDS (fixed in round 5: "broken" not "error")

### SPEC-3
→ CORRESPONDS

### SPEC-4
→ CORRESPONDS (test is correct; failure is an implementation bug)

### SPEC-5
→ CORRESPONDS (fixed in round 5: exact line 4)

### SPEC-6
→ CORRESPONDS

### SPEC-7
→ CORRESPONDS

### SPEC-8
→ PARTIAL (needs exclusions for resume.sh and stage-io.sh; count needs >= 17)
   → FIXED in round 7

---

## Round 5 — three targeted fixes (prior run)

- SPEC-2: changed expected "error" → "broken"
- SPEC-5: changed `:[0-9]+` → `:4` (exact line)
- SPEC-8: changed `-gt 0` → `-ge 13`

---

## Round 4 and earlier — see original notes above
