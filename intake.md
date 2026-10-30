[bug] a review lens that does not finish counts as a failure — the run stops; it may merge only when every lens finishes and passes

## Decision

**A review lens that times out, or does not finish for any reason, counts as a failure.**
- If any lens fails or does not finish, the run stops (a hard stop): no PR is opened, nothing merges, and the lens is not retried. This holds even if every other lens passed.
- Only when **every** lens finishes and passes may the run merge.

## What is wrong today

- `_map_write_summary` (`core/pipeline/strategies/map.sh`) sets `ZBUILD_RUN_FLAGGED=yes` only when a lens's outcome is `fail`, and sets `no` otherwise. A lens that timed out, ran out of turns, broke, or left no result therefore counts as "no problem found".
- With all six lenses timed out, `ZBUILD_RUN_FLAGGED=no`, and pr-delivery (`plugins/agent/pr-delivery/plugin.sh`, `auto_unless_flagged`, simple.yaml's `merge_policy`) auto-merges a change nobody reviewed.
- The run already notices: `_ZB_MAP_UNFINISHED` and the status comment's "K of N lenses did not finish". But that only warns; nothing acts on it.
- ADR-040's #2368-part-2 amendment specifies today's behaviour ("`no` when none did"), so the ADR changes too.

## ADR

- **Amend ADR-040**, the #2368-part-2 amendment ("The engine sums up a map group"):
  - a review element that did not finish counts as failed;
  - a review group with any failed or unfinished element is a failed stage and the run stops (ADR-069);
  - the run may merge only when every element finished and passed.
- ADR-040 is in `config/adr-enforcement-baseline.txt`, so the amendment names its enforcing tests inline ("Enforced by: …").
- ADR-064 §4: the status comment names each unfinished lens and its outcome. That already exists; keep it.

"Did not finish" means any element outcome other than `pass` or `fail`, or an element with no current result (`stage_result_is_current`, ADR-068 §8).

## Required behavior

Write each as a test first and watch it fail.

- **R1.** All six lenses finish with `timed_out`, `out_of_turns`, `broken` or no result. The review group fails, the run stops before `pr_open`, no PR is opened, and nothing merges.
- **R2.** Five lenses pass and one is `timed_out`. Same result as R1. The run's log and status comment say "1 of 6 lenses did not finish: <lens> (timed_out)".
- **R3.** One lens's outcome is `fail`. The run stops, no PR is opened, and nothing merges.
- **R4.** Every lens finishes and passes. The run proceeds to `pr_open` and may merge under `auto_unless_flagged`.
- **R5.** A lens that did not finish is not re-run.

## Scope

- **Code:** `core/pipeline/strategies/map.sh` (`_map_write_summary`, the group's outcome), `core/pipeline/runner.sh` (the `map:*` dispatch case), `plugins/agent/pr-delivery/plugin.sh` and `plugins/tool/merge/plugin.sh` (only if the flag's meaning changes for them).
- **ADR:** `docs/adr/ADR-040-composable-gate-lens-taxonomy.md`.
- **Tests that pin today's behaviour:**
  - `tests/unit/engine-combines-map-test.sh` (M1, M2)
  - `tests/integration/map-members-reported-test.sh` (MR4–MR6)
  - `tests/integration/merge-policy-auto-unless-flagged-test.sh`
  - `tests/unit/pr-delivery-v2-result-test.sh`
  - `tests/unit/merge-v2-result-test.sh`
  - `tests/unit/pr-open-v2-result-test.sh`, `tests/unit/pr-open-v2-inputs-test.sh`, `plugins/tool/pr-open/tests/pr-open-test.sh`

  Run `grep -rl 'ZBUILD_RUN_FLAGGED' tests/ plugins/` and include every match.
- **Out of scope:** retrying a lens; lens time limits.
