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

Re-verified this iteration against the current tree and against `plan.json`
(the step-by-step decomposition this design was checked against) and the
`spec-coverage` gate's `fail` verdict from the prior iteration, which flagged
five real gaps in the previous draft. Each is addressed below; nothing in the
previously-verified baseline facts (no `result_contract`, no `config.router`,
flat `{schema_version,verdict,summary,checks}` shape, no trap, no
`$ZBUILD_STAGE_INPUTS` read) has changed — the branch still has zero commits
since intake.

**Gaps from the `spec-coverage` fail, and the correction each drives:**

1. **`data:{}` folding.** `plan.json` step-3 is explicit and quotes the
   issue's own "Folds in" section: `_monitor_write_result` must emit
   `{result_contract, schema_version, verdict, disposition, reason,
   data:{summary, checks}}` — the plugin-owned `summary`/`checks` fields
   fold into a namespaced `data` block. **This corrects the prior
   iteration's decision**, which followed `review-lens/plugin.sh:66-78`'s
   flat, un-nested shape (confirmed again this iteration — no shipped
   migrated plugin uses a `data:{}` wrapper; grepped `plugins/agent/*/plugin.sh`
   for `"data":` / `data:{` and found no match anywhere in the tree). The
   issue text for #1847 is more specific than the general wave precedent on
   this point, and per CLAUDE.md's spec-wins rule the design follows the
   issue's explicit instruction for **this** plugin rather than generalizing
   review-lens's shape to it. Flagged below as a named deviation for human
   sign-off, since it means `monitor` and `review-lens` will not share an
   identical v2 envelope shape.
