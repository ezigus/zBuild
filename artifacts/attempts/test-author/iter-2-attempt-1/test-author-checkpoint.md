## Checkpoint — issue #2035 test-author (iteration 6) — COMPLETE

### Files written
- tests/unit/adr-migration-claims-test.sh — all 4 SPECs + finding fixes implemented and verified

### Changes made this iteration (vs prior checkpoint)
1. **SPEC-5 structural check** (new): self-referential grep verifying loop uses `-not -path '*/tests/*'` find flag.
2. **SPEC-5 absence check** (new): loop over review-lens/review-report non-test files asserting no bare `^[^#]*extract_first_json_object`. Addresses issue-acceptance finding 3 (R-3 gap).
3. **SPEC-4 structural check** (new): self-referential grep verifying SPEC-3 uses `'^[^#]*extract_first_json_object'` with `$_rl` variable. No self-reference issue: assertion on disk has `\"$_rl\"` (escaped) which doesn't match the search target `"$_rl"` (unescaped at SPEC-3 line).
4. **SPEC-6 narrowed to Amendment v1.2** (updated): awk extracts Amendment v1.2 section; grep checks function names within that section only. Addresses spec-correspondence finding 3.

### Test run results (all 12 pass on current codebase)
- All 12 assertions green
- shellcheck warnings at pre-existing lines 41, 147 are not from this iteration

### All SPECs done
