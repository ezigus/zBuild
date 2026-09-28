# Design: close the timed_out disposition SPEC gap in monitor (v2 migration, #1847)

## Summary

**Goal.** Finish the monitor plugin's migration to result-contract v2 (ADR-054
§6 / ADR-063 §3): the rc=124 (wall-clock timeout) exit path must name its
disposition (`timed_out`) and reason (`router_timeout`) the same way every
other budget/router-failure path does — derived from the shared
`_router_rc_classify` → `router_reason_disposition` chokepoint, never a
hand-copied literal.

**Context — unchanged from the prior iteration.** Tracing the CURRENT
plugin.sh (committed at `8263b7b2`) shows the rc=124 → `timed_out` mapping
the issue asks for already exists and is already correctly derived through
the shared chokepoint — no dedicated branch, no hand-copied literal. No
further plugin.sh change is needed; build already confirmed this (0 files
changed, 1 iteration).

**This round's actual gap: spec-coverage, not code.** spec-coverage failed
this run with two "NOT COVERED" items pulled from the issue's original
acceptance checklist:

1. *"router budgets resolve from the manifest with template override still
   winning"*
2. *"manifest declares a `primary: true` output"*

Both behaviors are pre-existing (unchanged at merge-base) and both are
**already exercised** in `tests/unit/monitor-v2-result-test.sh` — just not
declared in this design's acceptance block, so the acceptance-gate has no
`[#1847/SPEC-n]` tag to look for and nothing to report as met:

- **Router-budget-precedence**: SPEC-22 (lines 468–499) stubs
  `template_stage_router_timeout`/`_max_turns` to sentinel values (`111`/
  `12`) that diverge from the manifest's own `timeout_s:300`/`max_turns:10`,
  and asserts `_route_resolve_timeout`/`_route_resolve_max_turns` return the
  **stub**, proving the template accessor still outranks monitor's manifest
  `config.router` block — the exact "template override still winning"
  guarantee spec-coverage flagged as unproven. (The general precedence rule
  — template > env > manifest > constant — is engine-owned and proven
  target-agnostically in `tests/unit/router-manifest-budget-test.sh` SPEC-4;
  SPEC-22 is the monitor-specific instance confirming monitor doesn't bypass
  that machinery.)
- **`primary:true` output**: SPEC-15 (lines 118–133) already asserts the
  manifest declares exactly one `primary:true` output and that it is
  `monitor_report`.

Neither block currently carries a `[#1847/SPEC-n]` label in its assertion
text (confirmed by grep — SPEC-8/SPEC-9/SPEC-23/SPEC-24 already do, SPEC-15/
SPEC-22 do not). That is the mechanical reason the acceptance-gate has
nothing to report: `TESTFILES` in this design's own acceptance block never
named them, so no tag was ever requested. **Decision: declare SPEC-15 and
SPEC-22 in this design's acceptance block as `[guard]`s**, so test-author
adds the `[#1847/SPEC-n]` tag to their existing assertion labels (no new
assertion logic needed — the proof already exists and already exercises the
right seam). Do not touch `router-manifest-budget-test.sh`; its own tags
belong to #1816, not this issue.

**SPEC-8/SPEC-9/SPEC-23/SPEC-24/SPEC-25 are unchanged from the prior
iteration** — same text, same classification, same TESTFILES. Their
underlying content (the sentinel-stub proof for SPEC-8/9/23, the literal-pair
guard for SPEC-24, the golden-diff guard for SPEC-25) is still the correct
answer to the tautology concern raised two rounds ago; nothing in this
round's stage summaries contradicts that reasoning.

**On the acceptance-gate's `negctl_error:timeout` across all five declared
SPECs, and the separate `tests/integration/state-root-isolation-test.sh`
failure**: neither is a correctness finding about this design. The negctl
timeout is an infra-level failure to complete the revert-and-rerun check at
all (not a assertion pass/fail), consistent with this repo's known negctl
flake pattern under load (see plan.json's own caveat about run 23575 hitting
the same `negctl_error:timeout` pattern near an `llm_rate_limited` abort).
The integration-suite failure is in a nested-run/state-root-isolation
fixture unrelated to monitor's disposition or budget-prompt behavior — it is
not touched, referenced, or enumerated by anything in this change's scope.
Both are named as unresolved risk below rather than acted on, since nothing
in this design can fix an infra timeout or an unrelated pre-existing
integration failure.