2. **Mandatory `reason` field.** The prior draft only added `reason` on
   failure paths. `router-rc-classify.sh:13`'s own contract (`rc=0: verdict=""
   reason=""`) establishes the precedent that `reason` is always a present
   key, empty string on success — `_review_lens_write_result` takes `reason`
   as a positional arg on every call site, including the success path. The
   corrected `_monitor_write_result` does the same: `reason` is always
   passed, `""` on `complete`.
3. **rc ∈ {0,1}.** `plan.json` step-4 states this directly, citing #1823:
   "Every rc ∈ {0,1} ... no other exit code leaves the plugin." The prior
   draft's SIGTERM/SIGINT branch let rc=130 propagate out of
   `monitor_stage_run` — **wrong**, and contradicted by `plan.json` step-5,
   which says the interrupt handler "writes disposition:'interrupted' ...
   and exits 1" (not 130). Corrected below: the trap and the rc=10
   turn-budget branch both cause `monitor_stage_run` itself to return 1;
   only the disposition field communicates cause, never the exit code.
4. **No hardcoded path-construction fallback.** The prior draft copied
   `design_stage_run`'s pattern verbatim: hardcoded `$artifacts_dir/...`
   paths as local-variable defaults, overridden by `$ZBUILD_STAGE_INPUTS`
   when present. `plan.json` step-7 is explicit that this is wrong for
   `monitor`: "Delete the hardcoded ... path construction ... Confirm via
   `grep` that no path construction remains." The difference from
   `design_stage_run`'s case: `design`'s two inputs (`scope_manifest`,
   `plan`) are **required** — the stage cannot run without them, so a
   same-directory default is a reasonable last resort. `monitor`'s two
   inputs (`deploy_result`, `pr_url`) are **already declared
   `required: false`** (`manifest.yaml`, unchanged) — the plugin already
   has correct fail-open handling for "this input is absent" via its
   existing `[[ -f "$deploy_result_json" ]]` guards. There is no need for a
   hardcoded-path fallback at all: when `$ZBUILD_STAGE_INPUTS` has no entry
   for an optional input, the correct behavior is simply "treat it as not
   provided," identical to today's behavior when the file doesn't exist.
   Corrected below: the hardcoded `$artifacts_dir/deploy-result.json` /
   `$artifacts_dir/pr-url.txt` string construction is deleted outright, not
   retained as a fallback branch. This requires updating the existing
   `monitor-test.sh` fixture (currently populates
   `$ARTIFACTS_DIR/deploy-result.json` directly with no
   `$ZBUILD_STAGE_INPUTS` set) to instead point `$ZBUILD_STAGE_INPUTS` at
   that same fixture file — an in-scope test edit, not a production
   behavior change (the live `deployed.yaml` dispatch always runs
   `input-resolve.sh` first and always populates the index, confirmed via
   `core/pipeline/input-resolve.sh` and `core/plugin-registry/lifecycle.sh:403-404`).
5. **Cleanup/release hook recorded absence.** `plan.json` step-1 requires a
   one-line manifest comment recording that no `hooks.cleanup` is declared.
   The prior draft omitted this entirely — no gap analysis, no SPEC, no
   scope entry for the exact precedent. Found the shipped precedent this
   iteration: `plugins/agent/review-lens/manifest.yaml:92-94`:
   ```
   # hooks.cleanup is intentionally absent: this plugin holds no live resources
   # that require teardown — ADR-054 §7 (#1829). The stub review_lens_cleanup in
   # plugin.sh is a reference marker only.
   ```
   and its dedicated test, `plugins/agent/review-lens/tests/review-lens-v2-budget-test.sh:280-291`
   (`[SPEC-19]`): asserts (a) `manifest.yaml` has no top-level `cleanup:`
   key, and (b) the manifest contains a comment citing `ADR-054 §7`. This
   design copies both the comment text and the test pattern for `monitor`
   (which holds no live resources either — an LLM health-check with no
   locks, no writable external state). `plan.json`'s own citation of
   "ADR-001" for this rule is the general lifecycle description
   (`docs/adr/ADR-001-plugin-contract.md:134`); the specific "record the
   absence" requirement and its enforced comment format is ADR-054 §7,
   per the shipped code — this design cites both, matching review-lens.

**Everything else from the prior iteration is unchanged and re-verified**:
`provides.role`, `provides.events`, `outputs:` (single `primary: true`),
`valid_verdicts`, the ADR-063 budget-guidance blocks, the
`_router_rc_classify`/`router_reason_disposition` three-arg call correction,
and the wiki-staleness finding for `docs/wiki/plugins/monitor.md`.

## Decision

- Add `provides.result_contract: 2` to `plugins/agent/monitor/manifest.yaml`.
- Add `config.router: {timeout_s: 300, max_turns: 10}`, matching
  `deployed.yaml`'s existing per-stage override (Pattern-1 single-shot
  headroom, same comment `review-lens/manifest.yaml` uses).
- Add the cleanup-absence comment, copied verbatim in spirit from
  `review-lens/manifest.yaml:92-94`, adapted for `monitor`:
  ```
  # hooks.cleanup is intentionally absent: this plugin holds no live resources
  # that require teardown — ADR-054 §7 (#1829).
  ```
- Replace `_monitor_write_report` with `_monitor_write_result(out, verdict,
  disposition, reason, summary, checks)`, writing via `jq` (never
  string-interpolated), **nested per the issue's "Folds in" instruction**:
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
  - `route_to_model` failure (rc not in {0,10,130}) → disposition via the
    corrected call pattern (copied from `review-lens/plugin.sh:315-317`):
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
    `reason:"signal_interrupt"`, via a trap
    (`_monitor_interrupt_handler`) mirroring
    `_review_lens_interrupt_handler`
- **rc ∈ {0,1} (#1823):** both the rc=10 branch and the interrupt trap cause
  `monitor_stage_run` to `return 1` — the raw router rc (10) and the raw
  signal rc (130) are never the function's own return value. Only
  `disposition` communicates *why* it returned 1; the caller/engine reads
  the disposition field from `monitor-report.json`, not the exit code, to
  decide retry policy (`core/pipeline/disposition.sh`'s response table).
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
  guards already handle an empty string correctly (file-exists test on `""`
  is false) — no new conditional needed. Both inputs stay `required: false`
  in the manifest, unchanged.
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
```

