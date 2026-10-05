# Design — #2035: ADR-028 closeout: mark review-lens and review-report as migrated

## Summary

**Goal.** Close out the stale record in ADR-028 §Migration and its guard test
(`adr-migration-claims-test.sh`). Both still say `review-lens` and
`review-report` are not migrated, but PRs #1840 and #1843 already migrated them
to `_llm_envelope_parse --schema-gate`.

**Context.** The guard test has a latent bug: its SPEC-3 grep for
`extract_first_json_object` in `review-lens/plugin.sh` does not exclude comment
lines. A comment at `plugin.sh:394` ("schema-gated envelope parser replaces bare
`extract_first_json_object`") matches the grep, causing SPEC-3 to take the "not
migrated" branch and pass for the wrong reason. The stale ADR claim goes
undetected. Additionally, the pre-#2035 SPEC-2 loop only checks `plan`,
`security-lens`, and `monitor` — it never checks `review-lens` or
`review-report` — so no assertion would have failed even if the migration had
been incomplete.

**Decision.** Fix two files only:
1. `tests/unit/adr-migration-claims-test.sh` — expand SPEC-2 loop to cover
   `review-lens` and `review-report` (searching all non-test `.sh` files per
   plugin directory, since `review-report`'s migration lives in `lib/lenses.sh`);
   fix SPEC-3 grep to exclude comment-only lines (`^[^#]*`); add a new SPEC-1
   assertion that the ADR contains no stale "not migrated" claim for these
   plugins.
2. `docs/adr/ADR-028-shared-llm-agent-framework.md` — update §Migration: add
   `_review_lens_envelope_schema_ok` and `_rr_lens_envelope_schema_ok` to the
   per-stage gates list; replace the stale "not migrated" paragraph with a dated
   migration note citing #1840/#1843. The 2026-09-02 correction note is
   preserved.

**SPEC-2 and SPEC-3 are [guard], not [change].** The migration patterns are
pre-existing code (`review-lens/plugin.sh` and `review-report/lib/lenses.sh`
both already contain `_llm_envelope_parse --schema-gate` before this change).
Test assertions checking for these patterns pass on old code — tagging them
[change] caused tautology failures in acceptance-gate (negctl). The real
[change] is SPEC-1: the ADR's stale "**not** migrated" claim causes SPEC-1 to
fail on old code and pass only after the ADR is corrected. WIRING is therefore
`docs/adr/ADR-028-shared-llm-agent-framework.md` (reverting it restores the
stale claim; SPEC-1 then fails).

```scope
docs/adr/ADR-028-shared-llm-agent-framework.md
tests/unit/adr-migration-claims-test.sh
plugins/agent/review-lens/plugin.sh
plugins/agent/review-report/lib/lenses.sh
plugins/agent/review-report/plugin.sh
plugins/agent/review-lens/tests/review-lens-v2-result-test.sh
config/adr-enforcement-baseline.txt
```

```acceptance
SPEC-1[change]: tests/unit/adr-migration-claims-test.sh contains an assertion that ADR-028 does not contain a stale "not migrated" claim for review-lens or review-report; this assertion fails before the ADR is updated (stale text present) and passes after.
SPEC-2[guard]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate; the explicit file-level assertion added to adr-migration-claims-test.sh passes both before and after this change (migration pre-exists from #1840).
SPEC-3[guard]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate; the explicit file-level assertion added to adr-migration-claims-test.sh passes both before and after this change (migration pre-exists from #1843).
SPEC-4[guard]: tests/unit/adr-migration-claims-test.sh SPEC-3 grep excludes comment-only lines (^[^#]*extract_first_json_object) so the comment at plugin.sh:394 does not trigger the wrong branch; passes both before and after.
SPEC-5[guard]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok (pre-existing; confirmed by the SPEC-2 loop expansion and by review-lens-v2-result-test.sh SPEC-4).
SPEC-6[guard]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok (pre-existing; confirmed by the SPEC-2 loop expansion).
WIRING: docs/adr/ADR-028-shared-llm-agent-framework.md
TESTFILES:
SPEC-1: tests/unit/adr-migration-claims-test.sh
SPEC-2: tests/unit/adr-migration-claims-test.sh
SPEC-3: tests/unit/adr-migration-claims-test.sh
SPEC-4: tests/unit/adr-migration-claims-test.sh
SPEC-5: tests/unit/adr-migration-claims-test.sh plugins/agent/review-lens/tests/review-lens-v2-result-test.sh
SPEC-6: tests/unit/adr-migration-claims-test.sh
```

```supersedes
tests/unit/adr-migration-claims-test.sh [SPEC-3]: old assertion label "the ADR does not claim review-lens is migrated" was reached via a wrong-branch pass (comment-including grep found plugin.sh:394's comment, treating it as un-migrated code); after the fix, the comment-excluding grep finds no match and the "review-lens migrated — no stale claim possible" branch is taken instead.
```

LOOP_COMPLETE
