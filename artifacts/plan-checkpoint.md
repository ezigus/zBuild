# Plan checkpoint — issue #1838 (impact v2 migration)

## Files read and key findings

- `plugins/agent/impact/manifest.yaml`: has valid_verdicts declared, provides.role+events declared, primary:true output declared. NO result_contract:2, NO router: section in config, inputs have NO from:/source:/path fields (already name-matched by id only). Cleanup comment stub exists at end of plugin.sh but no hook body.
- `plugins/agent/impact/plugin.sh`: impact_run constructs hardcoded paths from state_dir. No v2 result writing anywhere. Uses return 2 on contract violations. No signal handler. ~562 lines.
- `core/pipeline/disposition.sh`: closed disposition set: complete, unusable, timed_out, out_of_turns, interrupted, throttled, rate_limited, unavailable, misconfigured, broken. disposition_response() is the response table.
- `scripts/lib/router-rc-classify.sh`: router_reason_disposition() maps reason strings to disposition words.
- `plugins/agent/plan/lib/entry.sh`: canonical v2 migration template: _plan_write_result, _plan_input (reads ZBUILD_STAGE_INPUTS), stage_signal_begin/end, _plan_on_signal, ZBUILD_ARTIFACT_DIR for output dir.
- `plugins/tool/teardown/plugin.sh + manifest.yaml`: result_contract:2 in manifest, v2 result written via atomic_write with disposition:"complete".
- `core/pipeline/input-resolve.sh`: engine writes stage-inputs/<stage>.json index, exposes as ZBUILD_STAGE_INPUTS. stage_inputs_prompt_block puts resolved paths in the agent's prompt. Plugin reads via ZBUILD_STAGE_INPUTS env var (same pattern as plan).
- `config/templates/simple.yaml` lines 356-373: template defines impact router: timeout_s:600, max_turns:45, retries:1. Template overrides win.
- `scripts/lib/stage-signal.sh`: stage_signal_begin/end already sourced by plugin-bootstrap.sh; no additional source needed in plugin.sh.
- `tests/unit/impact-max-turns-test.sh`: existing test pins template max_turns:45 / timeout_s:600.
- `tests/unit/` — existing impact tests: envelope-recovery, hallucination-filter, max-turns, persona-framing, prefilter-order-detector, prefilter, prompt-override, scope-plateau, tier. No v2 result contract test yet.
- `plugins/agent/impact/tests/impact-prompt-contract-test.sh`: one plugin-local test.
- `plugins/agent/plan/manifest.yaml`: router: section under config with retries:1, retry_on_exhaustion:1, timeout_s:300, max_turns:45.

## Conclusions

1. manifest.yaml needs: result_contract:2 in provides, router: section in config (timeout_s:600, max_turns:45 as manifest defaults; template wins), no cleanup hook (nothing to free).
2. plugin.sh needs: _impact_write_result, _impact_input, signal handler, ZBUILD_ARTIFACT_DIR, ZBUILD_STAGE_INPUTS, v2 result on every exit path, router_reason_disposition for disposition, return 1 not return 2.
3. Tests needed (TDD order): v2-result-contract test first (all exit paths), disposition-mapping test, no-path-construction grep test, valid_verdicts coverage test, golden snapshot update.

## What next if stopped

Emit the plan JSON with these steps.
