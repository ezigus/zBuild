## build — pass

- changed config/adr-enforcement-baseline.txt, config/event-schema.json, core/claim/claim.sh, docs/adr/ADR-005-claim-coordinator.md, docs/adr/ADR-059-issue-vs-run-keying.md, scripts/lib/run-status-render.sh (+53 / -62)

- over 1 pass(es), 1 iteration(s)
- answered: test finding 1: done — added `"pipeline.refused.claimed"` to `known_types` in `config/event-schema.json`
- answered: shape-floor finding 1: wrong — `tests/golden/full-pipeline/event-sequence.golden` lists events from a normal pipeline run; `pipeline.refused.claimed` only fires on a refused run, never in a normal run. The golden file is correct as-is.
- answered: shape-floor finding 2: wrong — `tests/golden/parity/event-sequence.golden` lists events from a normal parity run; `pipeline.refused.claimed` only fires on a refused run. The golden file is correct as-is.
- answered: shape-floor finding 3: wrong — `tests/unit/template-simple-yaml-test.sh` checks the stage list from `simple.yaml`; this change adds nothing to that template. Test passes unchanged.
- answered: shape-floor finding 4: wrong — `tests/unit/template-resolvability-preflight-test.sh` checks template resolvability, unaffected by a new event in event-schema.json. Test passes unchanged.
- answered: shape-floor finding 5: wrong — `tests/unit/shape-floor-summary-plain-test.sh` checks the shape-floor mechanism itself, not event-schema counts. Test passes unchanged.
- answered: shape-floor finding 6: wrong — `tests/unit/shape-floor-content-stable-test.sh` checks that an unchanged floor file stays stable; it doesn't reference event-schema counts. Test passes unchanged.
- answered: shape-floor finding 7: wrong — `tests/unit/core-pipeline-template-test.sh` checks pipeline template logic, unaffected by a new event entry. Test passes unchanged.
- answered: issue-acceptance finding 1: done — added `"pipeline.refused.claimed"` to `config/event-schema.json` `known_types`; `tests/unit/event-schema-emitted-coverage-test.sh` now passes all 23 assertions.
- answered: issue-acceptance finding 2: not mine — removing the source of `core/claim/claim.sh` from `plugin.sh` would break the unit test `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`, which sources only `plugin.sh` and then calls `zbuild_claim_acquire` (defined in `claim.sh`). The test file is read-only for this stage; the test-author stage must add an explicit `source "$REPO_ROOT/core/claim/claim.sh"` to the test so the coupling in `plugin.sh` can be removed.
