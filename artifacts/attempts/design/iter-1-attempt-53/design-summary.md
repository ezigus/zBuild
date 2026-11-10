## design — fail

- the design fails 17 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: lens-correctness-design finding 1: wrong** — the design already addresses this. Gap 11 in the architectural decision documents the exact failure mode (after clearing `skip_until_stage`, `resume_mode` stays `true` and the resume skip guard fires for all subsequent units). The Decision paragraph requires `resume_mode=false` immediately after clearing `skip_until_stage` in both the cycle:* arm and stage:* arm. DSFSTG-3[code] pins the observable behavior with a 3-unit fixture [intake, cyc, verify] where verify is marked complete and must still emit stage.start in combined `--resume --from-stage cyc` mode; this test fails on old code and passes after the fix.
