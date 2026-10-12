## spec-correspondence — partial

- judged 12 SPEC(s): 5 correspond, 7 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion verifies `timed_out` appears somewhere in lifecycle.sh or runner.sh, but does not verify the disposition is emitted with the stage name and the limit, which the requirement explicitly demands.
- SPEC-3 partial: Tier 1 (template beats env) and tier 3 (5400 default exists) are each verified in isolation, but tier 2 (env beats 5400 engine default) is not — accepting "unset" for `_TPL_STAGE_TIMEOUT_S_beta` only confirms the template did not hard-code the value, not that the env variable is actually applied over the default at dispatch time.
- SPEC-6 partial: The assertion verifies `_runner_dispatch_always_run` reads `_TPL_STAGE_TIMEOUT_S_*` and that always_run stages lack `router.timeout_s`, but the `_check_stage_timeout` function is defined without explicit calls shown for the full enumerated list of stage/value pairs the requirement mandates.
- SPEC-7 partial: The assertion confirms `ZBUILD_ORCH_TIMEOUT` is absent from the three strategy files, but does not verify the absence of any other flat ceiling or demonstrate that a dispatch running longer than 300 s within its `stage_timeout_s` actually completes without being killed.
- SPEC-9 partial: The assertion tests the "cannot be found" case and verifies the backend name appears in output, but the second condition — "whose config is unreadable" — has no corresponding test case.
- SPEC-10 partial: `zbuild_pg_kill` presence is confirmed in local_engine.sh and the named functions, but hand-rolled `kill -TERM/-KILL` sequences are only explicitly checked for absence in `plugin_hook_call` and one specific pattern in `_runner_dispatch_always_run`; local_engine.sh is not grepped for remaining hand-rolled sequences.
- SPEC-17 partial: The assertion confirms orch-ruflo-hive carries no suppressing TERM/KILL sequence, but only checks that orch-mock/plugin.sh exists — it does not exercise the watchdog with a hanging hook under orch-mock to confirm the lifecycle-level kill fires backend-agnostically.

