# ADR-007: Test Strategy

**Status:** Accepted
**Date:** 2026-05-24

## Context

The legacy code has 160 test files (158 bash + 2 vitest) and `legacy/scripts/lib/test-helpers.sh`, which provides color output, temp-dir isolation, PATH-shadow mocks, child-process cleanup, and CI-env sanitization. The harness is generic and well-crafted; the test inventory is mixed.

A first-pass audit incorrectly claimed "60+ grep-for-function-name assertions" as a liability. Re-audit found **zero** `grep -qE "^funcname\(\)"` patterns across the 160 files. Tests invoke functions directly and assert outputs/side-effects. That's a major asset.

Confirmed gap: **zero golden-output / snapshot tests.** No `*.golden`, no `expected/`, no `fixtures/`. Tests are assertion-based; output contracts (CLI JSON shape, structured artifact formats) drift undetected.

## Decision

zBuild's test strategy has three pillars: **call-and-assert** (lifted from legacy), **golden-file diffing** (new), and the **5-test trial** per keeper (process gate).

### Pillar 1: Call-and-assert (lift wholesale)

`scripts/lib/test-helpers.sh` is lifted from `legacy/scripts/lib/test-helpers.sh` with minimal changes (legacy env var names renamed to `ZBUILD_*`). Convention:
- Test file naming: `tests/<feature>-test.sh` for unit/integration; `tests/e2e/<feature>-test.sh` for end-to-end.
- Co-located plugin tests: `plugins/<kind>/<name>/tests/<name>-test.sh` (integration) and `plugins/<kind>/<name>/tests/<name>-unit-test.sh` (unit). Discovered by `run-tests.sh` via glob `plugins/**/tests/*-test.sh`.
- Every test file is idempotent on re-source (`[[ -n "${_<name>_TEST_LOADED:-}" ]] && return 0`).
- Master cleanup trap kills child processes; tests cannot leak daemons.

### Pillar 2: Golden-file diffing (new)

`tests/golden/` directory. For output contracts (CLI JSON shape, structured artifact formats, ADR-required schemas):

```bash
# In test:
zbuild status --json > "$ACTUAL"
diff -u "tests/golden/status-json-empty-pipeline.golden" "$ACTUAL"
```

Update flow:
```bash
ZBUILD_UPDATE_GOLDEN=1 ./tests/cli-status-test.sh
# review the diff in git, commit the .golden change with a justification in the PR
```

Golden files MUST be reviewed in PRs. Untouched golden files are checked against actual output every CI run.

### Pillar 3: 5-test trial per keeper

Every keeper has an issue with this checklist (template in `.github/issues/keepers-manifest.yaml`):

1. **Behavior preserved.** New code's behavior matches legacy's, verified by a regression test that exercises both.
2. **Regression test exists.** Test path documented in the issue. Test fails before migration, passes after.
3. **Citation discoverable.** `legacy/<file>:<line>` from the issue resolves in the current tree (until pruned).
4. **Mapping matches.** New file location matches the row in KEEPERS §H mapping table.
5. **Removal reproduces symptom.** Deleting the new implementation reproduces the original symptom the legacy code was solving.

The trial is the gate to `git rm` the legacy source and write the tombstone.

### Migration matrix (from KEEPERS §G)

Enumerated row-by-row in `.github/issues/keepers-manifest.yaml`. Each of legacy's 160 test files lands in one bucket:

- **~50 migrate near-unchanged.** All 25 lib tests (daemon-state, pipeline-stages, helpers, compat, config). All 9 E2E tests. Core feature tests for pipeline/ci/loop/replay/daemon/init/cleanup/cost/db. Harness is reusable.
- **~30 rewrite.** Adapters, agi-roadmap, chaos, postmortem-460, ruflo-adapter, tmux-pipeline, ai-provider, cross-repo-isolation, budget-chaos, evidence — all encode platform-specific assumptions that won't survive plugin migration.
- **~20 delete.** Obsolete features, incident-specific postmortems (e.g., postmortem-460), extreme stress tests. Not load-bearing for zBuild.

The manifest is the truth; phase-ship blocks until every test file has a bucket assignment.

### CI

`.github/workflows/test.yml`:
- On every PR: lint (shellcheck), unit tests, golden-file checks.
- Nightly: full E2E suite.
- Per-PR golden file changes must be reviewed (workflow comment lists changed golden files).

### Multi-daemon claim race test

Phase 0 verification calls for this: spawn two simulated daemons, have them race for the same issue, assert exactly one wins. Lives in `tests/e2e/claim-race-test.sh`. Runs nightly + on any PR touching `plugins/claim-coordinator/`.

## Consequences

**Good:**
- Harness reuse is enormous (saves weeks of work).
- Golden tests catch silent contract drift (JSON shape changes, manifest schema bumps).
- 5-test trial makes "is this keeper done?" objective.
- Migration matrix makes "are we ready to ship Phase 5?" countable.

**Bad:**
- Golden files require discipline to maintain. Stale goldens become noise. Mitigation: every golden has a header comment explaining what contract it pins.
- The 5-test trial is process overhead per keeper. Trade-off: explicit gates beat implicit drift.
- Rewriting 30 tests is real effort. Mitigation: parallelize across the migration; each rewrite is independent.

## Implementation Notes (Phase 0.5 — issue #291)

- **Tier directories exist:** `tests/unit/`, `tests/integration/`, `tests/e2e/`, `tests/golden/`, `tests/mutation/`. Per-tier runner at `scripts/run-tests.sh`.
- **Mutation harness** (`scripts/run-mutation.sh`, added by PR #301) applies real patches and asserts the expected test fails. Patch-vs-test relevance enforcement is tracked by **#309**.
- **Golden snapshots** present today: `init-state-shape.golden`, `redaction-applied-shape.golden`, `cli-dry-run.golden`. Coverage is intentionally narrow; expansion proceeds with each new contract.
- **5-test trial** has been applied to memory-sqlite (#216) and orch-sequential (#219) per PR #304. Other keepers await per-PR trial files; ADR-002 pruning protocol blocks `git rm` of legacy source until the trial files exist.
- **Parity test** (`tests/e2e/parity-local-vs-ci-test.sh`) diffs full `pipeline-state.json` (normalized) + artifact sha256 tree + event-type sequence — the depth promised by ADR-010 (added by PR #306).
- **CI gating:** `.github/workflows/test.yml` runs smoke + lint + unit + integration + e2e + golden + mutation as parallel jobs.

## References

- [KEEPERS.md §G](../KEEPERS.md#section-g--test-harness-carry-forward-with-audit-correction) — full migration matrix and harness audit.
- [KEEPERS.md §J](../KEEPERS.md#section-j--verification) — the 5-test trial.
- `legacy/scripts/lib/test-helpers.sh` — source for the lifted harness.
