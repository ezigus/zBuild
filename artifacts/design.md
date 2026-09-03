# Design: design plugin → contract v2 + ADR-063 §1/§2

## Architectural Decision Summary

**Goal.** Migrate `plugins/agent/design` to the v2 result contract so every exit
path writes a machine-readable `design-verdict.json` sidecar (`result_contract:2`,
`disposition`, `rc∈{0,1}`, `valid_verdicts` expanded to `[pass,error,incomplete]`,
name-matched inputs via `ZBUILD_STAGE_INPUTS`). Land ADR-063 §1/§2 by injecting
live timeout/max_turns budget blocks into the prompt so the model can emit a
best-effort design before it is cut off.

**Context.** The design plugin is the only model-driven stage that writes its sidecar
only on one path (router timeout). All other exit paths leave `design-verdict.json`
absent, so `verdict.sh` falls through to reading the primary (design.md) as presence==pass
— which means a failed run with no design.md reads as "missing", not "error". This
is the v1 gap. ADR-063 §3/§4 require v2 to be on disk before `disposition: exhausted`
becomes load-bearing; §1/§2 (budget in the prompt) unblock only after v2 lands
because a loud failure is safer than a quiet partial (ADR-063 §0).

**Decision.** Four targeted changes to two files, gated by two new test files:

1. **manifest.yaml** — add `provides.result_contract: 2`; expand `valid_verdicts`
   from `[incomplete]` to `[pass, error, incomplete]`; add `config.router.timeout_s: 600`
   and `config.router.max_turns: 45` as manifest-level defaults (template override
   still wins at runtime per ADR-017).

2. **plugin.sh — `_design_write_result` helper** — writes `design-verdict.json`
   on every terminal exit path (success→pass/complete; error paths→error/broken or
   error/throttled per `_router_rc_classify`; timeout→incomplete/interrupted). Timeout
   path replaces its bespoke inline write with the helper. SIGINT (rc=130) propagates
   without a sidecar — that is not a stage outcome. `return 2` normalised to `return 1`
   on non-SIGINT error paths.

3. **plugin.sh — `ZBUILD_STAGE_INPUTS` lookups** — `design_stage_run` reads
   `scope_manifest` and `plan` paths from the index when `ZBUILD_STAGE_INPUTS` is
   set; falls back to path construction when absent (existing unit test fixtures that
   set paths directly keep working). The optional `design` input (prior design body)
   similarly read from index first, `_design_read_prior_design` kept as fallback.

4. **plugin.sh — budget guidance (ADR-063 §1/§2)** — two private helpers
   `_design_budget_guidance <max_turns>` and `_design_wallclock_guidance <timeout_s>
   <elapsed_s>` (mirrors plan plugin's pattern). Appended to prompt BEFORE
   `append_prompt_override` so operator overlay appears last (ADR-032). Also appends
   a best-effort instruction: if sections are unfinished as budget nears, name them
   rather than silently omitting.

```scope
plugins/agent/design/manifest.yaml
plugins/agent/design/plugin.sh
tests/unit/design-v2-result-contract-test.sh
tests/unit/design-budget-prompt-injection-test.sh
tests/unit/design-router-timeout-reiter-test.sh
tests/unit/design-timeout-exhaustion-halt-1261-test.sh
tests/unit/design-acceptance-block-test.sh
tests/unit/design-persona-framing-test.sh
tests/unit/design-summary-switch-test.sh
tests/unit/design-stage-banner-content-test.sh
tests/unit/design-stray-file-recovery-test.sh
tests/unit/design-prompt-override-section-test.sh
tests/unit/design-prompt-scope-charter-test.sh
tests/unit/design-prior-gate-feedback-test.sh
tests/unit/lint-verdict-classify-test.sh
tests/unit/verdict-no-forbidden-strings-guard-test.sh
tests/unit/stage-input-resolve-test.sh
tests/integration/design-build-decisions-flow-test.sh
tests/integration/design-impact-cycle-integration-test.sh
tests/integration/design-impact-cycle-self-feedback-test.sh
tests/integration/design-pipeline-test.sh
tests/integration/design-prompt-override-pipeline-test.sh
core/pipeline/verdict.sh
core/router/route.sh
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
docs/wiki/plugins/design.md
plugins/agent/plan/plugin.sh
scripts/lib/router-rc-classify.sh
```

```acceptance
SPEC-1[change]: success path writes design-verdict.json with result_contract:2, verdict=pass, disposition=complete before atomic_write of design.md
SPEC-2[change]: error path (e.g. missing plan.json) writes design-verdict.json with result_contract:2, verdict=error, disposition=broken
SPEC-3[guard]: timeout path still writes design-verdict.json with verdict=incomplete, disposition=interrupted (existing behaviour unchanged)
SPEC-4[change]: manifest declares provides.result_contract:2 and config.valid_verdicts includes pass, error, and incomplete
SPEC-5[change]: design_stage_run reads scope_manifest and plan paths from ZBUILD_STAGE_INPUTS index when the env var is set, not from hardcoded path construction
SPEC-6[change]: prompt file contains a WALL CLOCK BUDGET block with timeout_s value sourced from _route_resolve_timeout
SPEC-7[change]: prompt file contains a TURN BUDGET block with max_turns value sourced from _route_resolve_max_turns
SPEC-8[guard]: existing prompt body instructions (scope charter, acceptance contract, tools section) are present and unaltered when budget blocks are injected
WIRING: plugins/agent/design/manifest.yaml
TESTFILES:
SPEC-1: tests/unit/design-v2-result-contract-test.sh
SPEC-2: tests/unit/design-v2-result-contract-test.sh
SPEC-3: tests/unit/design-v2-result-contract-test.sh
SPEC-4: tests/unit/design-v2-result-contract-test.sh
SPEC-5: tests/unit/design-v2-result-contract-test.sh
SPEC-6: tests/unit/design-budget-prompt-injection-test.sh
SPEC-7: tests/unit/design-budget-prompt-injection-test.sh
SPEC-8: tests/unit/design-budget-prompt-injection-test.sh
```

LOOP_COMPLETE
