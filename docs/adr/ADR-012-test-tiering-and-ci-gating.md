# ADR-012 — Test Tiering and CI Gating

**Status:** Accepted  
**Date:** 2026-05-25  
**Deciders:** zbuild core team  

## Context

zbuild Phase 0 ships with 17 test files that mix unit and integration concerns under a single CI job labeled `unit`. Both `tests/run-unit.sh` and `tests/run-all.sh` perform identical discovery. A maintainer reading the Actions tab sees `smoke ✓ unit ✓` and reasonably concludes only unit tests exist.

Problems:
1. Test taxonomy is structural fiction — no tier separation.
2. CI hides actual test scope — integration-shaped tests run under a "unit" label.
3. No e2e, golden, or mutation tiers exist.
4. No per-tier CI jobs means a regression in one tier can hide behind another.

## Decision

### Three tiers, hard definitions

| Tier | Directory | Constraint |
|---|---|---|
| unit | `tests/unit/` | Single-module, no subprocess, no FS outside `$ZBUILD_TEST_TMP`, <1s/test |
| integration | `tests/integration/` | Multi-module, mocked at process boundary, <10s/test |
| e2e | `tests/e2e/` | Full `scripts/zbuild` CLI invocation, sandbox FS, no real network |

Additional tiers: `tests/golden/` (snapshot diffs), `tests/mutation/` (doc-driven mutation records).

### Filename rule

`tests/<tier>/<area>-test.sh`

### Per-tier runner

`bash scripts/run-tests.sh --tier {unit,integration,e2e,golden,mutation,lint,all}`

Output format: `<tier>: N/M passed` — parseable by CI summary step.

> **Amendment (#1129 Change C, 2026-06-29):** `lint` is now a first-class suite
> tier. `--tier all` (what `npm test` runs) runs `unit`, `integration`, `e2e`,
> `golden`, `mutation`, **and `lint`**, and the overall suite exit code reflects
> all of them — a lint failure fails the suite. The lint tier reuses
> `scripts/lib/framework-result.sh::framework_run_lint` (which runs `npm run lint`
> by default; overridable via `ZBUILD_LINT_CMD`, ADR-032/033) and emits the same
> `lint: N/M passed` summary line. This lets the simple.yaml pipeline drop its
> dedicated `lint` read-out gate (the `test` cycle member, which runs the suite,
> now also enforces lint) without losing lint enforcement — see ADR-013 note and
> ADR-040. See the **Coverage gating** note below for why coverage was NOT folded.

### Golden convention

- Snapshot files in `tests/golden/<name>.golden`
- Helper `assert_golden` in `scripts/lib/golden.sh`
- `UPDATE_GOLDEN=1 bash scripts/run-tests.sh --tier golden` regenerates

### Mutation convention

- One doc per core file: `tests/mutation/<file>-mutations.md`
- Each doc: file, mutation description, expected failing test(s), result
- `scripts/run-tests.sh --tier mutation` validates doc structure (not behavior)
- CODEOWNERS or `mutation-review` label enforces re-run on changes to listed files

### Coverage policy

- `kcov` over unit + integration tiers
- Floor = measured baseline − 5% on first wiring PR; ratchet upward each quarter
- **Caveat:** kcov-on-bash has rough attribution under `set -e`, sourced files, subshells — treat the floor as a regression detector, not an absolute quality measure

> **Current floor (as of 2026-05-31):** 29% statement coverage on
> `core/` + `scripts/lib/` (enforced via `scripts/check-coverage.sh` and
> CI per issue #372). Target: 70%. The floor is ratcheted upward as test
> depth improves.

> **Coverage gating (#1129 Change C):** Unlike lint, coverage is **NOT** folded
> into `--tier all`. `scripts/check-coverage.sh` works by re-invoking
> `run-tests.sh --tier unit --coverage-trace` to gather an xtrace; running that
> inside `--tier all` would (a) trip the #983 re-entrancy guard (a nested
> real-tier `run-tests.sh` with no `ZBUILD_TESTS_DIR` is refused), and (b) re-run
> the entire unit tier a second time (heavy duplicate runtime). Coverage therefore
> stays enforced by its dedicated CI `coverage` job (and `bash scripts/check-coverage.sh`
> locally), not by the suite. Accordingly, simple.yaml drops its `coverage`
> read-out gate as well (the CI job remains the enforcement point). Re-folding
> coverage cleanly is a future follow-up (decouple the trace mechanism from a
> nested suite run).

### CI job graph

```
Tier 1 (parallel): smoke  lint  unit  integration  e2e-mocked  golden  mutation-lint
Tier 2 (needs Tier 1 unit+integration): coverage
Tier 3 (needs all): summary → $GITHUB_STEP_SUMMARY
```

### Empty-tier semantics

An empty tier passes green with a warning annotation to avoid bootstrap deadlock during migration.

### Real-Claude e2e

Out of scope until a budget-capped, secret-gated, `safe-to-test-e2e`-labeled workflow lands. Per-PR ($10) + daily ($25) + weekly ($100) cap via cost-ledger lookup before invocation.

## Consequences

### Positive
- CI is honest: each job label matches what it runs.
- Test regressions are caught in the correct tier job.
- Golden contracts enforce event-shape stability.
- Mutation docs prevent silent coverage drift on core files.

### Negative
- Migration cost: 17 existing tests must be moved to new tier directories.
- `kcov` on bash is imprecise — floor is a coarse safety net, not a coverage guarantee.

### Neutral
- Backward compat: `tests/run-all.sh` and `tests/run-unit.sh` delegate to the new runner; existing `npm test` / `npm run test:unit` continue to work.

## Implementation Notes (Phase 0.5 — issue #291)

| Item | Status | PR / Notes |
|------|--------|------------|
| `scripts/run-tests.sh` per-tier runner (`unit` / `integration` / `e2e` / `golden` / `mutation`) | Implemented | #272 (cleanup wave) |
| All five tier directories present with tests | Implemented | confirmed by `npm test` — 23/23 unit, 31/31 integration, 6/6 e2e, 1/1 golden, 6/6 mutation |
| CI matrix: separate jobs per tier | Implemented | `.github/workflows/test.yml` |
| `kcov` bash coverage floor | Deferred → Phase 1 | floor threshold not yet set; tracking issue TBD |
| Existing `npm test` / `npm run test:unit` backward compat | Implemented | delegate to `run-tests.sh` |

## References

- ADR-001 (plugin registry — tests cover registry behavior)
- ADR-004 (redaction chokepoint — chokepoint test is tier `unit`)
- ADR-007 (golden contracts — golden tier formalizes Pillar 2)
- Issue #33 (redaction chokepoint test), #34 (goal sanitization), #70 (golden diffing), #138 (e2e workflows)
