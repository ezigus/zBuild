## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: acceptance-gate finding 1: done — DSFSTG-4 reclassified from `[code]` to `[done]`. The base code (`core/pipeline/runner.sh`) already has the `--from-stage` validation guard before the auto-resume check (confirmed at line 1737, before the auto-resume elif at line 2081), so a test of "exits 1 when --from-stage without --resume" passes on the base code. DSFSTG-4 is now `[done]` with evidence `core/pipeline/runner.sh:"--from-stage is only valid with --resume"`. The [#1805/DSFSTG-4] test sub-case was removed from the from-stage-rehydrate-test.sh step and from TESTFILES (no test is written for a [done] SPEC). The Gap 12 fix step (move the guard back before auto-resume) remains in the steps block — it drives restoration of the regression the branch introduced, independent of the SPEC classification. Findings 1, 3, and 32 updated accordingly.
- not answered: lens-correctness-design finding 1
