# Design — #2035: ADR-028 closeout: mark review-lens and review-report as migrated

## Summary

**Goal.** Close out the stale record in ADR-028 §Migration and its guard test (`adr-migration-claims-test.sh`). Both still say `review-lens` and `review-report` are not migrated, but PRs #1840 and #1843 already migrated them to `_llm_envelope_parse --schema-gate`.

**Context.** The guard test has a latent bug: its SPEC-3 grep for `extract_first_json_object` in `review-lens/plugin.sh` does not exclude comment lines. A comment at `plugin.sh:394` ("schema-gated envelope parser replaces bare `extract_first_json_object`") matches the grep, causing SPEC-3 to take the "not migrated" branch and pass for the wrong reason. The stale ADR claim goes undetected. Additionally, SPEC-2 in the guard test only checks `plan`, `security-lens`, and `monitor` — it never checks `review-lens` or `review-report` — so no assertion would have failed even if the migration had been incomplete.

**Decision.** Fix two files only:
1. `tests/unit/adr-migration-claims-test.sh` — expand SPEC-2 to include `review-lens` and `review-report` (searching all non-test `.sh` files per plugin dir, since `review-report`'s migration lives in `lib/lenses.sh`); fix SPEC-3 grep to exclude comment-only lines; add a new assertion that the ADR contains no stale "not migrated" claim for these plugins.
2. `docs/adr/ADR-028-shared-llm-agent-framework.md` — update §Migration: add `_review_lens_envelope_schema_ok` and `_rr_lens_envelope_schema_ok` to the per-stage gates list; replace the "not migrated" paragraph (v1.2 §Migration, line 189) with a dated migration note citing #1840/#1843; remove the false "review-lens was not migrated" note from the bullet at line 193.

The 2026-09-02 correction note (historical) is preserved in the ADR.

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
SPEC-2[change]: tests/unit/adr-migration-claims-test.sh SPEC-2 loop is expanded to include review-lens, searching all non-test .sh files under the plugin directory (not just plugin.sh); the assertion passes because _llm_envelope_parse --schema-gate is present in plugin.sh.
SPEC-3[change]: tests/unit/adr-migration-claims-test.sh SPEC-2 loop is expanded to include review-report, searching all non-test .sh files under the plugin directory; the assertion passes because _llm_envelope_parse --schema-gate is present in lib/lenses.sh.
SPEC-4[guard]: tests/unit/adr-migration-claims-test.sh SPEC-3 grep excludes comment-only lines when checking review-lens/plugin.sh for extract_first_json_object; the comment at plugin.sh:394 no longer triggers the wrong branch.
SPEC-5[guard]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok (pre-existing; confirmed by SPEC-2 expansion and by review-lens-v2-result-test.sh SPEC-4).
SPEC-6[guard]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok (pre-existing; confirmed by SPEC-3 expansion).
WIRING: tests/unit/adr-migration-claims-test.sh
TESTFILES:
SPEC-1: tests/unit/adr-migration-claims-test.sh
SPEC-2: tests/unit/adr-migration-claims-test.sh
SPEC-3: tests/unit/adr-migration-claims-test.sh
SPEC-4: tests/unit/adr-migration-claims-test.sh
SPEC-5: tests/unit/adr-migration-claims-test.sh plugins/agent/review-lens/tests/review-lens-v2-result-test.sh
SPEC-6: tests/unit/adr-migration-claims-test.sh
```

```supersedes
tests/unit/adr-migration-claims-test.sh [SPEC-3]: assertion "the ADR does not claim review-lens is migrated" is now wrong by meaning — after the ADR fix, the ADR correctly DOES claim review-lens is migrated; the assertion is replaced by "review-lens migrated — no stale claim possible" (the else branch) which is reached by the comment-excluding grep.
```
