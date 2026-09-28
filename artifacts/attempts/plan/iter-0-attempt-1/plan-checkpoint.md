# Plan checkpoint — issue 1837 (migrate intake plugin to contract v2)

## COMPLETE — emitting plan JSON now

### Files read and key findings
1. `plugins/agent/intake/manifest.yaml` — v1, no result_contract, primary: true on scope-manifest (markdown, not JSON), valid_verdicts: [], inputs: [], config.tier_default: T1, has provides.role/events.
2. `plugins/agent/intake/plugin.sh` — 5 `return 2` in intake_run, no result JSON written, writes scope-manifest.md and intake.md to state_dir via atomic_write.
3. `core/contract/version.sh` — v2 is integer 2, v1 and v2 coexist.
4. `plugins/tool/teardown/plugin.sh` — reference: writes teardown-result.json with result_contract:2, verdict, disposition, reason, data fields.
5. `plugins/agent/plan/manifest.yaml` — shows router: block under config: with retries, etc.
6. `plugins/agent/security-lens/manifest.yaml` — v2, router: timeout_s, max_turns under config:.
7. `plugins/agent/intake/tests/intake-test.sh` — 10 rc=2 assertions (all in intake_run paths), ~620 lines.
8. `plugins/agent/intake/tests/intake-branch-test.sh` — tests _intake_create_workspace_branch directly (lib function), NOT intake_run; rc=2 assertions there DON'T need updating.
9. `core/pipeline/disposition.sh` — closed set: complete, unusable, timed_out, out_of_turns, interrupted, throttled, rate_limited, unavailable, misconfigured, broken.
10. `ADR-054` — rc ∈ {0,1}, primary output must be JSON result with result_contract/verdict/disposition/reason, cleanup absent if no resources.

### Key decisions
- New primary output: `intake-result.json` (JSON result file); scope_manifest drops primary:true.
- valid_verdicts: [pass, fail] — pass on success, fail on any refusal/error.
- Dispositions: unavailable for closed issue / failed fetch; misconfigured for missing goal; broken for engine contract violations; complete for success.
- rc=2 in intake_run → rc=1 (lib functions keep their own codes; intake_run normalizes).
- intake-branch-test.sh rc=2 tests: no changes needed (test lib, not intake_run).
- Router budget: intake makes no LLM calls today but is T1 agent; declare minimal budget per #1816 mandate.
- cleanup hook: absent (intake holds no live resources); recorded in manifest comment and test.
- inputs: stays [] (external source: GitHub API, not declared inter-stage).
