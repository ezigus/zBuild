# ADR-style design: migrate plugins/agent/monitor to contract v2

## Goal

Move the `monitor` plugin's result, disposition, router budgets and inputs
onto ADR-054/ADR-055's contract v2, matching the pattern already shipped for
`review-lens`, `security-lens`, `spec-acceptance`, `review-report`, `merge`,
`pr-open` and `deploy-release` (the ongoing 17-plugin F-wave, #1833–#1849).
`monitor` is the last of that wave (issue #1847). The live `deployed.yaml`
dispatch (`deploy → validate → monitor`) must remain behavior-identical for a
passing run: same stages, same ordering, same `monitor-report.json` verdict
semantics (`pass`/`degraded`).

## Context

Re-verified this iteration against the current tree, `plan.json`, and the
`spec-coverage` gate's `fail` verdict from the prior iteration, which flagged
one real gap in iteration 2's draft (all five gaps from iteration 1→2 are
still fixed and unchanged; see "Carried forward" below).

**Gap from this iteration's `spec-coverage` fail, and the correction it
drives:**

- **Unproven override precedence.** The acceptance checkbox "Router budgets
  resolve from the manifest, and the template override still wins where one
  is set" requires proving precedence — but SPEC-7 (as written in iteration
  2) only asserts the manifest's `config.router` values *match*
  `deployed.yaml`'s existing per-stage override. Both layers declare
  `timeout_s: 300, max_turns: 10` — identical numbers — so no assertion
  actually distinguishes "the manifest supplied this" from "the template
  overrode the manifest and happened to land on the same number." A reader
  cannot tell precedence held from that alone.

  Investigated whether a *new* test is even necessary here, since precedence
  itself is not new: `tests/unit/router-manifest-budget-test.sh` is a
  standing, plugin-agnostic guard (`[SPEC-4]`, `router-manifest-budget-test.sh:213-227`)
  that already proves `core/router/route.sh`'s `_route_resolve_knob` picks
  the template accessor's value over `config.router.*` from an arbitrary
  manifest fixture — the mechanism does not know or care which plugin it is
  resolving for. That test is unaffected by this migration and stays green
  throughout (listed in scope as reference-only, unchanged).

  What that generic guard does **not** cover is `monitor`'s *own* manifest
  content once SPEC-7 adds a `config.router` block to it — there is currently
  no assertion anywhere that exercises `_route_resolve_timeout` /
  `_route_resolve_max_turns` against `plugins/agent/monitor/manifest.yaml`
  itself with a template value that *diverges* from what SPEC-7 puts there.
  Since `route.sh`'s resolution order does not vary by plugin, this is not a
  new behavior this migration introduces — it is the existing, already-true
  precedence rule, newly checkable against `monitor`'s manifest because that
  manifest didn't have a `config.router` block to check it against before.
  Tagged `[guard]` below (SPEC-22) per the classification rule: the
  behavior it asserts is already true at merge-base for any manifest,
  `monitor`'s included, before this migration adds one.

**Carried forward from iteration 1→2 (all re-verified this iteration, tree
unchanged — zero commits since intake):**

1. **`data:{}` folding** — `_monitor_write_result` emits `{result_contract,
   schema_version, verdict, disposition, reason, data:{summary, checks}}`,
   per the issue's own "Folds in" text (`plan.json` step-3), a named
   deviation from `review-lens`'s flat shape (grepped `plugins/agent/*/plugin.sh`
   for `data:{`/`"data":` again this iteration — still no match anywhere in
   the tree). Flagged for human sign-off below.
2. **Mandatory `reason` field**, always present, `""` on `complete` — matches
   `router-rc-classify.sh:13`'s established contract.
3. **rc ∈ {0,1} (#1823)** — the rc=10 turn-budget branch and the
   SIGTERM/SIGINT trap both cause `monitor_stage_run` to `return 1`; the raw
   router rc (10) and signal rc (130) never become the function's own return
   value. Only `disposition` communicates cause.
4. **No hardcoded path-construction fallback** — `monitor`'s two inputs
   (`deploy_result`, `pr_url`) are already `required: false`; the hardcoded
   `$artifacts_dir/deploy-result.json` / `$artifacts_dir/pr-url.txt` string
   construction is deleted outright, read exclusively via
   `$ZBUILD_STAGE_INPUTS`. `monitor-test.sh`'s existing fixture is edited to
   point `$ZBUILD_STAGE_INPUTS` at the same file it populates today.
5. **Cleanup/release hook recorded absence** — one-line manifest comment
   citing `ADR-054 §7 (#1829)`, copied from `review-lens/manifest.yaml:92-94`,
   with a matching test assertion pattern from
   `review-lens/tests/review-lens-v2-budget-test.sh:280-291` (`[SPEC-19]`).

## Decision

- Add `provides.result_contract: 2` to `plugins/agent/monitor/manifest.yaml`.
- Add `config.router: {timeout_s: 300, max_turns: 10}`, matching
  `deployed.yaml`'s existing per-stage override (Pattern-1 single-shot
  headroom, same comment `review-lens/manifest.yaml` uses).
