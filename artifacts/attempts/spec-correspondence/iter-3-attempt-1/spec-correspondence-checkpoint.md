# spec-correspondence checkpoint

## Files read
- design.md: confirms goal is to fix ADR-028 stale "not migrated" claims for review-lens/review-report, fix the comment-grep bug in adr-migration-claims-test.sh, and expand SPEC-2 loop. Two files changed: test file and ADR.

## Conclusions per SPEC (revised)

SPEC-1: corresponds — assertion searches ADR-028 for `**not** migrated` near plugin names; passing establishes the stale claim is absent.

SPEC-2: partial — assertion checks only plugins/agent/review-lens/plugin.sh for `_llm_envelope_parse.*--schema-gate`; it establishes the pattern is present in plugin.sh, but does NOT verify the requirement's "searching all non-test .sh files under the plugin directory (not just plugin.sh)" — the loop-scope claim is untested.

SPEC-3: partial — assertion checks only plugins/agent/review-report/lib/lenses.sh; establishes pattern present in lenses.sh, but same gap: does not verify the loop searches all non-test .sh files, nor that loop expansion to review-report occurred.

SPEC-4: corresponds — regex `^[^#]*extract_first_json_object` excludes comment-only lines; passing means the comment at plugin.sh:394 no longer triggers the old branch.

SPEC-5: corresponds — grep checks specifically for `_llm_envelope_parse.*--schema-gate.*_review_lens_envelope_schema_ok` in plugin.sh; passing directly establishes the requirement.

SPEC-6: corresponds — grep checks specifically for `_llm_envelope_parse.*--schema-gate.*_rr_lens_envelope_schema_ok` in lib/lenses.sh; passing directly establishes the requirement.

## Status: complete, all 6 verdicts reached.
