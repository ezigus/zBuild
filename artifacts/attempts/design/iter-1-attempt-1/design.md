# ADR-style design: migrate plugins/agent/monitor to contract v2

## Goal

Move the `monitor` plugin's result file, disposition, router budgets and
inputs onto ADR-054/ADR-055's contract v2, matching the pattern already
shipped for `review-lens`, `security-lens`, `spec-acceptance`,
`review-report`, `merge`, `pr-open` and `deploy-release` (the ongoing
17-plugin F-wave, #1833–#1849). `monitor` is the last of that wave
(issue #1847). The live `deployed.yaml` dispatch (`deploy → validate →
monitor`) must remain behavior-identical for a passing run: same stages,
same ordering, same `monitor-report.json` verdict semantics
(`pass`/`degraded`).

## Context

`monitor` (`plugins/agent/monitor`) is a `kind:agent`, T1, one-shot
(ADR-018 Pattern 1) LLM health check. It already uses the shared
ADR-028 `llm-agent.sh` framework (schema-gated envelope parse) and
ADR-043 redaction-by-construction (`route_to_model`), and its `inputs:`
block already speaks the ADR-055 §1 name-only convention (`deploy_result`,
`pr_url` — both `required: false`, no restated `source`/`path`/`type`,
and both id-match their producers' declared output ids in
`plugins/agent/deploy/manifest.yaml` and
`plugins/agent/pr-delivery/manifest.yaml`). What is missing, verified
against the shipped reference implementations (`review-lens`,
`deploy-release`, `pr-open`):

1. **No `provides.result_contract: 2`.** The manifest declares no
   contract version, so the engine treats it as v1 (`contract_version_default`,
   `core/contract/version.sh`) and the coexistence rc/disposition
   narrowing never applies.
2. **`monitor-report.json` carries no `result_contract`, `disposition` or
   `reason` field.** ADR-054 §5's mandatory v2 result keys are entirely
   absent; only the plugin's own `{schema_version, verdict, summary,
   checks}` shape exists (ADR-054 §5 note: `schema_version` ≠
   `result_contract` — both must coexist, not be conflated).
3. **No disposition mapping on failure paths.** A router failure
   (`route_to_model` rc≠0) and an unparseable/schema-gate-failed reply
   both collapse to `verdict:degraded` with no `disposition` word — the
   reference plugins map these through `_router_rc_classify` +
   `router_reason_disposition` (`scripts/lib/router-rc-classify.sh`) into
   `timed_out`/`out_of_turns`/`interrupted`/`rate_limited`/`unavailable`/
   `misconfigured`/`unusable`, per ADR-054 §6a.
4. **No SIGTERM/SIGINT interrupt handling.** `review-lens` and
   `deploy-release` register a trap before the `route_to_model` call that
   writes `disposition:interrupted` before propagating rc=130 (ADR-054
   §6a `interrupted`); `monitor` has no trap, so a signalled dispatch
   leaves a stale or absent primary artifact.
5. **No declared router budgets in the manifest.** `deployed.yaml`
   already sets `router: {timeout_s: 300, max_turns: 10}` at the
   template layer for the `monitor` stage, but the manifest itself
   declares no `config.router` block (unlike `review-lens`), so ADR-054
   §9's manifest-first resolution path has nothing to resolve for this
   plugin, and the prompt carries no ADR-063 §1 TURN BUDGET / WALL CLOCK
   BUDGET guidance block (both `review-lens` and `spec-acceptance`-style
   T1 stages already inject these before the model call).
6. **`docs/wiki/plugins/monitor.md` is stale independent of this
   change** — it shows a manifest shape (`hooks.cleanup`,
   `provides.artifact_type`/`schema_version`, typed `inputs[].source:
   stage:X`) that predates ADR-055 §1 and ADR-056's cleanup-hook
   removal, already contradicting the current `manifest.yaml` on disk.
   Prior migrations in this same wave (merge/pr-open/deploy-release,
   security-lens) updated their wiki pages in the same PR
   ("update wiki doc to reflect contract v2 manifest shape"); this
   migration must do the same for `monitor.md` rather than leave it
   further out of date.

## Decision

- Add `provides.result_contract: 2` to `plugins/agent/monitor/manifest.yaml`,
  alongside the existing `role: monitor` and `events:` list (unchanged).
- Add `config.router: {timeout_s: 300, max_turns: 10}` to the manifest,
  matching `deployed.yaml`'s existing per-stage override exactly, so a
  bare/manual dispatch of `monitor` (no template override) gets the same
  budget the live template already provides — a behavior-preserving,
  not behavior-changing, declaration for the live path.
- In `plugin.sh`, replace `_monitor_write_report` with a v2-shaped
  writer that emits `result_contract:2`, the existing `schema_version:1`,
  `verdict`, `summary`, `checks` (unchanged plugin-owned shape) **plus**
  `disposition` and `reason`, mirroring `_review_lens_write_result`'s
  jq-constructed, atomically-written pattern. Every existing call site
  (dry-run, router failure, unparseable reply, normal pass/degraded)
  passes an explicit disposition:
  - dry-run → `disposition: complete`
  - router failure → `router_reason_disposition "$(_router_rc_classify ...)"`
    (mirrors `review-lens`'s `router_reason_disposition` call on its
    failure path)
  - unparseable/schema-gate-failed reply → `disposition: unusable`
  - normal pass/degraded verdict (model responded, envelope validated) →
    `disposition: complete` (the health-assessment verdict is a separate
    axis per ADR-054 §6 — `monitor`'s own `pass`/`degraded` vocabulary is
    unchanged and untouched)
- Add a SIGTERM/SIGINT trap around the `route_to_model` call
  (`_monitor_interrupt_handler`, registered/cleared exactly like
  `_review_lens_interrupt_handler`) that writes
  `disposition:interrupted` and lets rc=130 propagate.
  A router rc=10 (turn-budget exhaustion) writes `disposition:out_of_turns`
  and propagates rc=10, matching `review-lens`'s rc=10 branch.
- Inject the ADR-063 §1 TURN BUDGET and WALL CLOCK BUDGET guidance
  blocks into the prompt before the `route_to_model` call, reusing the
  same shape as `_review_lens_budget_guidance` /
  `_review_lens_wallclock_guidance` (new `_monitor_budget_guidance` /
  `_monitor_wallclock_guidance` helpers, or a shared extraction — either
  is acceptable; no shared helper currently exists in `llm-agent.sh` to
  reuse instead of duplicating).
- `valid_verdicts: [pass, degraded]`, the `inputs:` block, and the
  `outputs:` block (including the `monitor_summary` ADR-055 §9 summary
  output) are **unchanged** — this migration touches the result/
  disposition/budget axes only, not the plugin's own verdict vocabulary
  or its artifact set.
- Update `docs/wiki/plugins/monitor.md`'s embedded manifest snippet to
  match the post-migration `manifest.yaml` (result_contract, router
  block, and drop the already-stale `hooks.cleanup`/`artifact_type`/
  typed-inputs shape it currently shows).
- No change to `config/templates/deployed.yaml` — its existing
  `monitor: {router: {timeout_s: 300, max_turns: 10}}` override already
  matches the new manifest default; the template is read-verified, not
  edited.

## Scope

```scope
plugins/agent/monitor/manifest.yaml
plugins/agent/monitor/plugin.sh
plugins/agent/monitor/tests/monitor-test.sh
tests/integration/deployed-template-e2e-test.sh
tests/unit/monitor-v2-result-test.sh
docs/wiki/plugins/monitor.md
config/templates/deployed.yaml
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
scripts/lib/router-rc-classify.sh
scripts/lib/llm-agent.sh
plugins/agent/review-lens/plugin.sh
plugins/agent/review-lens/manifest.yaml
```

Notes on the non-obvious entries:

- `tests/unit/monitor-v2-result-test.sh` is **new**, following the
  established per-plugin dedicated-test convention for this wave
  (`tests/unit/deploy-release-v2-result-test.sh`,
  `tests/unit/pr-open-v2-result-test.sh`,
  `tests/unit/pr-open-v2-inputs-test.sh`, `tests/unit/merge-v2-result-test.sh`,
  `tests/unit/gate-v2-contract-test.sh`, `tests/unit/review-report-v2-contract-test.sh`).
  These live at `tests/unit/`, not under the plugin's own `tests/`
  directory, and this migration should match that placement rather than
  invent a new one.
- `config/templates/deployed.yaml` is scoped as a **read/verify** site —
  its `monitor:` stage already declares `router.timeout_s: 300` /
  `max_turns: 10`; the design's manifest-level default must match it
  exactly or the two layers silently disagree about which stages get
  which budget on a bare dispatch.
- `docs/adr/ADR-054-stage-contract.md` and `ADR-055-...md` are
  **reference-only** — no roster of migrated plugin names or per-plugin
  count lives in either file that this change would make stale (verified:
  §4b's "17 F-wave migrations" prose names issue numbers, not plugin
  names, and needs no edit when one more lands). Listed so the build
  stage confirms this rather than re-deriving it.
- `plugins/agent/review-lens/{plugin.sh,manifest.yaml}` are the
  **reference implementation** this design's disposition/budget/
  interrupt-handler pattern is copied from; listed so a reviewer can
  diff monitor's new code against its template directly.
- `scripts/lib/router-rc-classify.sh` and `scripts/lib/llm-agent.sh` are
  **reference-only** (reused functions `_router_rc_classify`,
  `router_reason_disposition`, `_llm_envelope_parse` — no change to
  either file).
- No enumeration/roster file breaks by omission here: `provides.result_contract`
  is self-declared per manifest and read dynamically
  (`core/contract/version.sh`); `scripts/lib/lint-contract.sh`'s
  `_LC_STAGE_IDS_TO_CHECK` strangler baseline already lists `monitor` and
  is unaffected (monitor's input/output id graph membership is
  unchanged); `tests/unit/dispatch-rc-guard-test.sh`'s pinned counts are
  scoped to `core/pipeline/*.sh` engine files only, not plugin code, and
  are unaffected by this change.

## Acceptance

```acceptance
SPEC-1[change]: plugins/agent/monitor/manifest.yaml declares provides.result_contract: 2
SPEC-2[change]: monitor-report.json (dry-run path) carries result_contract:2 and disposition:complete
SPEC-3[change]: monitor-report.json (live pass path) carries result_contract:2 and disposition:complete alongside the unchanged verdict:pass
SPEC-4[change]: monitor-report.json (route_to_model failure path) carries a disposition derived via router_reason_disposition, not a bare verdict:degraded with no disposition field
SPEC-5[change]: monitor-report.json (unparseable/schema-gate-failed reply path) carries disposition:unusable
SPEC-6[change]: a SIGTERM/SIGINT received during the route_to_model call writes disposition:interrupted to monitor-report.json before the signal rc (130) propagates
SPEC-7[change]: plugins/agent/monitor/manifest.yaml declares config.router with timeout_s:300 and max_turns:10, matching deployed.yaml's existing per-stage override
SPEC-8[change]: the assembled prompt contains a TURN BUDGET block before the route_to_model call
SPEC-9[change]: the assembled prompt contains a WALL CLOCK BUDGET block before the route_to_model call
SPEC-10[guard]: ZBUILD_DRY_RUN=1 still returns rc=0 and writes verdict=pass without calling route_to_model
SPEC-11[guard]: config.valid_verdicts remains exactly [pass, degraded]
SPEC-12[guard]: inputs: still declares only {id: deploy_result, required: false} and {id: pr_url, required: false} — no source/path/type restated
SPEC-13[guard]: deployed.yaml's deploy → validate → monitor dry-run dispatch still ends with monitor-report.json present and monitor_stage_run returning rc=0
WIRING:
plugins/agent/monitor/manifest.yaml
TESTFILES:
SPEC-1: tests/unit/monitor-v2-result-test.sh
SPEC-2: tests/unit/monitor-v2-result-test.sh
SPEC-3: tests/unit/monitor-v2-result-test.sh
SPEC-4: tests/unit/monitor-v2-result-test.sh
SPEC-5: tests/unit/monitor-v2-result-test.sh
SPEC-6: tests/unit/monitor-v2-result-test.sh
SPEC-7: tests/unit/monitor-v2-result-test.sh
SPEC-8: tests/unit/monitor-v2-result-test.sh
SPEC-9: tests/unit/monitor-v2-result-test.sh
SPEC-10: plugins/agent/monitor/tests/monitor-test.sh
SPEC-11: plugins/agent/monitor/tests/monitor-test.sh tests/unit/monitor-v2-result-test.sh
SPEC-12: plugins/agent/monitor/tests/monitor-test.sh tests/unit/monitor-v2-result-test.sh
SPEC-13: tests/integration/deployed-template-e2e-test.sh
```

Each `[#1847/SPEC-n]`-tagged assertion above must FAIL at the merge-base
baseline (today's manifest has no `result_contract`/`disposition`/
`router` block, and `plugin.sh` writes no `disposition` field, has no
interrupt trap, and injects no budget guidance) and PASS after this
change. The `WIRING:` file is `manifest.yaml` itself: reverting it alone
to merge-base (keeping `plugin.sh`'s new disposition/budget code at
HEAD) removes `result_contract: 2` and the `config.router` block, which
should flip SPEC-1 and SPEC-7 (and, because the plugin can no longer
resolve non-zero manifest-declared budgets, SPEC-8/SPEC-9) from pass to
fail — proving the manifest declaration is load-bearing rather than
inert.

## Named gaps

- The exact shared-vs-duplicated helper choice for the two budget-
  guidance functions (extract into `llm-agent.sh` vs. duplicate
  per-plugin, as `review-lens` currently does) is left to the build
  stage; no existing shared helper exists to require reuse over the
  established duplication pattern.
- Whether `SPEC-4`'s router-failure disposition test should enumerate
  more than one rc value (e.g. rc=124 timeout vs. generic rc=1) is left
  to the build stage's test design; both map through the same
  `router_reason_disposition` call already covered by
  `scripts/lib/router-rc-classify.sh`'s own unit coverage, so one
  representative case is sufficient to prove the wiring per SPEC-4's
  claim.

LOOP_COMPLETE
