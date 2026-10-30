# Design: #1753 — Fix unfinished review lens treated as pass

## Architectural Decision Summary

**Goal.** A review lens that does not finish must count as a failure, setting
`ZBUILD_RUN_FLAGGED=yes` and blocking auto-merge. Currently any map-member outcome other than
`fail` (e.g. `timed_out`, `out_of_turns`, `broken`, `missing`) leaves `ZBUILD_RUN_FLAGGED=no`,
allowing the `auto_unless_flagged` delivery policy to proceed to merge as if the lens had passed.

**Context.** `_map_write_summary` in `core/pipeline/strategies/map.sh` computes `ZBUILD_RUN_FLAGGED`
after the map group runs. It currently sets `flagged=yes` only when `outcome == fail` (line 157).
Any other non-pass outcome populates `_ZB_MAP_UNFINISHED` (used for the group banner) but leaves
`flagged=no`. Downstream, `plugins/agent/pr-delivery/plugin.sh:161` already blocks merge under
`auto_unless_flagged` when `ZBUILD_RUN_FLAGGED=yes`; the delivery path is correct. The gap is
exclusively in map.sh's `flagged` computation.

**Decision.** Change `map.sh:157` from:

```bash
[[ "$outcome" == fail ]] && flagged=yes
```

to:

```bash
[[ "$outcome" == pass ]] || flagged=yes
```

Any outcome that is not `pass` — conclusive `fail` or any unfinished outcome (`timed_out`,
`out_of_turns`, `interrupted`, `broken`, `missing`, `misconfigured`, `unavailable`, etc.) — sets
`ZBUILD_RUN_FLAGGED=yes`. No changes are needed to `runner.sh`, `pr-delivery/plugin.sh`, or
`merge/plugin.sh`: those files already handle `ZBUILD_RUN_FLAGGED=yes` correctly.

The comment on `map.sh:132` also describes `ZBUILD_RUN_FLAGGED` as set when an element "failed"
— it must be updated to say "failed or did not finish."

**ADR-040 §2368 part 2** currently states `ZBUILD_RUN_FLAGGED` is `yes` "when a lens found a
high or critical problem the change introduced." That description is now incomplete: the variable
is also `yes` when any element did not finish. A new amendment records this. Per CLAUDE.md, the
amendment must add or update the `## Enforced by` section entry for the new statement.

**No supersedes.** No existing test assertion pins the bug behavior (`timed_out → ZBUILD_RUN_FLAGGED=no`).
The fix is purely additive to the contract `engine-combines-map-test.sh` already describes.

```scope
core/pipeline/strategies/map.sh
docs/adr/ADR-040-composable-gate-lens-taxonomy.md
tests/unit/engine-combines-map-test.sh
tests/integration/map-members-reported-test.sh
tests/integration/merge-policy-auto-unless-flagged-test.sh
tests/unit/merge-v2-result-test.sh
tests/unit/pr-delivery-v2-result-test.sh
tests/unit/pr-open-v2-inputs-test.sh
tests/unit/pr-open-v2-result-test.sh
plugins/agent/pr-delivery/plugin.sh
plugins/tool/merge/plugin.sh
plugins/tool/pr-open/tests/pr-open-test.sh
core/pipeline/runner.sh
```

```acceptance
SPEC-1[code]: When any map member's outcome is not `pass`, `_strategy_run_map` exports `ZBUILD_RUN_FLAGGED=yes`. covers: R-1
SPEC-2[no-code]: ADR-040 is amended to state that an element with outcome ≠ `pass` (whether `fail` or unfinished) sets `ZBUILD_RUN_FLAGGED=yes`, and its `Enforced by` entry names the test. covers: R-1
SPEC-3[done]: Under `auto_unless_flagged`, pr-delivery routes to pr-open (not merge) when `ZBUILD_RUN_FLAGGED=yes`. covers: R-1 evidence: plugins/agent/pr-delivery/plugin.sh:161 tests/integration/merge-policy-auto-unless-flagged-test.sh
WIRING: core/pipeline/runner.sh
TESTFILES:
SPEC-1: tests/unit/engine-combines-map-test.sh
SPEC-2: docs/adr/ADR-040-composable-gate-lens-taxonomy.md
```

## Findings

**Plan scope items not requiring code changes.** The plan listed `plugins/agent/pr-delivery/plugin.sh`,
`plugins/tool/merge/plugin.sh`, `core/pipeline/runner.sh`, and several pr-open tests in scope (steps 5–6).
After reading each file: pr-delivery's `auto_unless_flagged` gate (`plugin.sh:161`) and merge's guard
already behave correctly when `ZBUILD_RUN_FLAGGED=yes`. Runner.sh does not condition on `_ZB_MAP_UNFINISHED`
for run-stopping; it reads it only for warning banners. No code changes are needed in those files; they
are in the scope block for review verification.

**Plan step-2 test files.** The plan named `pr-delivery-v2-result-test.sh`, `merge-v2-result-test.sh`,
`pr-open-v2-result-test.sh`, `pr-open-v2-inputs-test.sh`, and `pr-open-test.sh`. These tests set
`ZBUILD_RUN_FLAGGED` externally to probe the delivery plugins' own behavior; they do not exercise map.sh.
They are included in scope for verification that the fix does not break them, but require no new
assertions: the delivery behavior they test is unchanged.

**`map-members-reported-test.sh`.** MR4/MR5 exercise the `timed_out` scenario through `_strategy_run_map`
and check the group banner. After the fix, `ZBUILD_RUN_FLAGGED=yes` will be set in this scenario.
Adding an MR7 assertion there would be additional coverage, but SPEC-1's primary test
(`engine-combines-map-test.sh`) already covers the same code path. The integration test is in scope
for verification; an MR7 assertion is optional for the implementer.
