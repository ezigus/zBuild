# Design: Migrate build plugin to result_contract:2 (issue #1833)

## Architectural Decision Summary

**Goal.** Bring the build plugin fully into conformance with ADR-054's Stage Contract v2: unconditional `result_contract:2` in every result file, `disposition` declared on every verdict branch, exit codes narrowed to `{0,1}`, inputs read from the engine-resolved `ZBUILD_STAGE_INPUTS` index, and router budget knobs declared as manifest data (ADR-017/ADR-054 §9).

**Context.** The build plugin is the F-wave migration entry #1833. Three gaps relative to v2 exist today:

1. **Conditional v2 output.** `_build_write_build_summary` in `lib/summary.sh` emits `result_contract:2`, `disposition`, and `reason` only when `build_disposition != ""`. The `scope_violation` branch and the normal-pass branch (done_sentinel + changed files) both leave `build_disposition` empty, so those result files are v1-shaped: no `result_contract`, no `disposition`. The engine's `_verdict_probe_contract` reads the result file at dispatch; a missing key reads as v1 and skips the disposition validation that a v2 plugin is supposed to satisfy.

2. **Non-binary exit codes.** `build_stage_run` returns `rc=2` when the `state_file` argument is absent. `_build_stage_run_inner` returns `rc=2` when `plan.json` is missing (before writing any result file) and `rc=130` on SIGINT (also before writing any result). ADR-054 §4b: a v2 stage is held to `rc∈{0,1}`; everything else belongs in `disposition`. The `rc=130` SIGINT propagation must still work, but the method changes: write a v2 `disposition:interrupted` result, return `1`, and let the ADR-025 abort sentinel carry the abort signal across subshells.

3. **Hardcoded input paths.** `build_stage_run` constructs `scope_manifest` as `"$state_dir/scope-manifest.md"` and `plan_json_path` as `"$artifacts_dir/plan.json"`. ADR-055 §1 / #1826: the engine resolves each declared input and hands the index to the hook via `ZBUILD_STAGE_INPUTS`. The plugin should read from the index when it is present; the hardcoded derivation remains as the fallback for callers (e.g. unit tests) that do not export the index.

**Decision.** Four file groups change together:

- **`manifest.yaml`** — add `result_contract: 2` to `provides:`; add `config.router:` section to make the budget parameters the plugin already uses data-driven per ADR-017 §8.
- **`lib/summary.sh`** — make `result_contract:2` unconditional in the jq template; add `disposition: "complete"` to the normal-pass branch; add `disposition: "broken"` and a `reason` to the `scope_violation` branch.
- **`plugin.sh`** — `build_stage_run` reads `scope_manifest` and `plan` paths from `ZBUILD_STAGE_INPUTS` (falls back to hardcoded derivation when unset); `build_stage_run` returns `rc=1` (not `rc=2`) for a missing `state_file`; `_build_stage_run_inner` writes a v2 interrupted result and returns `rc=1` for missing `plan.json` and for the SIGINT path (was `rc=2` and `rc=130`).
- **`tests/build-test.sh`** — update T2 assertion from `rc=2` to `rc=1`; add SPEC-tagged assertions for unconditional `result_contract:2`, `disposition` on the scope_violation branch, `disposition` on the normal-pass branch, and ZBUILD_STAGE_INPUTS-based input resolution.

