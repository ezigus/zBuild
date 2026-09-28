# Design: close the timed_out disposition SPEC gap in monitor (v2 migration, #1847)

## Summary

**Goal.** Finish the monitor plugin's migration to result-contract v2 (ADR-054
§6 / ADR-063 §3): every terminal path out of `_monitor_stage_run_inner` must
write a disposition from the closed vocabulary
(`core/pipeline/disposition.sh:_ZBUILD_DISPOSITION_SET`), and the two
budget-exhaustion cases the router can report — turn-budget (rc=10) and
wall-clock (rc=124) — must be named explicitly, not inferred.

**Context.** The prior iteration (commit `8263b7b2`) already migrated the
primary artifact to `result_contract:2` and gave `rc=130` (signal) and `rc=10`
(turn-budget) their own dedicated branches, each writing a named disposition
directly (`interrupted`/`signal_interrupt`, `out_of_turns`/`budget_exhausted`).
`rc=124` (wall-clock timeout, ADR-063 §3's `timed_out` case) has **no dedicated
branch** — it falls through to the generic `rc -ne 0` tail, which derives a
disposition via `_router_rc_classify` + `router_reason_disposition`. Tracing
that path by hand confirms it *currently* resolves correctly (`router_timeout`
→ `timed_out`), so the visible defect is not a wrong answer — it's that `rc=124`
is the only one of the three ADR-063 §3 sentinel codes (130, 10, 124) not
given a self-contained, direct branch. That asymmetry is exactly the
"SPEC gap" the issue plan names, and it matters beyond style: the generic tail
also reads `_ROUTE_LAST_BUDGET_EXHAUSTED`, an unrelated global set by the
turn-budget detector (`router-rc-classify.sh`), so `rc=124`'s classification
is not self-contained the way `rc=130` and `rc=10` are — it depends on state
a neighboring branch can set. The prior run's acceptance-gate reported
`negctl_error:timeout` for SPEC-8/9/23/24/25 (the five [change] SPECs this
contract added); test and issue-acceptance are marked context-only in this
stage's inputs, so this design does not diagnose that infra signal further,
but removing the shared-state dependency for `rc=124` removes one concrete
source of cross-case indeterminism in that same code path.

**Decision.** Add a fourth dedicated branch, `if [[ "$rc" -eq 124 ]]`,
positioned with the existing `rc -eq 130` / `rc -eq 10` branches and before the
generic `rc -ne 0` tail. It writes `disposition:timed_out`,
`reason:router_timeout` directly via `_monitor_write_result`, mirroring the
rc=10 branch's shape exactly (same stage-summary wording pattern, same
`return 1`). The generic tail remains unchanged and still owns every other
non-zero rc (rate limits, OOM-kill, config errors, unrecognized errors) — this
does not touch `_router_rc_classify` or `router_reason_disposition`, both of
which stay correct and are still exercised by the generic path. No manifest,
schema, or disposition-vocabulary change: `timed_out` is already a member of
`_ZBUILD_DISPOSITION_SET` (`core/pipeline/disposition.sh`) and already wired
into `disposition_response`/`disposition_retryable`/`disposition_unfinished`.
This is a same-file, same-function, one-branch addition — no new abstraction,
no plugin-visible contract change, and the four ADR-063 §3 outcomes
(complete / interrupted / out_of_turns / timed_out) now share one shape: named
rc, direct write, no shared mutable state.

## Scope

```scope
plugins/agent/monitor/plugin.sh
plugins/agent/monitor/manifest.yaml
plugins/agent/monitor/tests/fixtures/monitor-report-v1-baseline.json
tests/unit/monitor-v2-result-test.sh
scripts/lib/router-rc-classify.sh
core/pipeline/disposition.sh
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-047-stage-agnostic-mechanics.md
```

Rationale for each entry beyond the seed:
- `manifest.yaml` — declares `provides.result_contract: 2` and
  `config.router {timeout_s:300, max_turns:10}` that the budget-guidance
  helpers and SPEC-8/9 read; unchanged by this design but load-bearing context
  for the branch being added.
- `router-rc-classify.sh` — owns `_router_rc_classify` /
  `router_reason_disposition`, the mapping the new branch bypasses for rc=124
  specifically; unchanged, but any future edit to the `124` case there must
  stay consistent with the new direct branch's literal `timed_out`/
  `router_timeout` pair.
