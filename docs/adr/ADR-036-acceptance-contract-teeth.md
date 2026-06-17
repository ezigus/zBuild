# ADR-036 — Acceptance-contract teeth (mechanical SPEC↔assertion gate)

**Status:** Accepted (2026-06-17)
**Related:** ADR-031 (behavioral acceptance contract), ADR-013 (canonical stage list),
ADR-020 (inter-stage data contract / optional inputs), ADR-022 (test-assessment),
ADR-030 (scope governance)
**Issue:** #922 (843-F). Surfaced by the dogfood of #844.

## Context

ADR-031 introduced the behavioral acceptance contract: `design` emits an
```` ```acceptance ```` block of `SPEC:` lines + `TESTFILES:`, writes failing
stubs, `build` makes them pass, and `test_assessment` judges whether each SPEC
holds. But ADR-031 explicitly left the teeth as **convention, not tooling**
("*Design writes failing tests … enforced by convention, not by tooling*";
"*Don't-weaken charter … enforced by process, not automation*").

The hole: nothing links an individual SPEC to an assertion that would **fail
without the implementation**. A SPEC passes if its TESTFILES are merely green
and the (LLM) `test_assessment` believes the prose — it "passes on LLM grounding
alone."

**Live proof — #844.** The regression test
`tests/unit/cycle-g2-cross-iter-timeout-test.sh` went green **even with the
implementation's seeding loop deleted** (its abandon assertions used
`MOCK_PLAN="build:timeout"`, hitting the within-run threshold regardless of the
feature). `test_assessment` returned `pass`; the headline behavior was never
actually exercised. A tautological test the contract could not detect.

## Decision

Add a mechanical, **non-LLM** `acceptance-gate` stage (a canonical leaf stage,
ADR-013 amendment) that gives the contract teeth in two levels.

### 1. Stable SPEC ids + assertion tagging

`SPEC:` lines gain stable ids: `SPEC-1:`, `SPEC-2:`, … (permanent across
iterations). Each backing assertion must carry its id in the assert **label**,
e.g. `assert_eq "[SPEC-2] carry-over count" exp act`. (`acceptance-block.sh`
keeps parsing legacy bare `SPEC:` lines for back-compat; only `SPEC-n:` lines
carry an id the gate enforces.)

### 2. Level 1 — tag-presence (cheap, fail-fast)

`acceptance-coverage.sh`: every `SPEC-n` must have ≥1 `[SPEC-n]`-tagged
assertion across the declared TESTFILES. A SPEC with none fails the gate
(`acceptance.gate.untagged_spec`).

### 3. Level 2 — baseline negative control (the real teeth)

`acceptance-negctl.sh`: each `SPEC-n`'s tagged TESTFILE must **fail at the
merge-base baseline and pass at HEAD**. Mechanism: a detached `git worktree` at
the merge-base with the default branch (resolved by the shared
`scripts/lib/merge-base.sh`, the same basis review uses, #896), with the TESTFILE
overlaid from HEAD (implementation reverted, test current). A valid control ⇔
`rc_baseline != 0 AND rc_head == 0`. A SPEC whose tagged test passes at baseline
is **tautological** and is rejected (`acceptance.gate.tautology`); a stub that
never passes is rejected (`not_passing_at_head`). Granularity is per-TESTFILE;
author one SPEC per assertion for precise attribution.

When the merge-base equals HEAD (no implementation delta) the control is
skipped, not failed (`NEGCTL SKIP no_impl_delta`).

### 4. Composability — optional input, no-op when absent

The gate declares the design/acceptance artifact as an **optional input**
(`required: false`, ADR-020 convention). With no acceptance block present it is a
**no-op pass** (`acceptance.gate.skipped`), so it drops cleanly into any
template and is omittable from any other — honoring stage independence.

### 5. Placement

In the standard template the gate runs inside `review_cycle` immediately after
`build_test_cycle`, before the CQ stages — a broken acceptance contract fails
fast. Because it is its own stage it does **not** depend on `test_assessment`
changes (#867).

## Consequences

- The #844 defect class (green-but-inert tautological tests) is now caught
  mechanically, not left to LLM judgment.
- `design`/`build` prompts are updated to emit `SPEC-n:` ids and `[SPEC-n]`
  tags. Anti-patterns (tautological tag, logic-in-helper, multi-SPEC-per-label,
  unconditional mocks) are stated in the prompts.
- ADR-031's "convention / process" clauses for test-first enforcement and the
  don't-weaken charter are **superseded** by this mechanical gate.
- New events registered in `config/event-schema.json`:
  `acceptance.gate.{start,complete,skipped,untagged_spec,tautology,baseline_resolve_failed,worktree_failed}`.
- ADR-013 grows by one canonical leaf stage (`acceptance-gate`), 16 → 17.

## Implementation Notes

- **Libraries** (`scripts/lib/`): `acceptance-coverage.sh` (Level 1 tag-presence),
  `acceptance-negctl.sh` (Level 2 negative control), and `merge-base.sh`
  (`zbuild_resolve_merge_base`, extracted from review's private resolver so the
  gate does not source the review plugin). SPEC-id parsing + `acceptance_list_spec_ids`
  / `acceptance_list_testfiles` live in the existing `acceptance-block.sh`.
- **Negative-control mechanism**: a detached `git worktree add --detach <merge-base>`
  with each declared TESTFILE overlaid via `git show HEAD:<path>`; the test runs
  with `ZBUILD_TEST_QUIET` unset and a hard timeout (`ZBUILD_NEGCTL_TIMEOUT`,
  default 60s). The validity test is rc-based at the file level: `rc_baseline != 0
  && rc_head == 0`. The worktree is removed via a `RETURN` trap.
- **Stage** (`plugins/agent/acceptance-gate/`): `kind: agent`, modeled on
  `cq-preflight`; writes `acceptance-gate-result.json` (`{"verdict","failures"}`),
  returns rc=1 on fail (picked up mechanically by `runner_read_stage_verdict`'s
  `*` branch — no `verdict.sh` change). `design` is declared `required: false`.
- **Wiring**: `review_cycle.flow` (after `build_test_cycle`), `_ZBUILD_CANONICAL_STAGES`
  (template.sh, 16→17), `_LC_STAGE_IDS_TO_CHECK` (lint-contract.sh), the test roster
  (`_ZBUILD_STANDARD_ROSTER` + `register_standard_pipeline_stubs`, #921), ADR-013,
  and the event schema.
- **Adding a stage cost (ABS-1)**: this change touched ~14 roster/position/count
  test sites despite #921's single-source helper, because the remaining sites are
  intentional tripwires and custom-body tests. Future stage additions should reuse
  `register_standard_pipeline_stubs` wherever a test only needs a pass-through roster.

## Limitations / future work

- Per-TESTFILE granularity: a file mixing a load-bearing and a tautological SPEC
  is judged load-bearing. The prompt mandates one SPEC per assertion to mitigate.
- The review-side coverage complement (downgrade `approve` when a SPEC's test is
  untouched in the diff) is tracked separately (843-H / #923).
