# Design: Migrate build plugin to result_contract:2 (issue #1833)

## Architectural Decision Summary

**Goal.** Complete the build plugin's migration to ADR-054 Stage Contract v2 by closing the two implementation gaps `fdaa186` left open and adding the one missing grep-based assertion.

**Context.** `fdaa186` shipped: unconditional `result_contract:2` / `disposition` in `lib/summary.sh`, rc=1 for state_file-missing / plan.json-missing / SIGINT, ZBUILD_STAGE_INPUTS reading for `scope_manifest` and `plan` in `build_stage_run`, and `result_contract:2` + `config.router` in `manifest.yaml`. Two gaps survive:

1. **rc∈{0,1} gap — `plugin.sh:114`.** The early-arg guard in `_build_stage_run_inner` (`if [[ -z "$scope_manifest" || … ]]`) still returns `rc=2`. ADR-054 §4b requires `rc∈{0,1}`. Writing a v2 result file is not possible here because `output_summary_json` is itself one of the guarded args; the fix is `return 2` → `return 1`.

2. **no-path-construction gap — `lib/context.sh:172`.** `_build_load_context` sets `_ctx_design_md_path="$artifact_dir/design.md"` with a hardcoded fallback; it never reads `.inputs.design` from ZBUILD_STAGE_INPUTS. The manifest already declares `design` as an optional input (ADR-055 §1). Fix: at the top of `_build_load_context`, check ZBUILD_STAGE_INPUTS for `.inputs.design` and use that path when present and non-empty; keep the existing hardcoded derivation as the fallback for callers that do not export the index (unit tests).

**Missing grep-assertion.** The SPEC-7 test (lines 873–931 of `build-test.sh`) asserts only that `build_stage_run` returns rc=0 when ZBUILD_STAGE_INPUTS names custom paths (`assert_pass "[SPEC-7]"`). For a robust negative control the test must also assert that the artifact the custom plan targeted (`si-test.txt`) actually appears in the resulting `diff.patch`. At merge-base ZBUILD_STAGE_INPUTS is not read: the default plan path is absent, the inner run fails before writing a diff, and the grep-assertion fails. After the fix the custom plan is loaded, the mock loop creates `si-test.txt`, and the diff captures it. This is the third change: add `assert_contains "[SPEC-7] ..." "$(cat .../diff.patch)" "si-test.txt"` to the existing SPEC-7 subsection.

**Decision.** Three targeted changes:

- **`plugin.sh:114`** — `return 2` → `return 1` in the missing-args guard of `_build_stage_run_inner`.
- **`lib/context.sh`** — read `design` from ZBUILD_STAGE_INPUTS at the top of `_build_load_context`; the existing hardcoded derivation remains as the fallback.
- **`tests/build-test.sh`** — (a) add `assert_contains "[SPEC-7] …" … "si-test.txt"` inside the existing SPEC-6/7 section; (b) add a SPEC-15 subsection: call `_build_stage_run_inner "" …` and assert rc=1; (c) add a SPEC-16 subsection: supply a ZBUILD_STAGE_INPUTS index with a custom `design.md` and assert the build prompt contains acceptance text from that file.

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
tests/unit/build-prompt-spec-text-test.sh
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
docs/adr/ADR-060-stages-return-structure.md
docs/wiki/plugins/build.md
```

```acceptance
SPEC-1[change]: build-summary.json carries result_contract:2 on the normal-pass branch (done_sentinel + changed files, no prior scope_violation)
SPEC-2[change]: build-summary.json carries disposition:complete on the normal-pass branch (done_sentinel + changed files)
SPEC-3[change]: build-summary.json carries result_contract:2 on the scope_violation branch
SPEC-4[change]: build-summary.json carries disposition:broken on the scope_violation branch
SPEC-5[change]: _build_stage_run_inner returns rc=1 (not rc=2) when plan.json is missing
SPEC-6[change]: build_stage_run reads scope_manifest path from ZBUILD_STAGE_INPUTS when that env var names a non-empty index file
SPEC-7[change]: build_stage_run reads plan path from ZBUILD_STAGE_INPUTS when that env var names a non-empty index file; the diff.patch produced by that run references the file declared in the custom plan (grep assertion)
SPEC-8[change]: manifest.yaml declares result_contract:2 under provides
SPEC-9[guard]: build-summary.json carries result_contract:2, disposition:interrupted on the router_timeout/error branch (unchanged from prior work)
SPEC-10[guard]: build-summary.json carries result_contract:2, disposition:broken, data.build_kind=inert_build on the false-completion branch (unchanged from prior work)
SPEC-11[guard]: build-summary.json schema_version remains 4 (result_contract and schema_version are independent keys)
SPEC-12[guard]: disposition values emitted by the build plugin are all members of the engine's closed vocabulary (complete, interrupted, broken)
SPEC-13[change]: build_stage_run returns rc=1 (not rc=2) when state_file argument is absent
SPEC-14[change]: _build_stage_run_inner writes a v2 disposition:interrupted result to output_summary_json and returns rc=1 (not rc=130) when route_to_model_loop signals SIGINT (router_rc=130)
SPEC-15[change]: _build_stage_run_inner returns rc=1 (not rc=2) when required function arguments (scope_manifest, plan_json_path, output_diff_patch, output_summary_json) are absent — the early-arg guard at plugin.sh:114
SPEC-16[change]: _build_load_context reads design.md path from ZBUILD_STAGE_INPUTS when that env var names a non-empty index file containing .inputs.design; the custom design.md's acceptance spec text appears in the build prompt
WIRING:
plugins/agent/build/manifest.yaml
plugins/agent/build/lib/summary.sh
plugins/agent/build/plugin.sh
plugins/agent/build/lib/context.sh
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
SPEC-13: plugins/agent/build/tests/build-test.sh
SPEC-14: plugins/agent/build/tests/build-test.sh
SPEC-15: plugins/agent/build/tests/build-test.sh
SPEC-16: plugins/agent/build/tests/build-test.sh
```

LOOP_COMPLETE
