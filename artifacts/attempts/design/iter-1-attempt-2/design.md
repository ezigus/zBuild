# Design — #2035: ADR-028 closeout: mark review-lens and review-report as migrated

## Summary

**Goal.** Close out the stale record in ADR-028 §Migration and its guard test
(`adr-migration-claims-test.sh`). Both still say `review-lens` and
`review-report` are not migrated, but PRs #1840 and #1843 already migrated them
to `_llm_envelope_parse --schema-gate`.

**Context.** The guard test has two defects. First, its SPEC-3 grep for
`extract_first_json_object` in `review-lens/plugin.sh` does not exclude comment
lines — a comment at `plugin.sh:403` matches, causing SPEC-3 to take the
"not migrated" branch and pass for the wrong reason: the ADR says "review-lens
and review-report are not migrated" (not "All four Pattern-1 stages.*review"),
so the not-migrated branch falls through to assert_pass, hiding the stale claim.
Second, the SPEC-2 loop only checks `plan`, `security-lens`, and `monitor`, so
no assertion fires even if the migration were incomplete. Both defects let the
stale ADR claim pass undetected. Neither `_review_lens_envelope_schema_ok` nor
`_rr_lens_envelope_schema_ok` appears anywhere in ADR-028.

**Decision.** Fix two files only:
1. `tests/unit/adr-migration-claims-test.sh` — fix SPEC-3 grep to exclude
   comment-only lines (`^[^#]*extract_first_json_object`); expand SPEC-2 loop
   to cover every non-test `.sh` file under `plugins/agent/review-lens/` and
   `plugins/agent/review-report/` (since review-report's migration lives in
   `lib/lenses.sh`); add assertion `[#2035/SPEC-1]` that ADR-028 has no text
   calling either stage "not migrated"; add assertion `[#2035/SPEC-6]` that
   ADR-028 positively names `_review_lens_envelope_schema_ok` and
   `_rr_lens_envelope_schema_ok` in its migration record.
2. `docs/adr/ADR-028-shared-llm-agent-framework.md` — update line 187 to add
   `review-lens` (#1840) and `review-report` (#1843) to the migrated-stages
   list; add `_review_lens_envelope_schema_ok` and `_rr_lens_envelope_schema_ok`
   to the per-stage gates block; replace the stale "not migrated" paragraphs at
   lines 189 and 193 with dated migration notes citing #1840/#1843.

**Coverage split for R-4.** R-4 has two clauses: (a) "ADR-028 names both stages
as migrated" and (b) "no sentence in it says otherwise." SPEC-1 covers clause
(b) — it fails when the ADR still says "not migrated." SPEC-6 covers clause (a)
— it fails when the ADR does not positively name the schema-gate functions.
Reverting the ADR restores stale text and removes the positive migration note,
failing both SPEC-1 and SPEC-6. SPEC-2[done] and SPEC-3[done] cover plugin code
only; SPEC-6 is the distinct check against the ADR document.

**Tag notes.** ADR-069 retired `[guard]`/`[change]`; this design uses `[code]`,
`[no-code]`, and `[done]`. ADR-070 requires `covers: R-X` on every SPEC line.

**Prior design verified.** All claims from the prior design were confirmed
against current repository state: plugin.sh:407 and lenses.sh:168 use the
schema-gate parser; ADR-028 lines 189 and 193 contain stale "not migrated" text;
neither schema-gate function name appears in ADR-028; the test defects are exactly
as described. `config/adr-enforcement-baseline.txt` lists ADR-028 (line 33), so
the missing `## Enforced by` section does not cause lint failure. The audit at
`docs/audits/adr-2026-10-03/batch-3.md` line 380 independently documents the
same contradiction.

```scope
docs/adr/ADR-028-shared-llm-agent-framework.md
tests/unit/adr-migration-claims-test.sh
plugins/agent/review-lens/plugin.sh
plugins/agent/review-report/lib/lenses.sh
plugins/agent/review-report/plugin.sh
plugins/agent/review-lens/tests/review-lens-v2-result-test.sh
config/adr-enforcement-baseline.txt
docs/audits/adr-2026-10-03/batch-3.md
```

```acceptance
SPEC-1[code]: the guard test contains an assertion tagged [#2035/SPEC-1] that ADR-028 has no text calling review-lens or review-report "not migrated"; fails on current ADR (lines 189 and 193 contain that text) and passes after those lines are replaced covers: R-1 R-4
SPEC-2[done]: review-lens/plugin.sh calls _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok at its rc=0 parse site covers: R-2 R-3 evidence: plugins/agent/review-lens/plugin.sh:407 plugins/agent/review-lens/tests/review-lens-v2-result-test.sh
SPEC-3[done]: review-report/lib/lenses.sh calls _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok at its rc=0 parse site covers: R-2 R-3 evidence: plugins/agent/review-report/lib/lenses.sh:168
SPEC-4[no-code]: the SPEC-3 grep in adr-migration-claims-test.sh uses the pattern ^[^#]*extract_first_json_object so the comment at review-lens/plugin.sh:403 no longer triggers the not-migrated branch covers: R-1 R-5
SPEC-5[no-code]: the SPEC-2 loop in adr-migration-claims-test.sh checks every non-test .sh file under plugins/agent/review-lens/ and plugins/agent/review-report/ for _llm_envelope_parse; both pass because the migration is pre-existing covers: R-2 R-3 R-5
SPEC-6[code]: the guard test contains an assertion tagged [#2035/SPEC-6] that ADR-028 names _review_lens_envelope_schema_ok and _rr_lens_envelope_schema_ok in its migration record; fails on current ADR (neither name appears there) and passes after the ADR update adds the positive migration note covers: R-4
WIRING: docs/adr/ADR-028-shared-llm-agent-framework.md
TESTFILES:
SPEC-1: tests/unit/adr-migration-claims-test.sh
SPEC-4: tests/unit/adr-migration-claims-test.sh
SPEC-5: tests/unit/adr-migration-claims-test.sh
SPEC-6: tests/unit/adr-migration-claims-test.sh
```

```supersedes
tests/unit/adr-migration-claims-test.sh [SPEC-3]: the old assertion label "the ADR does not claim review-lens is migrated" was reached via a wrong-branch pass — the comment-including grep matched plugin.sh:403, treating the plugin as un-migrated, so SPEC-3 took the not-migrated branch; after the SPEC-4 fix the comment-excluding grep finds no bare call, the migrated branch is taken, and the assertion label becomes "review-lens migrated — no stale claim possible"
```

ANSWER spec-coverage finding 1: done — SPEC-6[code] retained from iteration 3 covers R-4 first clause ("ADR-028 names both stages as migrated") by asserting ADR-028 positively names _review_lens_envelope_schema_ok and _rr_lens_envelope_schema_ok; fails on current ADR where neither name appears
ANSWER spec-coverage finding 2: done — R-4 is now split across two SPECs: SPEC-6[code] covers the positive clause ("names both stages as migrated") and SPEC-1[code] covers the negative clause ("no sentence says otherwise"); together they fully cover R-4
ANSWER spec-coverage finding 3: done — SPEC-6[code] is a distinct ADR-document check, separate from SPEC-2[done] and SPEC-3[done] which only attest plugin code; SPEC-6 fails when the ADR doesn't positively name the schema-gate functions regardless of what the plugin code does

LOOP_COMPLETE
