# Plan checkpoint — issue 1837 (migrate intake plugin to contract v2)

## COMPLETE — emitting plan JSON now

### Files read and key findings
1. `plugins/agent/intake/manifest.yaml` — v1, no result_contract, primary: true on scope_manifest (markdown), valid_verdicts: [], inputs: [], config.tier_default: T1, has provides.role/events.
2. `plugins/agent/intake/plugin.sh` — 5 `return 2` in intake_run (lines 161, 165, 175, 186) + `return $_branch_rc` (line 242) that passes raw lib rc; no result JSON written; `_intake_art` computed early from dirname(state_file)/artifacts.
3. `plugins/tool/teardown/plugin.sh` — reference pattern for writing v2 result: `printf '%s\n' "{ ... }" | atomic_write "$_result_file"`.
4. `plugins/agent/security-lens/manifest.yaml` — router: timeout_s/max_turns pattern under config:.
5. `plugins/agent/intake/tests/intake-test.sh` — 624 lines; 10 rc=2 assertions (all intake_run paths); lines 80, 187, 371, 394, 406, 418, 540 etc.
6. `core/pipeline/disposition.sh` — valid dispositions: complete, unusable, timed_out, out_of_turns, interrupted, throttled, rate_limited, unavailable, misconfigured, broken.

### Key decisions
- New primary output: `intake-result.json`; scope_manifest drops primary:true.
- valid_verdicts: [pass, fail].
- Dispositions: unavailable for closed/locked issue + failed fetch; misconfigured for missing goal/branch refusal; broken for engine violations + empty sanitized; complete for success.
- rc=2 → rc=1 in intake_run for all direct return 2; branch path normalized to return 1 (not $_branch_rc).
- _intake_art early computation already handles most paths; state_file-empty path falls back to ZBUILD_ARTIFACT_DIR.
- router budget: timeout_s: 120, max_turns: 0 (no LLM calls).
- cleanup hook: absent; recorded in manifest comment.
- intake-branch-test.sh: no changes (tests lib, not intake_run).
