# spec-correspondence checkpoint

## Files read
- design.md: confirms goal is to fix ADR-028 stale "not migrated" claims for review-lens/review-report, fix the comment-grep bug in adr-migration-claims-test.sh, and expand SPEC-2 loop. Two files changed: test file and ADR. SPEC-4 and SPEC-5 are [no-code]; SPEC-1 and SPEC-6 are [code].

## Conclusions per SPEC (final judgements)

SPEC-1: corresponds — assertion greps ADR for the `(review-lens|review-report).*\*\*not\*\*.*migrat` pattern, uses [#2035/SPEC-1] tag, fails when pattern found (current ADR), passes when absent (after replacement). Directly establishes the requirement.

SPEC-4: partial — assertion verifies that `^[^#]*extract_first_json_object` finds no non-comment occurrences in plugin.sh (the effect clause of the requirement), but does not verify that adr-migration-claims-test.sh's SPEC-3 grep was actually updated to use this pattern (the structural clause: "uses the pattern").

SPEC-5: partial — assertion uses `_llm_envelope_(parse|classify)` while the requirement specifies `_llm_envelope_parse`; a directory with only `_llm_envelope_classify` would pass the assertion but fail the SPEC-2 loop as described.

SPEC-6: partial — assertion greps the entire ADR file for both names (file-wide), but the requirement says "in its migration record" (location-specific); passing could occur if the names appeared in a non-migration section of the file.

## Status: complete, all 4 verdicts reached.
