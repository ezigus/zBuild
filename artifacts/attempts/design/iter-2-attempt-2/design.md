# Design: close the timed_out disposition SPEC gap in monitor (v2 migration, #1847)

## Summary

**Goal.** Finish the monitor plugin's migration to result-contract v2 (ADR-054
§6 / ADR-063 §3): the rc=124 (wall-clock timeout) exit path must name its
disposition (`timed_out`) and reason (`router_timeout`) the same way every
other budget/router-failure path does — derived from the shared
`_router_rc_classify` → `router_reason_disposition` chokepoint, never a
hand-copied literal. The rc=8/9 budget-guidance numbers in the prompt must
likewise be provably sourced from `_route_resolve_max_turns`/
`_route_resolve_timeout`, not read from the manifest by a second path.

**Context — revised from the prior iteration.** Tracing the CURRENT plugin.sh
(committed at `8263b7b2`, already on this branch) shows the code is already
correct:
- Lines 169–170 call `_route_resolve_max_turns` / `_route_resolve_timeout`
  and feed the results straight into `_monitor_budget_guidance` /
  `_monitor_wallclock_guidance`, which build the TURN BUDGET / WALL CLOCK
  BUDGET prompt blocks (lines 172–179). No manifest value is read a second
  time.
- The generic `rc -ne 0` tail (lines 215–227) already calls
  `_router_rc_classify` then `router_reason_disposition`. For rc=124,
  `_router_rc_classify`'s own `124)` case (`scripts/lib/router-rc-classify.sh:704`
  area, case statement ~line 134) sets reason=`router_timeout` unconditionally
  from the case statement — it does not depend on `_ROUTE_LAST_BUDGET_EXHAUSTED`
  (that global is checked *before* the case, but is reset to `0` at the top of
  every real `route_to_model` call in `core/router/route.sh:117`, and the
  test harness's mock `route_to_model()` never touches it — so there is no
  cross-test leak in practice). `router_reason_disposition("router_timeout")`
  returns `timed_out`. **The rc=124 → `timed_out` mapping the issue asks for
  already exists and is already correctly derived — no dedicated branch, no
  hand-copied literal.**

This reverses the prior iteration's decision to add a fourth dedicated
`rc -eq 124` branch that wrote `disposition:timed_out` as a literal string
"mirroring the rc=10 branch's shape." Per `plan.json` step 2, that is exactly
the wrong move: *"Keep the mapping fully derived from `router_reason_disposition`;
no literal disposition strings beyond what already exists."* A new literal
branch would have made the disposition *less* derived, not more — moving a
correctly-classified case out of the shared chokepoint and into a hand-copy,
the opposite of what ADR-063 §3 asks for.

**The real gap spec-coverage found is in the TEST, not the code.** SPEC-8/9
today only assert that the manifest's literal numbers (`10`, `300`) appear in
the prompt with all router env overrides unset. A plugin that hand-read
`config.router.max_turns` from the manifest YAML directly — bypassing
`_route_resolve_max_turns` entirely — would pass that assertion identically.
Likewise SPEC-23 only asserts the final string `timed_out`/`router_timeout`;
a hand-copied `disposition:"timed_out"` literal (exactly what the prior
iteration proposed adding) would pass it just as well as the real derived
path does. Neither assertion can tell "genuinely derived" apart from
"coincidentally matches." That is the uncovered claim spec-coverage named.

**Decision.** No further plugin.sh changes. Strengthen SPEC-8, SPEC-9, and
SPEC-23 to a stub/sentinel seam proof — the same technique already used
elsewhere in this codebase for exactly this purpose (SPEC-22 in this same
test file stubs `template_stage_router_timeout`/`_max_turns` and checks
`_route_resolve_timeout`/`_route_resolve_max_turns`'s return;
`tests/unit/design-budget-prompt-injection-test.sh` SPEC-6/7 stub the same
two resolver functions to sentinel values `777`/`99` and assert the *prompt*
echoes the stub, not the manifest; `tests/unit/router-reason-disposition-test.sh`
SPEC-1 exercises `router_reason_disposition` in isolation). Applying the same
pattern here:
- SPEC-8/SPEC-9: stub `_route_resolve_max_turns`/`_route_resolve_timeout` to
  return sentinel values that diverge from the manifest's `10`/`300`
  (e.g. `77`/`321`, mirroring the divergence discipline SPEC-22 already
  enforces at lines 473–479 of the test file), run `monitor_stage_run`, and
  assert the TURN BUDGET / WALL CLOCK BUDGET prompt blocks contain the
  **stub** value, not the manifest literal. This can only pass if the prompt
  is actually built from the resolver's return value.
