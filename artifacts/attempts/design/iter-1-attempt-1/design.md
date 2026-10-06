# Design — #2035: ADR-028 closeout: mark review-lens and review-report as migrated

## Summary

**Goal.** Close out the stale record in ADR-028 §Migration and its guard test
(`adr-migration-claims-test.sh`). Both still say `review-lens` and
`review-report` are not migrated, but PRs #1840 and #1843 already migrated them
to `_llm_envelope_parse --schema-gate`.

**Context.** The guard test has a latent bug: its SPEC-3 grep for
`extract_first_json_object` in `review-lens/plugin.sh` does not exclude comment
lines. A comment at `plugin.sh:403` matches the grep, causing SPEC-3 to take
the "not migrated" branch and pass for the wrong reason. The stale ADR claim
goes undetected. Additionally, the SPEC-2 loop only checks `plan`,
`security-lens`, and `monitor` — it never checks `review-lens` or
`review-report` — so no assertion would have failed even if the migration had
been incomplete.

**Decision.** Fix two files only:
1. `tests/unit/adr-migration-claims-test.sh` — expand SPEC-2 loop to cover
   `review-lens` and `review-report` (searching all non-test `.sh` files per
   plugin directory, since `review-report`'s migration lives in `lib/lenses.sh`);
   fix SPEC-3 grep to exclude comment-only lines (`^[^#]*`); add a new assertion
   tagged `[#2035/SPEC-1]` that ADR-028 contains no stale "not migrated" claim
   for these plugins.
2. `docs/adr/ADR-028-shared-llm-agent-framework.md` — update §Migration: add
   `_review_lens_envelope_schema_ok` and `_rr_lens_envelope_schema_ok` to the
   per-stage gates list; replace the stale "not migrated" paragraph with a dated
   migration note citing #1840/#1843.

**Note on tag changes from prior design.** ADR-069 (PR #2304, 2026-10-05)
retired the `[guard]` tag — the design-gate rejects it as UNKNOWN_STATUS. The
prior design used `[guard]` for SPEC-2 through SPEC-6 and `[change]` for
SPEC-1. This revision replaces `[guard]` with `[done]` plus evidence (for
pre-existing code in the plugin files) or `[no-code]` (for test-only fixes),
and replaces `[change]` with `[code]`. ADR-070 (also 2026-10-05) requires
`covers: R-X` on every SPEC; all SPECs have been updated. SPEC-5 and SPEC-6
from the prior design are subsumed into SPEC-2[done] and SPEC-3[done] since the
schema-gate function names are part of the same evidence lines.

The real `[code]` requirement is SPEC-1: the ADR's stale "**not** migrated"
claim causes the new `[#2035/SPEC-1]` assertion to fail on old code, and pass
only after the ADR is corrected. WIRING is therefore
`docs/adr/ADR-028-shared-llm-agent-framework.md` — reverting it restores the
stale claim and SPEC-1 fails.

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
SPEC-1[code]: the guard test contains an assertion that ADR-028 does not name review-lens or review-report as not migrated; this assertion fails when the ADR has stale text (lines 189 and 193) and passes after those lines are updated covers: R-1 R-4
SPEC-2[done]: review-lens/plugin.sh calls _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok at its rc=0 parse site covers: R-2 R-3 evidence: plugins/agent/review-lens/plugin.sh:407 plugins/agent/review-lens/tests/review-lens-v2-result-test.sh
SPEC-3[done]: review-report/lib/lenses.sh calls _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok at its rc=0 parse site covers: R-2 R-3 evidence: plugins/agent/review-report/lib/lenses.sh:168
SPEC-4[no-code]: the SPEC-3 grep in adr-migration-claims-test.sh uses the pattern ^[^#]*extract_first_json_object so the comment at review-lens/plugin.sh:403 no longer triggers the not-migrated branch covers: R-1 R-5
SPEC-5[no-code]: the SPEC-2 loop in adr-migration-claims-test.sh checks every non-test .sh file under plugins/agent/review-lens/ and plugins/agent/review-report/ for _llm_envelope_parse; both pass because the migration is pre-existing covers: R-2 R-3 R-5
WIRING: docs/adr/ADR-028-shared-llm-agent-framework.md
TESTFILES:
SPEC-1: tests/unit/adr-migration-claims-test.sh
SPEC-4: tests/unit/adr-migration-claims-test.sh
SPEC-5: tests/unit/adr-migration-claims-test.sh
```

```supersedes
tests/unit/adr-migration-claims-test.sh [SPEC-3]: the old assertion label "the ADR does not claim review-lens is migrated" was reached via a wrong-branch pass — the comment-including grep matched plugin.sh:403, treating it as un-migrated code, so SPEC-3 took the not-migrated branch and passed; after the fix the comment-excluding grep finds no match, the migrated branch is taken, and the assertion instead checks the ADR for stale claims
```

LOOP_COMPLETE
