## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: lens-correctness-design finding 1: wrong — the scenario it describes (resume skip guard activating for leaf stages after the targeted cycle in combined `--resume --from-stage <s>` mode) is already addressed by Gap 11 in the architectural decision: immediately after clearing `skip_until_stage` in both the `cycle:*` and `stage:*` dispatch arms, `resume_mode` is also set to false (`[[ -n "$skip_until_stage" ]] && { skip_until_stage=""; resume_mode=false; }`). This prevents the resume skip guard from activating for stages after `<s>`. Pure resume runs (no from-stage) never set `skip_until_stage`, so this line is unreachable in that path. DSFSTG-3[code] provides the observable test: a 3-unit fixture [intake, cyc, verify] where all three are marked complete; in combined mode with `--from-stage cyc`, `verify` must still emit stage.start. The test fails on the unfixed code (verify silently skipped) and passes after the Gap 11 fix (Finding 30 and Finding 31 in the design document).
