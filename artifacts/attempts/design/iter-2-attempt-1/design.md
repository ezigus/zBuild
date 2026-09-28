# Design — Close the timed_out disposition SPEC gap in monitor (#1847)

## 1. Summary

**Goal.** Prove that `plugins/agent/monitor` fully honors ADR-063 for its v2
migration: §1 (budget reaches the prompt from the enforcing value) and §3
(disposition split — `timed_out` for a wall-clock timeout vs `out_of_turns`
for a turn-budget hit), since #1847's own migration currently proves §1 only
by block-presence and proves §3 only for the turn-budget half.

**Context.** `plugin.sh` (HEAD 8263b7b2) and `tests/unit/monitor-v2-result-test.sh`
(HEAD 115f5b5e) already carry the full v2 migration: manifest
`provides.result_contract: 2`, a v2 result on every exit path, and 22 SPECs.

**ADR-063 §1 (budget-disclosure) — already implemented and already tested.**
`plugin.sh:75-101` defines `_monitor_budget_guidance`/`_monitor_wallclock_guidance`,
wired into the prompt at `plugin.sh:167-179`, pulling their numbers from
`_route_resolve_max_turns`/`_route_resolve_timeout` (`core/router/route.sh:704,716`
— the same values the router itself enforces, never hand-copied). This is
tested today by **SPEC-8/SPEC-9** (`tests/unit/monitor-v2-result-test.sh:288-314`),
which assert the assembled prompt contains a TURN BUDGET block reflecting the
manifest's `max_turns:10` and a WALL CLOCK BUDGET block reflecting
`timeout_s:300`. The spec-coverage gate flagged §1 as uncovered because the
prior iteration of this design never named SPEC-8/SPEC-9 or traced §1 against
the code at all — the acceptance block below now cites them explicitly so the
design's own account of ADR-063 coverage is complete, not just the code.

ADR-063 §1 also asks for "one helper" shared across stages so the numbers are
never restated per-stage. That extraction does not exist yet — `plan` and
`impact` each have their own inline budget prose — but the ADR's own
Implementation Notes order this repo's adoption explicitly: `design` → the
advisory lenses → **`monitor`** → *then* "`plan` and `impact` — retrofit onto
§1's shared block" (step 4, after monitor). Building that shared extraction is
out of scope for #1847; monitor already satisfies §1's substance (pinned to
the enforcing value, present in the prompt, tested) via its own local
functions, matching how `design`/lenses were expected to land first.

ADR-063 §2 (partial deliverable form) needs no new field for monitor: `checks`
is already an unconstrained array (a short or empty list is a valid partial
answer), and per §3 the *signal* that an answer is partial is `disposition`
(timed_out/out_of_turns), not a new verdict value — monitor's schema
deliberately keeps `valid_verdicts` at exactly `[pass, degraded]` (SPEC-11,
unchanged). §2's "discriminating test" (ADR-063 Implementation Notes: "kill it
at its bound and assert the next attempt starts from something") is therefore
the same test as §3's, which SPEC-23/24 below cover; no separate SPEC is
needed and inventing one would test a behavior that is already true by
construction (the array has no minimum-length constraint), which the design
charter's own tagging rule (§0) forbids classifying as `[change]`.

**ADR-063 §3 gap (the reason this design exists).** Tracing every non-zero
exit of `monitor_stage_run` against the live code:

- rc=130 (signal) → the `_monitor_interrupt_handler` trap writes
  `disposition:interrupted` — proven by SPEC-6.
- rc=10 (turn-budget exhaustion) → a dedicated branch hardcodes
  `disposition:out_of_turns` — SPEC-21 exercises this branch but asserts
  only the rc=1 collapse and file existence, **never the disposition value**.
- any other non-zero rc (including 124) → the generic branch runs
  `_router_rc_classify` then `router_reason_disposition`. For rc=124,
  `_router_rc_classify` (`scripts/lib/router-rc-classify.sh:143`) sets
  `reason=router_timeout` (the `_ROUTE_LAST_BUDGET_EXHAUSTED` global that
  would otherwise short-circuit this is initialized to `0` at
  `core/router/route.sh:117` and is only ever set to `1` inside the real
  `route_to_model` body, which every SPEC in this file replaces wholesale —
  so it cannot leak into a mocked rc=124 run). `router_reason_disposition`
  then maps `router_timeout → timed_out` (`scripts/lib/router-rc-classify.sh:234`,
  and `core/pipeline/disposition.sh:18` confirms `timed_out`/`out_of_turns`
  are the current closed-set members — `exhausted` was retired by #2187
  precisely because it hid which budget ran out). **No SPEC exercises this
  path with rc=124 at all** — SPEC-4 only exercises it with rc=1 (→
  `unavailable`).

