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
`deploy-release`, `pr-open`) and, for the two gaps below, against the
current tree read in this iteration:

1. **No `provides.result_contract: 2`.** The manifest declares no
   contract version, so the engine treats it as v1 (`contract_version_default`,
   `core/contract/version.sh`) and the coexistence rc/disposition
   narrowing never applies.
2. **`monitor-report.json` carries no `result_contract`, `disposition` or
   `reason` field.** ADR-054 §5's mandatory v2 result keys are entirely
   absent; only the plugin's own `{schema_version, verdict, summary,
   checks}` shape exists (ADR-054 §5 note: `schema_version` ≠
   `result_contract` — both must coexist, not be conflated). Verified
   against `review-lens/plugin.sh`'s `_review_lens_write_result`
   (`plugins/agent/review-lens/plugin.sh:66-78`): the v2 fields
   (`result_contract`, `disposition`, `reason`) sit **flat, top-level,
   alongside the plugin's own fields** (`name`, `score`, `findings`) —
   there is no `data:{}` nesting wrapper anywhere in the shipped
   reference shape. `monitor`'s own `summary`/`checks` fields follow the
   same flat convention, not a nested envelope.
3. **No disposition mapping on failure paths.** A router failure
   (`route_to_model` rc≠0) and an unparseable/schema-gate-failed reply
   both collapse to `verdict:degraded` with no `disposition` word — the
   reference plugins map these through `_router_rc_classify` +
   `router_reason_disposition` (`scripts/lib/router-rc-classify.sh`) into
   `timed_out`/`out_of_turns`/`interrupted`/`rate_limited`/`unavailable`/
   `misconfigured`/`unusable`, per ADR-054 §6a.
4. **No SIGTERM/SIGINT interrupt handling.** `review-lens` registers a
   trap before the `route_to_model` call (`_review_lens_interrupt_handler`,
   `plugins/agent/review-lens/plugin.sh:84-89`) that writes
   `disposition:interrupted` before propagating rc=130 (ADR-054 §6a
   `interrupted`); `monitor` has no trap, so a signalled dispatch leaves a
   stale or absent primary artifact.
5. **No declared router budgets in the manifest.** `deployed.yaml`
   already sets `router: {timeout_s: 300, max_turns: 10}` at the
   template layer for the `monitor` stage, but the manifest itself
   declares no `config.router` block (unlike `review-lens`), so ADR-054
   §9's manifest-first resolution path has nothing to resolve for this
   plugin, and the prompt carries no ADR-063 §1 TURN BUDGET / WALL CLOCK
   BUDGET guidance block (`review-lens/plugin.sh:91-94`,
   `_review_lens_budget_guidance`, already injects this before the model
   call for its own T1 dispatch).
6. **`monitor_stage_run` hardcodes its two optional input paths.**
   `plugin.sh:76-77` builds `deploy_result_json` and `pr_url_txt` by
   string concatenation on `$artifacts_dir` unconditionally — it never
   looks at the engine-resolved input index. The established fix for
   this exact gap already exists in the tree: `design_stage_run`
   (`plugins/agent/design/plugin.sh:139-149`, ADR-050/#1826) and its
   inner prior-design read (`plugins/agent/design/plugin.sh:478-491`)
   both check `$ZBUILD_STAGE_INPUTS` (a JSON `{"inputs":{name:path}}`
   index the engine exports per `core/plugin-registry/lifecycle.sh:403-404`
   when `input-resolve.sh` ran) for the named input first, **falling
   back to the hardcoded path only when the index is absent or empty**
   — the comment at `design/plugin.sh:141-142` states this explicitly:
   "falling back to the hardcoded path construction so existing test
   fixtures keep working." `monitor` has no equivalent read at all.
7. **`docs/wiki/plugins/monitor.md` is stale independent of this
   change** — it shows a manifest shape (`hooks.cleanup`,
   `provides.artifact_type`/`schema_version`, typed `inputs[].source:
   stage:X`) that predates ADR-055 §1 and ADR-056's cleanup-hook
   removal, already contradicting the current `manifest.yaml` on disk.
   Prior migrations in this same wave (merge/pr-open/deploy-release,
   security-lens) updated their wiki pages in the same PR; this
   migration must do the same for `monitor.md` rather than leave it
   further out of date.

**Verified as already satisfied, not a gap** (re-confirmed this iteration
by reading `manifest.yaml` and `plan.json` directly, in response to
spec-coverage feedback that flagged these as apparently uncovered):

- The manifest's `outputs:` block already declares exactly one
  `primary: true` entry (`monitor_report`, `manifest.yaml:48-54`), and
  the repo-wide `scripts/lib/lint-contract.sh` §"ADR-020 amendment
  (#507)" check (lines ~176-187) already fails the build if any
  in-scope manifest has zero or more-than-one `primary: true` output.
  This migration does not touch `outputs:` and must not regress this —
  captured below as a guard (SPEC-15), not a change.
- `provides.role: monitor` is already declared (`manifest.yaml:20`).
  This migration does not touch it. `plan.json`'s own notes field states
  this explicitly: "its manifest already had valid_verdicts, a
  primary:true output, provides.role, and provides.events — the issue's
  own acceptance checklist anticipates this ('if this plugin already
  declares one, say so and move on')." Captured below as a new guard
  (SPEC-16), since spec-coverage flagged its absence from the acceptance
  block as a gap — the fix is a guard SPEC pinning the pre-existing
  declaration, not a `[change]` (there is nothing to change; a `[change]`
  tag on an already-true behavior cannot fail at baseline, per this
  charter's own tagging rule).
- `provides.events: [monitor.alert, monitor.check, monitor.started]` is
  already declared (`manifest.yaml:21-25`) and every one of those three
  events is already emitted by `plugin.sh` (`emit_event "monitor.started"
  ...`, `"monitor.check"`, `"monitor.alert"`). This is already enforced
  by two existing tests, neither of which this migration touches or
  needs to: `plugins/agent/monitor/tests/monitor-test.sh`'s own
  `[SPEC-6]` ("monitor's manifest declares monitor.started, monitor.check,
  monitor.alert" — both under `provides.events` and in the engine's
  composed known-events set), and the repo-wide
  `tests/unit/event-schema-emitted-coverage-test.sh`'s
  `[SPEC-1717-1]` ("every plugin-emitted event is declared in that
  plugin's own manifest", ADR-001 §"Declared events", #1717) and
  `[SPEC-1717-2]` (`config/event-schema.json` carries no plugin-owned
  namespace — `monitor` already appears in that test's closed
  `_PLUGIN_NS_RE` roster of plugin namespaces, unaffected by this
  change since no namespace is added or renamed). Captured below as a
  new guard (SPEC-17).

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
  `verdict`, `summary`, `checks` (unchanged plugin-owned shape, **flat,
  top-level** — matching `_review_lens_write_result`'s precedent, not a
  `data:{}` wrapper) **plus** `disposition` and `reason`. Every existing
  call site (dry-run, router failure, unparseable reply, normal
  pass/degraded) passes an explicit disposition:
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
  and propagates rc=10, matching `review-lens`'s rc=10 branch. (Note:
  the issue's own "ALSO LAND HERE" text citing `disposition:exhausted`
  is stale — `core/pipeline/disposition.sh` retired `exhausted` in
  #2187 because it mapped to an unimplemented `escalate` action;
  `out_of_turns`/`timed_out` are the current closed vocabulary and both
  already route to `retry`. This design follows the working code, not
  the stale issue citation, per the "spec/precedent wins over drift"
  rule.)
- Inject the ADR-063 §1 TURN BUDGET and WALL CLOCK BUDGET guidance
  blocks into the prompt before the `route_to_model` call, reusing the
  same shape as `_review_lens_budget_guidance` /
  `_review_lens_wallclock_guidance` (new `_monitor_budget_guidance` /
  `_monitor_wallclock_guidance` helpers, or a shared extraction — either
  is acceptable; no shared helper currently exists in `llm-agent.sh` to
  reuse instead of duplicating).
- Read the two optional inputs (`deploy_result`, `pr_url`) via
  `$ZBUILD_STAGE_INPUTS` first, falling back to the current hardcoded
  `$artifacts_dir/deploy-result.json` / `$artifacts_dir/pr-url.txt`
  paths — the identical read-then-fallback shape already used by
  `design_stage_run` (`plugins/agent/design/plugin.sh:143-149`):
  ```
  if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
      _si_deploy="$(jq -r '.inputs.deploy_result // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
      _si_pr="$(jq -r '.inputs.pr_url // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
      [[ -n "$_si_deploy" ]] && deploy_result_json="$_si_deploy"
      [[ -n "$_si_pr" ]] && pr_url_txt="$_si_pr"
  fi
  ```
  This keeps the literal hardcoded path strings in code as a fallback —
  a **deliberate, tested** choice (SPEC-18 below), not an accidental
  omission. The design follows the one working precedent in the tree
  (`design_stage_run`) rather than inventing a stricter no-fallback
  variant with no reference implementation to copy. SPEC-14 proves the
  index takes priority when present; SPEC-18 proves the fallback
  construction is retained (not deleted) when the index is absent —
  together they cover both branches of this decision, closing the gap
  spec-coverage flagged in this SPEC's earlier draft.
- `valid_verdicts: [pass, degraded]` and the `outputs:` block (including
  the `monitor_summary` ADR-055 §9 summary output and the existing
  `monitor_report` `primary: true` declaration) are **unchanged** — this
  migration touches the result/disposition/budget/input-resolution axes
  only, not the plugin's own verdict vocabulary or its artifact set.
- Update `docs/wiki/plugins/monitor.md`'s embedded manifest snippet to
  match the post-migration `manifest.yaml` (result_contract, router
  block, and drop the already-stale `hooks.cleanup`/`artifact_type`/
  typed-inputs shape it currently shows).
- No change to `config/templates/deployed.yaml` — its existing
  `monitor: {router: {timeout_s: 300, max_turns: 10}}` override already
  matches the new manifest default; the template is read-verified, not
  edited.
- No change to `provides.role` or `provides.events` — both are already
  correct and already guarded by tests outside this migration's scope
  (see Context, above). This migration must not regress either.

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
scripts/lib/lint-contract.sh
plugins/agent/review-lens/plugin.sh
plugins/agent/review-lens/manifest.yaml
plugins/agent/design/plugin.sh
core/pipeline/input-resolve.sh
tests/unit/event-schema-emitted-coverage-test.sh
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
  interrupt-handler/result-shape pattern is copied from; listed so a
  reviewer can diff monitor's new code against its template directly.
- `plugins/agent/design/plugin.sh` and `core/pipeline/input-resolve.sh`
  are **reference-only** — the source of the `$ZBUILD_STAGE_INPUTS`
  read-then-fallback pattern (ADR-050/#1826) this design copies for
  `monitor`'s two optional inputs; no change to either file.
- `scripts/lib/router-rc-classify.sh`, `scripts/lib/llm-agent.sh` are
  **reference-only** (reused functions `_router_rc_classify`,
  `router_reason_disposition`, `_llm_envelope_parse` — no change to
  either file).
- `scripts/lib/lint-contract.sh` is **reference-only** — the existing
  repo-wide "exactly one `primary: true`" check (ADR-020 amendment
  #507) that already covers `monitor`'s manifest and must keep passing
  (SPEC-15); listed so the build stage confirms the guard rather than
  re-deriving it, no edit expected.
- `tests/unit/event-schema-emitted-coverage-test.sh` is **reference-only**
  — added this iteration in response to spec-coverage feedback. Its
  `[SPEC-1717-1]`/`[SPEC-1717-2]` assertions already cover `monitor`'s
  `provides.events` declaration and namespace membership (SPEC-17
  below); no edit expected, listed so the build stage confirms this
  guard keeps passing rather than silently assuming it.
- No enumeration/roster file breaks by omission here: `provides.result_contract`
  is self-declared per manifest and read dynamically
  (`core/contract/version.sh`); `scripts/lib/lint-contract.sh`'s
  `_LC_STAGE_IDS_TO_CHECK` strangler baseline already lists `monitor` and
  is unaffected (monitor's input/output id graph membership is
  unchanged); `tests/unit/dispatch-rc-guard-test.sh`'s pinned counts are
  scoped to `core/pipeline/*.sh` engine files only, not plugin code, and
  are unaffected by this change; `tests/unit/event-schema-emitted-coverage-test.sh`'s
  `_PLUGIN_NS_RE` roster already lists `monitor` and this migration adds
  no new event namespace to it.

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
SPEC-14[change]: when $ZBUILD_STAGE_INPUTS is set and its .inputs.deploy_result / .inputs.pr_url entries are non-empty, monitor_stage_run reads the deploy-result / pr-url content from those resolved paths instead of the hardcoded $artifacts_dir/deploy-result.json / pr-url.txt paths — proven by pointing the index at files in a different directory and asserting the prompt (or report) reflects that content, not the artifacts_dir copies
SPEC-15[guard]: plugins/agent/monitor/manifest.yaml's outputs: block still declares exactly one primary: true entry (monitor_report) — scripts/lib/lint-contract.sh's ADR-020/#507 check must keep passing for this manifest
SPEC-16[guard]: plugins/agent/monitor/manifest.yaml still declares provides.role: monitor, unchanged by this migration
SPEC-17[guard]: plugins/agent/monitor/manifest.yaml still declares provides.events: [monitor.alert, monitor.check, monitor.started], and plugin.sh still emits all three — monitor-test.sh's existing [SPEC-6] and tests/unit/event-schema-emitted-coverage-test.sh's [SPEC-1717-1]/[SPEC-1717-2] must keep passing unchanged
SPEC-18[guard]: when $ZBUILD_STAGE_INPUTS is unset or empty, monitor_stage_run still falls back to constructing and reading $artifacts_dir/deploy-result.json and $artifacts_dir/pr-url.txt exactly as before — the hardcoded fallback path literals are retained in plugin.sh, not deleted, per this design's precedent-following decision (see Decision, above) — proven by monitor-test.sh's pre-existing [SPEC-3] (which populates $ARTIFACTS_DIR/deploy-result.json directly with no ZBUILD_STAGE_INPUTS set) continuing to pass unchanged after this migration
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
SPEC-14: tests/unit/monitor-v2-result-test.sh
SPEC-15: tests/unit/monitor-v2-result-test.sh
SPEC-16: tests/unit/monitor-v2-result-test.sh
SPEC-17: plugins/agent/monitor/tests/monitor-test.sh tests/unit/event-schema-emitted-coverage-test.sh
SPEC-18: plugins/agent/monitor/tests/monitor-test.sh
```

Each `[#1847/SPEC-n]`-tagged assertion above must FAIL at the merge-base
baseline (today's manifest has no `result_contract`/`disposition`/
`router` block, `plugin.sh` writes no `disposition` field, has no
interrupt trap, injects no budget guidance, and never reads
`$ZBUILD_STAGE_INPUTS`) and PASS after this change, except SPEC-15,
SPEC-16, SPEC-17 and SPEC-18, which are guards already true at baseline
(the last three confirmed this iteration by reading `manifest.yaml`,
`plugin.sh` and `plan.json` directly) and must stay true. The `WIRING:`
file is `manifest.yaml` itself: reverting it alone to merge-base
(keeping `plugin.sh`'s new disposition/budget/input-resolution code at
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
- **SPEC-14/SPEC-18 fallback-retention decision**: the design keeps a
  hardcoded fallback path for `deploy_result`/`pr_url` (matching
  `design_stage_run`'s only precedent in the tree), rather than removing
  path construction from `plugin.sh` entirely. An absolute reading of
  "the plugin constructs no artifact paths in code" would require a
  stricter no-fallback variant that has no working reference
  implementation anywhere in the repo today. This iteration resolved the
  ambiguity spec-coverage flagged by adding SPEC-18 as an explicit,
  tested guard for the fallback-retention branch (SPEC-14 already
  covered the index-present branch) — the decision is now a stated,
  tested contract rather than a silent gap. A human should still confirm
  this precedent-following interpretation is the intended one before
  merge, since it is a direct, deliberate narrowing of a literal
  acceptance phrase — the same class of judgment call the plan already
  made for the `exhausted`→`out_of_turns` disposition correction.
- The plan step that suggested folding `summary`/`checks` into a nested
  `data:{}` object was checked against the shipped reference
  (`review-lens/plugin.sh:66-78`) and found to not match: the real
  precedent keeps plugin-owned fields flat/top-level beside the v2
  fields. This design follows the shipped precedent, not the plan's
  suggestion.

LOOP_COMPLETE