- SPEC-23: stub `router_reason_disposition` to return a distinguishing
  sentinel string (e.g. `SENTINEL_TIMED_OUT`) when called with argument
  `router_timeout`, drive `monitor_stage_run` with `MOCK_ROUTE_RC=124`, and
  assert the written `monitor-report.json`'s `.disposition` equals the
  **sentinel**, not the hand-guessable string `"timed_out"`. `reason` stays a
  literal-value assertion (`router_timeout`) because that word is
  `_router_rc_classify`'s own case-statement output — the rc→reason mapping,
  not the reason→disposition derivation this SPEC exists to prove — and is
  already covered by `tests/unit/router-reason-disposition-test.sh` SPEC-1.

**SPEC-24 (rc=10/`out_of_turns`/`budget_exhausted`) deliberately stays
untouched, literal-checked, and `[guard]`.** Investigation
(`grep -rn budget_exhausted`) shows `reason:budget_exhausted` paired with
`disposition:out_of_turns` is an established, hand-written literal pair
shared verbatim by `plugins/agent/review-lens/plugin.sh:307` and asserted the
same way by its own test (`review-lens-v2-budget-test.sh:197-198`). It is a
deliberate, cross-plugin convention for the turn-budget short-circuit path —
not something this design should retrofit through `router_reason_disposition`
(whose case statement recognizes `router_out_of_turns`/`max_iterations`, not
`budget_exhausted`, confirming the two paths are intentionally independent).
Redefining it here would silently change an already-shipped, multi-plugin
reason string outside this issue's scope. The ADR-063 §3 "derived, not
hand-copied" requirement applies to the *new* rc=124 gap this issue closes;
it does not retroactively obligate the pre-existing, sibling-shared rc=10
convention.

**SPEC-25** was not named in spec-coverage's findings and is unchanged.

No manifest, schema, or disposition-vocabulary change. `timed_out` was
already a member of `_ZBUILD_DISPOSITION_SET`
(`core/pipeline/disposition.sh`) before this issue and remains so.

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
- `plugin.sh` — the WIRING/reachability target; this round's diff to it may
  be zero lines (the code was already correct), but it remains the file
  whose presence connects rc=124 to the disposition chokepoint, and the
  acceptance-gate's revert-to-merge-base check still exercises it correctly
  (reverting it removes the entire v2 disposition machinery, flipping every
  SPEC-n TESTFILE).
- `manifest.yaml` — declares `config.router {timeout_s:300, max_turns:10}`,
  the literal value SPEC-8/9's sentinel-divergence check is defined against;
  unchanged, but load-bearing context for choosing sentinel values that must
  not collide with it.