**Decision.** This is a test-coverage gap, not a runtime defect: by code
trace, `monitor_stage_run` already writes the correct word for both budgets,
already discloses both budgets to the model, and already carries a partial
signal on the engine's axis. Add the missing assertions rather than changing
`plugin.sh`:

1. A new SPEC mocking rc=124 and asserting `disposition:timed_out`,
   `reason:router_timeout`, run immediately alongside the existing rc=10 case
   so the two dispositions are provably distinct outputs of the same stage.
2. Strengthen SPEC-21's existing rc=10 block with the `disposition:out_of_turns`
   / `reason:budget_exhausted` assertions it never made.
3. A conditional, narrowly-scoped patch to `plugin.sh` — build only touches
   it if running the new SPEC first (red-run per this repo's test-first rule)
   reveals the trace above is wrong in some way not visible from static
   reading (e.g. bash version quoting, or a fixture that sets
   `_ROUTE_LAST_BUDGET_EXHAUSTED` some other way). No new disposition word is
   introduced either way — the fix, if any, only removes a bypass of
   `router_reason_disposition`, it never hand-copies a literal.
4. Deepen SPEC-3's "behavior is unchanged" field-presence check into a real
   golden-diff: a `monitor-report-v1-baseline.json` fixture plus a byte-level
   comparison of the carried-over `verdict`/`summary`/`checks` fields for a
   passing run, so the v2 migration is not just "yes there are dispositions"
   but "yes the pre-existing health-report shape it wraps is untouched".
5. No implementation change for §1/§2 — the acceptance block cites the
   pre-existing SPEC-8/SPEC-9 as guards so the design's stated ADR-063
   coverage for monitor is complete: §1 (SPEC-8/9), §2 (structural, argued
   above, no new SPEC), §3 (SPEC-6/21/23/24), §4 (engine-level, not
   monitor's — the acceptance-gate/response-table wiring lives in
   `core/pipeline/disposition.sh`, already a `retry` response for both words).

No manifest, template, or ADR change is required: `config/templates/deployed.yaml`
already wires `monitor` into the live pipeline, ADR-054 §6a already documents
`timed_out`/`out_of_turns` as the current vocabulary, and
`scripts/lib/lint-disposition-words.sh` already accepts both words as members
of `core/pipeline/disposition.sh`'s closed set.

## 2. Scope

```scope
plugins/agent/monitor/plugin.sh
plugins/agent/monitor/manifest.yaml
plugins/agent/monitor/tests/fixtures/monitor-report-v1-baseline.json
tests/unit/monitor-v2-result-test.sh
tests/unit/router-reason-disposition-test.sh
scripts/lib/router-rc-classify.sh
core/router/route.sh
core/pipeline/disposition.sh
scripts/lib/lint-disposition-words.sh
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
config/templates/deployed.yaml
```

Rationale for each non-seed file:

- `plugins/agent/monitor/manifest.yaml` — read to confirm `config.router`
  (`timeout_s:300`, `max_turns:10`) and `result_contract:2` are already
  correct (SPEC-1/7); these are also the numbers SPEC-8/9 assert appear in
  the prompt. In scope in case the conditional patch needs a manifest
  companion change, though none is currently expected.
- `tests/unit/router-reason-disposition-test.sh` — the existing unit test for
  `_router_rc_classify`/`router_reason_disposition` itself (asserts the
  `_ROUTE_LAST_BUDGET_EXHAUSTED` precedence rule at
  `scripts/lib/router-rc-classify.sh:48-60`). Read-reference only: it is the
  proof that the shared classifier already produces `router_timeout` for
  rc=124 outside of monitor, which the new monitor SPEC extends to monitor's
  own write path. Not expected to change.
- `scripts/lib/router-rc-classify.sh`, `core/router/route.sh` — source of the
  `_ROUTE_LAST_BUDGET_EXHAUSTED` global and the rc=124/rc=10 classification
  this design's SPECs assert against, AND the source of
  `_route_resolve_max_turns`/`_route_resolve_timeout` that §1's budget block
  is pinned to (`route.sh:704,716`). Read to verify both the no-leak claim in
  §1 and that monitor's budget numbers are not hand-copied. Not expected to
  change.
- `core/pipeline/disposition.sh` — owns the closed disposition set
  (`timed_out`, `out_of_turns` are members, `exhausted` retired #2187) and
  `disposition_unfinished`/the `retry` response table (ADR-063 §4); read to
  confirm both words are valid and both retry. Not expected to change.
- `scripts/lib/lint-disposition-words.sh` — CI lint that rejects any literal
  disposition word outside the closed set, including in
  `_monitor_write_result` calls; the new/strengthened SPECs must not trip it.
  Not expected to change.
- `docs/adr/ADR-054-stage-contract.md` §6a, `docs/adr/ADR-063-*.md` — the
  contract this design proves against; read to confirm the current
  (`timed_out`/`out_of_turns`) vocabulary is the one to test, and that §1/§2's
  adoption-order notes place monitor before the plan/impact shared-helper
  retrofit. Not expected to change (ADR-063's implementation-notes list
  already cites #1847/monitor as adoption step 3).
- `config/templates/deployed.yaml` — confirms monitor is already composed
  into the live pipeline (no wiring gap to fix). Not expected to change.

## 3. Acceptance

```acceptance
SPEC-8[guard]: the assembled monitor prompt contains a TURN BUDGET block reflecting the manifest's config.router.max_turns (ADR-063 §1), rendered by _monitor_budget_guidance from _route_resolve_max_turns — the same value the router enforces, never hand-copied. Pre-existing; re-cited here so this design's ADR-063 coverage account is complete.
SPEC-9[guard]: the assembled monitor prompt contains a WALL CLOCK BUDGET block reflecting the manifest's config.router.timeout_s (ADR-063 §1), rendered by _monitor_wallclock_guidance from _route_resolve_timeout. Pre-existing; re-cited here for the same reason as SPEC-8.
SPEC-23[guard]: router rc=124 (wall-clock timeout) causes monitor_stage_run to write disposition:timed_out and reason:router_timeout on monitor-report.json, derived via _router_rc_classify + router_reason_disposition (never a hand-copied literal) — distinct from the rc=10 disposition:out_of_turns case (SPEC-21/SPEC-24). Already true at merge-base by code trace (generic rc!=0 branch, no rc=124 special-case bypasses the classifier); tagged guard per the "check the tree" rule, not change.
SPEC-24[guard]: the existing rc=10 (turn-budget exhaustion) path (SPEC-21) additionally carries disposition:out_of_turns and reason:budget_exhausted on monitor-report.json — closing the assertion gap where SPEC-21 proved only the rc collapse to 1 and file existence, never the disposition/reason values.
SPEC-25[guard]: for a live passing run, the v2 monitor-report.json's carried-over health-assessment fields (verdict, data.summary, data.checks) are byte-identical to a pre-migration v1-shaped fixture (monitor-report-v1-baseline.json) once contract-v2-only fields (result_contract, disposition, reason) are excluded from the comparison — deepening SPEC-3's field-presence check into a real diff, proving the v2 migration wraps the health report without altering it.
WIRING: none
TESTFILES:
SPEC-8: tests/unit/monitor-v2-result-test.sh
SPEC-9: tests/unit/monitor-v2-result-test.sh
SPEC-23: tests/unit/monitor-v2-result-test.sh
SPEC-24: tests/unit/monitor-v2-result-test.sh
SPEC-25: tests/unit/monitor-v2-result-test.sh
```

**WIRING: none** — every SPEC here is `[guard]`: each protects a disposition
value, a prompt block, or a field shape that the already-migrated,
already-live-wired `monitor_stage_run` demonstrably produces today (SPEC-8/9
by direct code trace against the budget-guidance functions and their
call-sites; SPEC-23/24 by direct code trace against `plugin.sh`'s exit paths;
SPEC-25 against the unchanged `_monitor_write_result` call on the success
path). No new call-path, manifest key, or template composition is introduced
for the acceptance-gate to prove load-bearing. If build's red-run of SPEC-23
surfaces a real defect (contrary to the trace in §1) and a `plugin.sh` patch
becomes necessary, that patch only removes a bypass of the existing
`router_reason_disposition` call — it does not add a new call-path to wire
in, so WIRING remains `none`.

## 4. Named gaps

- I did not execute the test suite (`npm run test:unit` /
  `bash tests/unit/monitor-v2-result-test.sh`) — this stage is read-only and
  cannot run `Bash` for verification. The rc=124-maps-to-`timed_out` claim in
  §1 is a static trace, not an observed test result; per this repo's
  test-first rule the build stage must still run the new SPEC-23 red before
  treating the guard classification as settled, and re-tag to `[change]`
  if the trace turns out wrong. The same applies to the SPEC-8/SPEC-9 status
  claimed here as already-passing guards — build should confirm they are
  green at merge-base before relying on that framing.
- `plan.json`'s notes mention a prior run (20260928102849-23575) whose
  test/acceptance-gate stages failed with `negctl_error:timeout`, suspected
  to be an infra/rate-limit flake unrelated to this gap. Not re-investigated
  here; flagged for build to watch for recurrence.
- ADR-063 §1's "one shared helper" extraction (currently `plan`, `impact`,
  and `monitor` each have their own inline budget-guidance functions) is
  named but deliberately left out of scope, per the ADR's own adoption order
  (monitor lands before the plan/impact retrofit onto a shared block). If a
  future issue does that extraction, `plugins/agent/monitor/plugin.sh` lines
  75-101/167-179 are a call-site that will need updating.

LOOP_COMPLETE