**SPEC-24 (rc=10/`out_of_turns`/`budget_exhausted`) stays untouched,
literal-checked, `[guard]`.** `reason:budget_exhausted` paired with
`disposition:out_of_turns` is an established, hand-written literal pair
shared verbatim by `plugins/agent/review-lens/plugin.sh:307` and its own
test. It is a deliberate, cross-plugin convention for the turn-budget
short-circuit path, intentionally independent of
`router_reason_disposition` (whose case statement recognizes
`router_out_of_turns`/`max_iterations`, not `budget_exhausted`). Out of
scope for this issue.

**SPEC-25** unchanged from prior round, not named by any stage summary this
round.

No manifest, schema, or disposition-vocabulary change. `timed_out` was
already a member of `_ZBUILD_DISPOSITION_SET`
(`core/pipeline/disposition.sh`) before this issue and remains so.

## Scope

```scope
plugins/agent/monitor/plugin.sh
plugins/agent/monitor/manifest.yaml
plugins/agent/monitor/tests/fixtures/monitor-report-v1-baseline.json
tests/unit/monitor-v2-result-test.sh
tests/unit/router-manifest-budget-test.sh
scripts/lib/router-rc-classify.sh
core/pipeline/disposition.sh
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-047-stage-agnostic-mechanics.md
```

Rationale for entries added this round:
- `router-manifest-budget-test.sh` — referenced (not modified) as the
  engine-level proof that the template>env>manifest>constant precedence
  rule this design's SPEC-22 relies on is real and target-agnostic (#1816
  SPEC-4). Included for traceability only; its own `#1816` tags are not
  this issue's to change.

All other scope entries and their rationale are unchanged from the prior
iteration: `plugin.sh` is the WIRING/reachability target (this round's diff
to it is again zero lines); `manifest.yaml` declares the `10`/`300`
literals SPEC-8/9's sentinel divergence is chosen against, and the single
`primary:true` output SPEC-15 asserts; `router-rc-classify.sh` owns both
case statements SPEC-23's seam test stubs against; `disposition.sh` is the
closed vocabulary `timed_out`/`out_of_turns` are drawn from; the three ADRs
state the contract being fulfilled, unchanged.

`plugins/agent/review-lens/plugin.sh` and its test remain cited as evidence
for the SPEC-24 scoping decision but are NOT touched, invalidated, or
asserted about by this change and are deliberately excluded from scope.

## Acceptance

```acceptance
SPEC-23[change]: router rc=124 (wall-clock timeout) is classified through the shared _router_rc_classify → router_reason_disposition chokepoint, never a hand-copied literal — proven by stubbing router_reason_disposition to return a distinguishing sentinel for argument "router_timeout" and asserting monitor_stage_run's written monitor-report.json .disposition equals that sentinel (not a hardcoded "timed_out"); reason is "router_timeout" (from _router_rc_classify's own rc=124 case); monitor_stage_run returns rc=1 (never the raw rc=124)
SPEC-24[guard]: router rc=10 (turn-budget exhaustion) continues to write the established literal pair disposition:out_of_turns, reason:budget_exhausted via its own dedicated branch (the same convention plugins/agent/review-lens/plugin.sh uses, intentionally not routed through router_reason_disposition), returning rc=1
SPEC-8[change]: the assembled monitor prompt's TURN BUDGET block reflects the value _route_resolve_max_turns returns at call time, not a value read a second way from the manifest — proven by stubbing _route_resolve_max_turns to a sentinel (e.g. 77) that diverges from the manifest's max_turns:10 and asserting the prompt echoes the sentinel, not 10
SPEC-9[change]: the assembled monitor prompt's WALL CLOCK BUDGET block reflects the value _route_resolve_timeout returns at call time, not a value read a second way from the manifest — proven by stubbing _route_resolve_timeout to a sentinel (e.g. 321) that diverges from the manifest's timeout_s:300 and asserting the prompt echoes the sentinel, not 300
SPEC-25[guard]: for a live passing run, the v2 monitor-report.json's carried-over health-assessment fields (verdict, data.summary, data.checks) are byte-identical to the pre-migration v1-shaped baseline fixture
SPEC-22[guard]: monitor's own template accessors (template_stage_router_timeout, template_stage_router_max_turns) continue to outrank monitor's own manifest config.router block when resolving turn/wall-clock budgets — proven by stubbing both accessors to sentinel values that diverge from the manifest's timeout_s:300/max_turns:10 and asserting _route_resolve_timeout/_route_resolve_max_turns return the stub, not the manifest value; this is monitor's instance of the engine-wide template>env>manifest>constant precedence rule (#1816), which monitor must not silently bypass
SPEC-15[guard]: monitor's manifest declares exactly one primary:true output, and it is monitor_report
WIRING:
plugins/agent/monitor/plugin.sh
TESTFILES:
SPEC-23: tests/unit/monitor-v2-result-test.sh
SPEC-24: tests/unit/monitor-v2-result-test.sh
SPEC-8: tests/unit/monitor-v2-result-test.sh
SPEC-9: tests/unit/monitor-v2-result-test.sh
SPEC-25: tests/unit/monitor-v2-result-test.sh
SPEC-22: tests/unit/monitor-v2-result-test.sh
SPEC-15: tests/unit/monitor-v2-result-test.sh
```

