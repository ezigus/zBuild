# spec-correspondence checkpoint

## Files read
- design.md: confirms goal is to fix ADR-028 stale "not migrated" claims for review-lens/review-report, fix the comment-grep bug in adr-migration-claims-test.sh, and expand SPEC-2 loop. Two files changed: test file and ADR.

## Conclusions per SPEC (final)

SPEC-1: corresponds — grep for stale `**not** migrated` pattern near plugin names in ADR-028; passing means the stale claim is absent.

SPEC-2: corresponds — grep for `_llm_envelope_parse[^|]*--schema-gate` in review-lens/plugin.sh; passing directly establishes the requirement. The "passes before and after" language is temporal/contextual justification, not a separate behavioral property the assertion must verify.

SPEC-3: corresponds — same reasoning; grep for same pattern in review-report/lib/lenses.sh directly establishes the requirement.

SPEC-4: corresponds — assertion runs both `#.*extract_first_json_object` and `^[^#]*extract_first_json_object` on plugin.sh, passes only when comment exists but non-comment does not; this IS using the comment-excluding grep and verifying it returns no matches, directly establishing that plugin.sh:394 comment does not trigger the wrong branch.

SPEC-5: corresponds — grep checks specifically for `_llm_envelope_parse.*--schema-gate.*_review_lens_envelope_schema_ok` in plugin.sh; passing directly establishes the full pattern is present.

SPEC-6: corresponds — grep checks specifically for `_llm_envelope_parse.*--schema-gate.*_rr_lens_envelope_schema_ok` in lenses.sh; passing directly establishes the full pattern is present.

## Status: complete, all 6 verdicts reached. FINAL RUN.