- `router-rc-classify.sh` — owns both `_router_rc_classify`'s rc→reason
  case statement (confirmed: `124` → `router_timeout`, unconditionally, not
  gated on `_ROUTE_LAST_BUDGET_EXHAUSTED`) and `router_reason_disposition`'s
  reason→disposition case statement (confirmed: `router_timeout` →
  `timed_out`; `router_out_of_turns`/`max_iterations` → `out_of_turns`, a
  different reason string than monitor's rc=10 literal `budget_exhausted`).
  Unchanged; this design's SPEC-23 seam test asserts against it by stubbing
  one of its two functions.
- `disposition.sh` — the closed vocabulary `timed_out`/`out_of_turns` are
  written into; confirmed already members, unchanged.
- ADR-063/ADR-054/ADR-047 — the contract this change fulfills (§3
  disposition naming via the shared chokepoint, the closed-set rule, and the
  artifact-required-on-every-exit-path rule respectively). No prose changes
  needed; all three already describe this behavior correctly.

No other file enumerates monitor's rc branches, the disposition set, or a
stage-count/roster this change grows — this round adds no new disposition
vocabulary member and no new plugin.sh branch, only a stronger proof
technique in the existing test. `plugins/agent/review-lens/plugin.sh` and its
test are cited above as evidence for the SPEC-24 scoping decision but are
NOT touched, invalidated, or asserted about by this change and are
deliberately excluded from scope.

## Acceptance

```acceptance
SPEC-23[change]: router rc=124 (wall-clock timeout) is classified through the shared _router_rc_classify → router_reason_disposition chokepoint, never a hand-copied literal — proven by stubbing router_reason_disposition to return a distinguishing sentinel for argument "router_timeout" and asserting monitor_stage_run's written monitor-report.json .disposition equals that sentinel (not a hardcoded "timed_out"); reason is "router_timeout" (from _router_rc_classify's own rc=124 case); monitor_stage_run returns rc=1 (never the raw rc=124)
SPEC-24[guard]: router rc=10 (turn-budget exhaustion) continues to write the established literal pair disposition:out_of_turns, reason:budget_exhausted via its own dedicated branch (the same convention plugins/agent/review-lens/plugin.sh uses, intentionally not routed through router_reason_disposition), returning rc=1
SPEC-8[change]: the assembled monitor prompt's TURN BUDGET block reflects the value _route_resolve_max_turns returns at call time, not a value read a second way from the manifest — proven by stubbing _route_resolve_max_turns to a sentinel (e.g. 77) that diverges from the manifest's max_turns:10 and asserting the prompt echoes the sentinel, not 10
SPEC-9[change]: the assembled monitor prompt's WALL CLOCK BUDGET block reflects the value _route_resolve_timeout returns at call time, not a value read a second way from the manifest — proven by stubbing _route_resolve_timeout to a sentinel (e.g. 321) that diverges from the manifest's timeout_s:300 and asserting the prompt echoes the sentinel, not 300
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
from the prior round's labels):

- **SPEC-23 stays `[change]`.** At the merge-base (`420e7964`, pre-migration
  main), the plugin writes no `disposition` field at all — the sentinel-seam
  assertion fails there for the honest reason ("no such field / stub never
  called"), and passes at HEAD because the real derivation chain exists.
  Strengthened from a bare string check to the sentinel-stub proof per
  spec-coverage's finding; the classification itself is unchanged.
- **SPEC-8 and SPEC-9 are promoted back to `[change]`** (the prior round had
  filed them `[guard]`). Per the literal classification rule — "fails at
  merge-base, passes at HEAD" — both do: pre-migration monitor.plugin.sh
  builds no TURN BUDGET / WALL CLOCK BUDGET block at all, so the sentinel
  assertion fails there for a real reason and passes at HEAD. The prior
  round's `[guard]` tag rested on "this round's diff didn't add the code,"
  which is not the rule's test; the rule asks only whether the behavior
  exists at merge-base, and it does not. Re-tagging avoids skipping the
  negative control for a behavior that in fact should have one.
- **SPEC-24 and SPEC-25 stay `[guard]`, unchanged from the prior round.**
  SPEC-24: the rc=10 literal pair is a pre-existing, cross-plugin convention
  this design deliberately does not touch (see Summary); re-verified it
  fails at merge-base for the same real reason (no disposition field) but is
  not *this* SPEC's derivation claim to prove — the claim it protects is "the
  established literal pair still holds," an invariant, not a new behavior
  this round introduces. SPEC-25: unchanged from prior round, not named by
  spec-coverage, golden-fixture behavior already shipped by `887c1f4c`.

Every SPEC above fails at merge-base and passes at HEAD-after-this-change for
the reason its description states. The classification change (SPEC-8/9 to
`[change]`) corrects a rule misapplication, not a new tautology; the
assertion strengthening (SPEC-8/9/23 to stub/sentinel proofs) is the direct
answer to spec-coverage's uncovered-claim findings.

## Unfinished / named gaps

None — investigation completed within budget. One residual risk worth
naming for the build stage: sentinel values chosen for SPEC-8/9 (`77`/`321`)
and SPEC-23 (`SENTINEL_TIMED_OUT`) must not collide with any other digit
sequence already present in the assembled prompt (role line mentions the run
ID; deploy/PR blocks are typically absent in this test's fixtures) — build
should re-verify no collision before relying on a bare `grep` inside the
captured block, matching SPEC-22's own divergence check at lines 473–479.