- `disposition.sh` — the closed vocabulary `timed_out` is written into;
  confirmed already a member, unchanged.
- ADR-063/ADR-054/ADR-047 — the contract this change fulfills
  (§3 disposition naming, the closed-set rule, and the artifact-required-on-
  every-exit-path rule respectively). No prose changes needed; both already
  describe this behavior correctly.

No other file enumerates monitor's rc branches, the disposition set, or a
stage-count/roster this change grows — `timed_out`/`out_of_turns` are already
present in every enumeration site found (`disposition.sh`'s
`_ZBUILD_DISPOSITION_SET`, `disposition_response`, `disposition_unfinished`;
`router_reason_disposition`'s case statement). This change adds a code path,
not a new vocabulary member, so ADR-032/033's absence-by-omission scan finds
no additional enumeration site to update.

## Acceptance

```acceptance
SPEC-23[change]: router rc=124 (wall-clock timeout) is handled by monitor_stage_run's own dedicated branch — not the generic rc!=0 fallback — and writes disposition:timed_out, reason:router_timeout, returning rc=1 (never the raw rc=124)
SPEC-24[guard]: router rc=10 (turn-budget exhaustion) continues to write disposition:out_of_turns, reason:budget_exhausted via its own dedicated branch, returning rc=1
SPEC-8[guard]: the assembled monitor prompt contains a TURN BUDGET block reflecting the manifest's config.router.max_turns
SPEC-9[guard]: the assembled monitor prompt contains a WALL CLOCK BUDGET block reflecting the manifest's config.router.timeout_s
SPEC-25[guard]: for a live passing run, the v2 monitor-report.json's carried-over health-assessment fields (verdict, data.summary, data.checks) are byte-identical to the pre-migration v1-shaped baseline fixture
WIRING:
plugins/agent/monitor/plugin.sh
TESTFILES:
SPEC-23: tests/unit/monitor-v2-result-test.sh
SPEC-24: tests/unit/monitor-v2-result-test.sh
SPEC-8: tests/unit/monitor-v2-result-test.sh
SPEC-9: tests/unit/monitor-v2-result-test.sh
SPEC-25: tests/unit/monitor-v2-result-test.sh
```

Reclassification notes (ADR-036 tautology check, re-derived from code, not
from the prior run's labels):

- **SPEC-23 stays `[change]`.** Traced by hand against the merge-base
  (`420e7964`) plugin.sh: the v1 code has no `disposition` field at all, so
  `jq -r '.disposition // empty'` on that baseline's report yields `""`, which
  fails the assertion's `"timed_out"` expectation — a genuine baseline
  failure, not a tautology. At HEAD, whether via the generic tail (today) or
  the new dedicated branch (after this change), the assertion passes. The
  *behavior* SPEC-23 asserts (rc=124 → `timed_out`/`router_timeout`) was
  already true before this design at HEAD; what changes is *how* — a direct,
  self-contained branch instead of a shared-state-dependent fallback. Kept
  `[change]` because the assertion's pass/fail still flips cleanly at the
  merge-base boundary, and the new assertion text ("handled by its own
  dedicated branch") is meaningfully different code-shape from the fallback it
  replaces.
- **SPEC-24, SPEC-8, SPEC-9, SPEC-25 are re-tagged `[guard]`, down from the
  prior round's classification.** Each already holds at HEAD *and* the
  behavior they assert was introduced by the already-merged commit
  `8263b7b2` (rc=10 branch, budget-guidance helpers) or `887c1f4c` (the
  baseline fixture) — nothing in this design's scope changes their code paths.
  Re-verified against merge-base: all four fail there for the same real
  reason SPEC-23 does (no `disposition` field, no budget-guidance helper
  calls, no v1 fixture to diff against pre-migration shape), so they are
  correctly-shaped assertions — they are just not *this* design's `[change]`,
  since this design's only code edit is the SPEC-23 branch. Carrying them as
  invariants protects against this change regressing the already-shipped
  rc=10/budget-block/golden-diff behavior while it edits the adjacent rc=124
  path in the same function.

No tautological SPEC survives in this contract: every SPEC above fails at
merge-base and passes at HEAD-after-this-change for the reason its
description states, and each classification matches whether *this* round's
diff is what makes it pass (`[change]`) or whether it already passed before
this round's diff and must not regress (`[guard]`).
