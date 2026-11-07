## review-lens-scope — fail

- found: medium: Both DSFSTG-1 and DSFSTG-2 test `--from-stage` only with `--resume`, always exercising the `skip_restore=true` branch of `_runner_from_stage_preflight`; the `skip_restore=false` branch (plain `--from-stage` without `--resume`, which performs the git archive restore itself) is never exercised, leaving the substantively different restore path untested despite DSFSTG-1's Given clause saying 'a new invocation uses --from-stage' without requiring --resume. (tests/integration/from-stage-rehydrate-test.sh:111)

- medium: Both DSFSTG-1 and DSFSTG-2 test `--from-stage` only with `--resume`, always exercising the `skip_restore=true` branch of `_runner_from_stage_preflight`; the `skip_restore=false` branch (plain `--from-stage` without `--resume`, which performs the git archive restore itself) is never exercised, leaving the substantively different restore path untested despite DSFSTG-1's Given clause saying 'a new invocation uses --from-stage' without requiring --resume. (tests/integration/from-stage-rehydrate-test.sh:111)
- score: 8
