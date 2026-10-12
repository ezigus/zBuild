# Spec-Correspondence Checkpoint

## Approach
All REQUIREMENT and ASSERTION text is provided inline. No implementation files need to be read — judging structural fit only.

## Conclusions reached

SPEC-1: partial — assertion checks timed_out string exists but not that it names the stage and limit
SPEC-2: corresponds — all structural checks (set -m, zbuild_pg_kill, _zbuild_pg_term_then_kill, >=10s grace) establish the requirement
SPEC-3: partial — tier 2 (env beats engine default) is not tested in isolation; unset is accepted, which doesn't confirm env is applied over the default
SPEC-4: corresponds — both rejection cases (below-router and non-integer) plus boundary cases all tested
SPEC-5: corresponds — watchdog inside plugin_hook_call + map.sh + runner.sh calling it establishes fresh independent timers
SPEC-6: partial — _check_stage_timeout function defined but explicit per-stage calls for enumerated stages not shown in assertion body
SPEC-7: partial — checks ZBUILD_ORCH_TIMEOUT absent from strategy files but behavioral completion (>300s dispatch survives) not directly verified
SPEC-8: corresponds — directory absent, no external refs, misconfigured behavior all checked
SPEC-9: partial — "config unreadable" case not tested; only "cannot be found" case covered
SPEC-10: partial — local_engine.sh not checked for absence of hand-rolled TERM/KILL, only zbuild_pg_kill presence
SPEC-11: corresponds — all three ADRs checked for Enforced by and removed from baseline
SPEC-17: partial — orch-mock existence confirmed but watchdog behavior under orch-mock not actually exercised

## Status: complete
