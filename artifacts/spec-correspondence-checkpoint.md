# spec-correspondence checkpoint

## Files read
- design.md: confirms goal is to fix ADR-028 stale "not migrated" claims for review-lens/review-report, fix the comment-grep bug in adr-migration-claims-test.sh, and expand SPEC-2 loop. Two files changed: test file and ADR.

## Conclusions per SPEC

SPEC-1: corresponds — assertion searches ADR-028 for `**not** migrated` near plugin names; passing establishes the stale claim is absent.

SPEC-2: partial — loop expansion and directory-wide search are confirmed, but the regex `_llm_envelope_(parse|classify)` is broader than the requirement's "because `--schema-gate` is present in plugin.sh" — assertion passes even if only `_llm_envelope_classify` (no --schema-gate) is present.

SPEC-3: partial — same assertion as SPEC-2, same gap; also does not confirm the match came from lib/lenses.sh specifically.

SPEC-4: corresponds — regex `^[^#]*extract_first_json_object` excludes comment-only lines; passing means the comment at 394 no longer triggers the old branch.

SPEC-5: corresponds — grep checks specifically for `_llm_envelope_parse.*--schema-gate.*_review_lens_envelope_schema_ok` in plugin.sh; passing directly establishes the requirement.

SPEC-6: corresponds — grep checks specifically for `_llm_envelope_parse.*--schema-gate.*_rr_lens_envelope_schema_ok` in lib/lenses.sh; passing directly establishes the requirement.

## Status: complete, all 6 verdicts reached.
