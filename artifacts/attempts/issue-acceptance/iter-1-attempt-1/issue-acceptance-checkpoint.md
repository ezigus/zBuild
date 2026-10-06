# Issue Acceptance Checkpoint

## Files read
- tests/unit/adr-migration-claims-test.sh: full file — confirmed SPEC-3 uses ^[^#]* grep; else branch says assert_pass "SPEC-3: review-lens migrated — no stale claim possible"; new [#2035/SPEC-5] loop checks review-lens and review-report for _llm_envelope_parse in all non-test .sh files; [#2035/SPEC-4] asserts no non-comment extract_first_json_object in review-lens/plugin.sh
- docs/adr/ADR-028-shared-llm-agent-framework.md lines 150-201: ADR migration section — both schema-gate functions listed (lines 186-187), both stages positively listed as migrated (lines 189, 191), old "not migrated" text removed; no contrary sentences remain

## Conclusions

R-1 (Red first): UNSURE. Structurally, SPEC-3's else branch asserts the migrated state and uses comment-excluding grep — the structural change is correct. But "fails at the merge-base because the comment at plugin.sh:353 matches" is a process claim about the TDD sequence I cannot verify from the diff alone. Additionally, at the actual merge-base of this PR (after PR #2037 already updated the ADR), the not-migrated branch would not assert_fail (the ADR no longer has "All four Pattern-1 stages.*review"), so SPEC-3 would pass for the wrong reason at merge-base — not fail as claimed.

R-2: MET. [#2035/SPEC-5] provides equivalent coverage — checks all non-test .sh files under each plugin directory for _llm_envelope_parse; tests pass.

R-3: UNSURE. R-3 says "turns SPEC-2 red." The SPEC-2 loop was not extended; SPEC-5 is a separate assertion. SPEC-5 checks for _llm_envelope_parse PRESENCE — it would not turn red if a bare extract_first_json_object call is ADDED alongside existing _llm_envelope_parse (only catches full reverts). For review-report specifically, no test catches "bare call added alongside _llm_envelope_parse." Under "replace/revert" interpretation SPEC-5 catches it; under "add alongside" interpretation it does not.

R-4: MET. ADR lines 186-187 list schema-gate functions; line 189 names both stages in Migration; line 191 has positive migration note; old "not migrated" sentences removed; no contrary text in scanned range.

R-5: MET. TEST VERDICT: pass, 815 passed, 0 failed.

## What is still unresolved
- R-1: merge-base behavior and PR body verification
- R-3: interpretation of "re-introducing"

## Verdict
UNSURE on R-1 and R-3.