Reclassification / re-declaration notes (ADR-036 tautology check, re-derived
from code, not from the prior round's labels):

- **SPEC-22 and SPEC-15 are newly declared this round, both `[guard]`.**
  Both assertions already exist in `tests/unit/monitor-v2-result-test.sh`
  (SPEC-22 at lines 468–499, SPEC-15 at lines 118–133) from an earlier
  design iteration of this same migration, and both behaviors are
  pre-existing — true at merge-base and unchanged by this issue — so
  `[change]` would be a misclassification; `[guard]` is correct and the
  acceptance-gate correctly skips the negative control for them. Declaring
  them here is what lets test-author add the `[#1847/SPEC-15]` and
  `[#1847/SPEC-22]` tags their assertion labels currently lack — the
  mechanical reason spec-coverage found both items "NOT COVERED" despite
  the proof already existing in the tree. No new assertion logic is
  required, only the tag.
- **SPEC-23/SPEC-24/SPEC-8/SPEC-9/SPEC-25**: unchanged from the prior
  round's classification and reasoning. Every SPEC above fails at
  merge-base and passes at HEAD-after-this-change for the reason its
  description states, except the two `[guard]`s (SPEC-24, SPEC-25, SPEC-22,
  SPEC-15), which are invariants that were already true at merge-base and
  must not regress.

## Unfinished / named gaps

- **Acceptance-gate `negctl_error:timeout` on all five previously-declared
  SPECs (8/9/23/24/25) this run.** This is an infra-level failure to
  complete the revert-and-rerun negative control, not an assertion
  pass/fail — no SPEC's content is implicated. plan.json's own notes record
  the same `negctl_error:timeout` pattern recurring near an
  `llm_rate_limited` abort in a prior run of this same issue, consistent
  with this repo's known negctl-under-load flake. Not actionable at the
  design level; flagging for the next build/test cycle to retry and, if it
  reproduces outside a rate-limit window, escalate as its own infra
  investigation.
- **`tests/integration/state-root-isolation-test.sh` failure** (nested-run
  nested-suite fixture roster mismatch) is unrelated to monitor's
  disposition/budget-prompt behavior — it references no file in this
  design's scope and is not caused by 0-line plugin.sh changes. Left out of
  scope as pre-existing/unrelated; noting it here so it isn't silently
  dropped from the stage record.
- SPEC-8/SPEC-9's sentinel values (`77`/`321`) and SPEC-23's sentinel
  (`SENTINEL_TIMED_OUT`) must not collide with any other digit sequence
  already present in the assembled prompt, matching SPEC-22's own
  divergence check (lines 473–479). Build should re-verify no collision
  before relying on a bare `grep` inside the captured block.