Notes on entries new this iteration:

- `plugins/agent/review-lens/tests/review-lens-v2-budget-test.sh` —
  **reference-only**, the shipped `[SPEC-19]` assertion pattern (no
  `cleanup:` key + comment citing `ADR-054 §7`) this design's cleanup-absence
  SPEC copies verbatim for `monitor`.
- `core/pipeline/disposition.sh` — **reference-only**, the closed
  disposition vocabulary and engine response table; the Decision section's
  disposition choices (`complete`/`unusable`/`out_of_turns`/`interrupted`)
  are drawn directly from its documented set, and its "`exhausted` retired
  by #2187" note is why this design (like the prior iteration) does not use
  the issue's stale `disposition:exhausted` text.
- `docs/adr/ADR-001-plugin-contract.md` — **reference-only**, general
  lifecycle-hook description (`cleanup` semantics, line 134) that
  `plan.json` cites; the specific recorded-absence comment convention is
  ADR-054 §7, per the shipped `review-lens` precedent — both are listed so
  a reviewer can see why both ADRs are cited in the new manifest comment.

All other entries are unchanged from the prior iteration (see that
iteration's per-entry notes on `config/templates/deployed.yaml`,
`docs/adr/ADR-054/055`, `review-lens/{plugin.sh,manifest.yaml}`,
`design/plugin.sh` + `input-resolve.sh`, `router-rc-classify.sh` +
`llm-agent.sh` + `route.sh`, `lint-contract.sh`, and
`event-schema-emitted-coverage-test.sh`).

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
```

Each `[#1847/SPEC-n]`-tagged `[change]` assertion must FAIL at the merge-base
baseline and PASS after this change; SPEC-10, 11, 12, 15, 16, 17 are guards
already true at baseline and must stay true. `plugin.sh:123`'s current
single-arg `_llm_router_classify "$rc"` call is dead code (always yields an
empty reason) that this migration replaces outright — not a regression it
introduces.

The `WIRING:` file is `manifest.yaml` itself: reverting it alone to
merge-base (keeping `plugin.sh`'s new code at HEAD) removes
`result_contract: 2` and `config.router`, flipping SPEC-1 and SPEC-7 (and,
because the plugin can no longer resolve non-zero manifest-declared
budgets, SPEC-8/SPEC-9) from pass to fail.

## Named gaps

- **Data-nesting deviation (SPEC-2/3/4/5)**: this design nests
  `summary`/`checks` under `data:{}` per the issue's explicit "Folds in"
  instruction, while every other shipped v2 migration in this wave
  (`review-lens` et al.) keeps those fields flat/top-level. This means
  `monitor`'s v2 envelope shape is not byte-identical to its siblings'. A
  human should confirm this is intentional (issue-specific) rather than an
  inconsistency to fix — the design follows the more specific instruction
  (this issue's text, per `plan.json` step-3) over the general wave
  precedent, per CLAUDE.md's spec-wins rule.
- **`monitor-test.sh`'s existing deploy-result/pr-url fixture must be
  edited**, not merely extended: today it populates
  `$ARTIFACTS_DIR/deploy-result.json` directly with no
  `$ZBUILD_STAGE_INPUTS` set (this is what SPEC-18 exercises going forward
  as "no fallback" behavior). Making that fixture exercise the enrichment
  path again requires pointing `$ZBUILD_STAGE_INPUTS` at the same file
  (SPEC-14's job). This is a test-fixture edit, not a production-behavior
  change — the live `deployed.yaml` dispatch always populates the index via
  `input-resolve.sh` before `monitor` runs.
- The shared-vs-duplicated helper choice for the two budget-guidance
  functions is left to the build stage, as in the prior iteration.
- Whether SPEC-4 should enumerate more than one non-{0,10,130} rc value
  (e.g. rc=124 timeout vs. generic rc=1) is left to the build stage's test
  design; the generic case is sufficient to prove the wiring.

LOOP_COMPLETE
