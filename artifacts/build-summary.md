## build — pass

- changed core/claim/claim.sh, core/pipeline/runner.sh (+29 / -10)

- over 1 pass(es), 1 iteration(s)
- answered: acceptance-gate finding 1: wrong — when ADR-005 is put back in the baseline, `tests/unit/lint-adr-enforced-by-test.sh` fails 2 of 29 tests: [A7] the real tree passes, and [#1764/DSADR-7] ADR-005-claim-coordinator.md must be removed from baseline. Directly verified by appending the entry and running the test.
- answered: issue-acceptance finding 1: done — added `zbuild_claim_build_holder()` to `core/claim/claim.sh` that builds and exports `_ZBUILD_CLAIM_HOLDER` before the sidecar is spawned; `runner.sh` calls it with a `declare -F` guard immediately before `_runner_status_comment_spawn` so the sidecar inherits the holder string at fork time.