```scope
plugins/agent/build/manifest.yaml
plugins/agent/build/plugin.sh
plugins/agent/build/lib/summary.sh
plugins/agent/build/lib/context.sh
plugins/agent/build/lib/commit.sh
plugins/agent/build/lib/diff.sh
plugins/agent/build/lib/prompt.sh
plugins/agent/build/lib/scope.sh
plugins/agent/build/tests/build-test.sh
tests/unit/build-false-completion-guard-test.sh
tests/unit/build-no-progress-diagnostic-test.sh
tests/unit/build-scope-expansion-test.sh
tests/unit/build-acceptance-charter-test.sh
tests/unit/build-acceptance-spec-feedback-test.sh
tests/unit/build-design-decisions-test.sh
tests/unit/build-diff-cumulative-test.sh
tests/unit/build-discrepancy-warn-inside-banner-test.sh
tests/unit/build-edited-oos-request-test.sh
tests/unit/build-lib-source-wiring-test.sh
tests/unit/build-nul-detection-test.sh
tests/unit/build-oos-pass-request-test.sh
tests/unit/build-persona-framing-test.sh
tests/unit/build-plugin-commit-msg-parser-test.sh
tests/unit/build-prompt-framing-test.sh
tests/unit/build-prompt-loop-complete-rule-test.sh
tests/unit/build-prompt-override-test.sh
tests/unit/build-timeout-banner-clean-iter-test.sh
tests/unit/build-timeout-scope-violation-preserves-inscope-test.sh
tests/unit/build-timeout-truncation-banner-test.sh
tests/integration/build-empty-diff-done-sentinel-test.sh
tests/integration/build-banner-llm-prompt-visible-test.sh
tests/integration/build-changed-files-summary-test.sh
tests/integration/build-commit-msg-multi-inner-iter-test.sh
tests/integration/build-created-oos-still-violation-test.sh
tests/integration/build-loop-banner-test.sh
tests/integration/build-no-stash-flow-test.sh
tests/integration/build-preexisting-untracked-not-violation-test.sh
tests/integration/build-prompt-includes-branch-state-end-to-end-test.sh
tests/integration/build-test-cycle-fallthrough-to-review-test.sh
tests/integration/build-test-cycle-multi-iter-test.sh
tests/integration/build-test-cycle-progress-test.sh
tests/integration/build-test-cycle-targeted-rerun-test.sh
tests/integration/cycle-no-committed-changes-fail-fast-test.sh
tests/integration/cycle-scope-violation-no-commit-test.sh
tests/integration/dispatch-rc-signal-boundary-test.sh
tests/integration/write-boundary-dispatch-test.sh
tests/unit/core-contract-version-test.sh
tests/unit/core-pipeline-disposition-test.sh
tests/unit/core-pipeline-verdict-test.sh
tests/unit/convergence-timeouts-never-fatal-1208-test.sh
tests/unit/dispatch-rc-test.sh
tests/unit/dispatch-rc-guard-test.sh
tests/unit/docs-adr-054-references-test.sh
tests/unit/lifecycle-required-output-test.sh
tests/unit/plugin-manifest-contract-audit-test.sh
tests/unit/preflight-lint-parity-test.sh
tests/unit/stage-input-resolve-test.sh
core/contract/version.sh
core/pipeline/disposition.sh
core/pipeline/input-resolve.sh
core/pipeline/verdict.sh
core/plugin-registry/lifecycle.sh
core/plugin-registry/manifest-validation.sh
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/wiki/plugins/build.md
```

```acceptance
SPEC-1[change]: build-summary.json carries result_contract:2 on the normal-pass branch (done_sentinel + changed files, no prior scope_violation)
SPEC-2[change]: build-summary.json carries disposition:complete on the normal-pass branch
SPEC-3[change]: build-summary.json carries result_contract:2 on the scope_violation branch
SPEC-4[change]: build-summary.json carries disposition:broken on the scope_violation branch
SPEC-5[change]: _build_stage_run_inner returns rc=1 (not rc=2) when plan.json is missing
SPEC-6[change]: build_stage_run reads scope_manifest path from ZBUILD_STAGE_INPUTS when that env var names a non-empty file
SPEC-7[change]: build_stage_run reads plan path from ZBUILD_STAGE_INPUTS when that env var names a non-empty file
SPEC-8[change]: manifest.yaml declares result_contract:2 under provides
SPEC-9[guard]: build-summary.json carries result_contract:2, disposition:interrupted on the router_timeout/error branch (unchanged from prior work)
SPEC-10[guard]: build-summary.json carries result_contract:2, disposition:broken, data.build_kind=inert_build on the false-completion branch (unchanged from prior work)
SPEC-11[guard]: build-summary.json schema_version remains 4 (result_contract and schema_version are independent keys)
SPEC-12[guard]: disposition values emitted by the build plugin are all members of the engine's closed vocabulary (complete, interrupted, broken)
WIRING:
plugins/agent/build/manifest.yaml
plugins/agent/build/lib/summary.sh
TESTFILES:
SPEC-1: plugins/agent/build/tests/build-test.sh
SPEC-2: plugins/agent/build/tests/build-test.sh
SPEC-3: plugins/agent/build/tests/build-test.sh
SPEC-4: plugins/agent/build/tests/build-test.sh
SPEC-5: plugins/agent/build/tests/build-test.sh
SPEC-6: plugins/agent/build/tests/build-test.sh
SPEC-7: plugins/agent/build/tests/build-test.sh
SPEC-8: plugins/agent/build/tests/build-test.sh
SPEC-9: tests/unit/convergence-timeouts-never-fatal-1208-test.sh
SPEC-10: tests/unit/build-false-completion-guard-test.sh
SPEC-11: plugins/agent/build/tests/build-test.sh
SPEC-12: tests/unit/core-pipeline-disposition-test.sh
```

LOOP_COMPLETE