- Add the cleanup-absence comment, adapted from
  `review-lens/manifest.yaml:92-94`:
  ```
  # hooks.cleanup is intentionally absent: this plugin holds no live resources
  # that require teardown — ADR-054 §7 (#1829).
  ```
- Replace `_monitor_write_report` with `_monitor_write_result(out, verdict,
  disposition, reason, summary, checks)`, writing via `jq` (never
  string-interpolated), nested per the issue's "Folds in" instruction:
  ```
  {result_contract:2, schema_version:1, verdict:$v, disposition:$d,
   reason:$r, data:{summary:$s, checks:$c}}
  ```
  `reason` is always passed — `""` on every `complete` call site (dry-run,
  live pass, live degraded-verdict). Call sites and their disposition:
  - dry-run → `complete`, `reason:""`
  - live pass/degraded verdict (model responded, envelope validated) →
    `complete`, `reason:""` (the health verdict itself, in `data.summary`/
    `data.checks`, communicates degradation — a separate axis from
    disposition, per ADR-054 §6)
  - `route_to_model` failure (rc not in {0,10,130}) →
    ```
    local _mon_v="" _mon_r=""
    _router_rc_classify "$rc" _mon_v _mon_r 2>/dev/null || true
    local disposition; disposition="$(router_reason_disposition "${_mon_r:-router_rc_nonzero}")"
    _monitor_write_result "$report_out" "degraded" "$disposition" "${_mon_r:-router_rc_nonzero}" "" "[]"
    ```
  - unparseable/schema-gate-failed reply → `unusable`,
    `reason:"envelope_invalid"` (or the concrete parse-failure string)
  - rc=10 (turn-budget exhaustion) → `out_of_turns`,
    `reason:"budget_exhausted"` — matches `review-lens/plugin.sh:293-309`'s
    rc=10 special case, ordered **before** the generic
    `_router_rc_classify` branch
  - SIGTERM/SIGINT during `route_to_model` → `interrupted`,
    `reason:"signal_interrupt"`, via a trap (`_monitor_interrupt_handler`)
    mirroring `_review_lens_interrupt_handler`
- **rc ∈ {0,1} (#1823):** both the rc=10 branch and the interrupt trap cause
  `monitor_stage_run` to `return 1` — the raw router rc (10) and the raw
  signal rc (130) are never the function's own return value. Only
  `disposition` communicates *why* it returned 1.
- Add the ADR-063 §1 TURN BUDGET / WALL CLOCK BUDGET prompt blocks
  (`_monitor_budget_guidance` / `_monitor_wallclock_guidance`), sourcing
  limits via `_route_resolve_max_turns` / `_route_resolve_timeout`
  (`core/router/route.sh:704,716`), same shape as `review-lens`.
- **Delete** the hardcoded `deploy_result_json="$artifacts_dir/deploy-result.json"`
  / `pr_url_txt="$artifacts_dir/pr-url.txt"` assignments (`plugin.sh:76-77`
  today). Read both exclusively from `$ZBUILD_STAGE_INPUTS`:
  ```
  local deploy_result_json="" pr_url_txt=""
  if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
      deploy_result_json="$(jq -r '.inputs.deploy_result // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
      pr_url_txt="$(jq -r '.inputs.pr_url // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
  fi
  ```
  The existing `[[ -f "$deploy_result_json" ]]` / `[[ -f "$pr_url_txt" ]]`
  guards already handle an empty string correctly — no new conditional
  needed. Both inputs stay `required: false`, unchanged.
- `valid_verdicts: [pass, degraded]`, `outputs:`, `provides.role`,
  `provides.events` — unchanged.
- Update `docs/wiki/plugins/monitor.md`'s embedded manifest snippet
  (result_contract, router block, cleanup-absence comment; drop the stale
  `hooks.cleanup`/`artifact_type`/typed-inputs shape it currently shows).
- No change to `config/templates/deployed.yaml` (read-verified only).

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
docs/adr/ADR-001-plugin-contract.md
core/pipeline/disposition.sh
scripts/lib/router-rc-classify.sh
scripts/lib/llm-agent.sh
scripts/lib/lint-contract.sh
plugins/agent/review-lens/plugin.sh
plugins/agent/review-lens/manifest.yaml
plugins/agent/review-lens/tests/review-lens-v2-budget-test.sh
plugins/agent/design/plugin.sh
core/pipeline/input-resolve.sh
core/router/route.sh
tests/unit/event-schema-emitted-coverage-test.sh
tests/unit/router-manifest-budget-test.sh
```

Notes on the entry new this iteration:

- `tests/unit/router-manifest-budget-test.sh` — **reference-only**, unchanged
  by this migration. Its `[SPEC-4]` (`:213-227`) is the standing, generic
  proof that `_route_resolve_knob` picks the template accessor over any
  manifest's `config.router.*`; SPEC-22 below extends that same proof to
  `monitor`'s own manifest content rather than re-deriving the precedence
  rule. Listed so a reviewer can confirm this file needs no edit and see why
  SPEC-22 doesn't duplicate it.

All other entries are unchanged from the prior iteration — see that
iteration's per-entry notes on `config/templates/deployed.yaml`,
`docs/adr/ADR-054/055`, `review-lens/{plugin.sh,manifest.yaml,tests}`,
`design/plugin.sh` + `input-resolve.sh`, `router-rc-classify.sh` +
`llm-agent.sh` + `route.sh`, `lint-contract.sh`,
`core/pipeline/disposition.sh`, `docs/adr/ADR-001-plugin-contract.md`, and
`event-schema-emitted-coverage-test.sh`.

## Acceptance

```acceptance
SPEC-1[change]: plugins/agent/monitor/manifest.yaml declares provides.result_contract: 2
SPEC-2[change]: monitor-report.json (dry-run path) carries result_contract:2, disposition:complete, reason:"", and data.summary/data.checks (not top-level summary/checks)
SPEC-3[change]: monitor-report.json (live pass path) carries result_contract:2, disposition:complete, reason:"", and the unchanged verdict:pass nested under data (data.summary, data.checks)
SPEC-4[change]: monitor-report.json (route_to_model failure path) carries a disposition derived via router_reason_disposition, with a non-empty reason field naming the classified router reason
SPEC-5[change]: monitor-report.json (unparseable/schema-gate-failed reply path) carries disposition:unusable and a non-empty reason
SPEC-6[change]: a SIGTERM/SIGINT received during the route_to_model call writes disposition:interrupted, reason:signal_interrupt to monitor-report.json, and monitor_stage_run returns rc=1 (not the raw signal rc)
SPEC-7[change]: plugins/agent/monitor/manifest.yaml declares config.router with timeout_s:300 and max_turns:10, matching deployed.yaml's existing per-stage override
SPEC-8[change]: the assembled prompt contains a TURN BUDGET block before the route_to_model call
SPEC-9[change]: the assembled prompt contains a WALL CLOCK BUDGET block before the route_to_model call
SPEC-10[guard]: ZBUILD_DRY_RUN=1 still returns rc=0 and writes verdict=pass without calling route_to_model
SPEC-11[guard]: config.valid_verdicts remains exactly [pass, degraded]
SPEC-12[guard]: inputs: still declares only {id: deploy_result, required: false} and {id: pr_url, required: false} — no source/path/type restated
SPEC-13[guard]: deployed.yaml's deploy → validate → monitor dry-run dispatch still ends with monitor-report.json present and monitor_stage_run returning rc=0
SPEC-14[change]: when $ZBUILD_STAGE_INPUTS is set and its .inputs.deploy_result / .inputs.pr_url entries are non-empty, monitor_stage_run reads the deploy-result / pr-url content from those resolved paths — proven by pointing the index at files in a different directory and asserting the prompt reflects that content
SPEC-15[guard]: plugins/agent/monitor/manifest.yaml's outputs: block still declares exactly one primary: true entry (monitor_report) — scripts/lib/lint-contract.sh's ADR-020/#507 check must keep passing
SPEC-16[guard]: plugins/agent/monitor/manifest.yaml still declares provides.role: monitor, unchanged by this migration
SPEC-17[guard]: plugins/agent/monitor/manifest.yaml still declares provides.events: [monitor.alert, monitor.check, monitor.started], and plugin.sh still emits all three
SPEC-18[change]: plugin.sh contains no hardcoded $artifacts_dir/deploy-result.json or $artifacts_dir/pr-url.txt string construction — grep -n 'artifacts_dir.*deploy-result\|artifacts_dir.*pr-url' plugins/agent/monitor/plugin.sh returns no match; when $ZBUILD_STAGE_INPUTS is unset/empty or has no entry for an optional input, monitor_stage_run treats that input as not provided (identical to today's "file does not exist" path) rather than constructing any fallback path
SPEC-19[change]: plugins/agent/monitor/manifest.yaml declares no top-level cleanup: key and carries a comment citing "ADR-054 §7" explaining hooks.cleanup's intentional absence
SPEC-20[change]: monitor-report.json's reason field is always present as a JSON key on every exit path, including the complete-disposition paths (dry-run, live pass, live degraded-verdict), where its value is the empty string
SPEC-21[change]: monitor_stage_run never returns an rc outside {0,1} — the SIGTERM/SIGINT path and the router rc=10 (turn-budget) path both cause it to return 1, never the raw signal or router rc
SPEC-22[guard]: with ZBUILD_PLUGIN_DIR/ZBUILD_CURRENT_STAGE pointed at monitor's own manifest.yaml, stubbing the template_stage_router_timeout / template_stage_router_max_turns accessors to return values that diverge from the manifest's config.router.{timeout_s,max_turns} (added by SPEC-7) causes _route_resolve_timeout / _route_resolve_max_turns to return the STUBBED (template) value, not the manifest's — proving the template layer still outranks monitor's newly-declared manifest defaults, not merely that the two currently agree
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
SPEC-18: plugins/agent/monitor/tests/monitor-test.sh tests/unit/monitor-v2-result-test.sh
SPEC-19: tests/unit/monitor-v2-result-test.sh
SPEC-20: tests/unit/monitor-v2-result-test.sh
SPEC-21: tests/unit/monitor-v2-result-test.sh
SPEC-22: tests/unit/monitor-v2-result-test.sh
```

Each `[#1847/SPEC-n]`-tagged `[change]` assertion must FAIL at the merge-base
baseline and PASS after this change; SPEC-10, 11, 12, 15, 16, 17, 22 are
guards already true at baseline (SPEC-22's underlying precedence mechanism
predates this issue and does not vary by plugin — see Context) and must stay
true; the acceptance-gate skips the negative control for all guard SPECs.
`plugin.sh:123`'s current single-arg `_llm_router_classify "$rc"` call is
dead code (always yields an empty reason) that this migration replaces
outright — not a regression it introduces.

The `WIRING:` file is `manifest.yaml` itself: reverting it alone to
merge-base (keeping `plugin.sh`'s new code at HEAD) removes
`result_contract: 2` and `config.router`, flipping SPEC-1 and SPEC-7 (and,
because the plugin can no longer resolve non-zero manifest-declared
budgets, SPEC-8/SPEC-9) from pass to fail.

## Named gaps

- **Data-nesting deviation (SPEC-2/3/4/5)**: this design nests
  `summary`/`checks` under `data:{}` per the issue's explicit "Folds in"
  instruction, while every other shipped v2 migration in this wave
  (`review-lens` et al.) keeps those fields flat/top-level. A human should
  confirm this is intentional (issue-specific) rather than an inconsistency
  to fix.
- **`monitor-test.sh`'s existing deploy-result/pr-url fixture must be
  edited**, not merely extended: today it populates
  `$ARTIFACTS_DIR/deploy-result.json` directly with no
  `$ZBUILD_STAGE_INPUTS` set. Making that fixture exercise the enrichment
  path again requires pointing `$ZBUILD_STAGE_INPUTS` at the same file
  (SPEC-14's job) — a test-fixture edit, not a production-behavior change.
- The shared-vs-duplicated helper choice for the two budget-guidance
  functions is left to the build stage.
- Whether SPEC-4 should enumerate more than one non-{0,10,130} rc value is
  left to the build stage's test design; the generic case is sufficient to
  prove the wiring.
- SPEC-22 stubs the template accessor functions directly (mirroring
  `router-manifest-budget-test.sh`'s own `[SPEC-4]` pattern) rather than
  constructing a real divergent `deployed.yaml` override, since this design
  makes no change to `deployed.yaml`. If a reviewer wants proof through the
  real template file instead of a stub, that is a larger, out-of-scope
  change to `deployed.yaml` itself — left for a human to request explicitly.

LOOP_COMPLETE
