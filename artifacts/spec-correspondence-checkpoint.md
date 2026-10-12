# Spec-Correspondence Checkpoint

## Analysis method
Judging each SPEC pair from assertion text as provided — no additional repo reads needed.
Prior round explored test files; this round re-derives verdicts from careful literal reading.

## Per-SPEC analysis

### SPEC-1
REQ: timed_out on EVERY route (map, fanout, sequential, roleless leaf, cycle member,
parallel-group member, and always_run) under EVERY backend.
ASSERTION: checks fanout.sh, sequential.sh, map.sh, runner.sh call plugin_hook_call.
Gap: always_run route dispatches through _runner_dispatch_always_run (not plugin_hook_call) —
not covered. parallel-group member route also not explicitly verified.
Verdict: partial

### SPEC-2
REQ: both internal watchdog path AND external-SIGTERM path kill entire group; TERM-ignoring
child dies.
ASSERTION: structural checks for internal path (set -m, zbuild_pg_kill, _zbuild_pg_term_then_kill,
grace>=10s) PLUS full behavioral test for external SIGTERM (SPEC-2ext section: setsid + 
BUILD_RUN_SPAWN_IGNORE_TERM=1 + send TERM to runner + verify TERM-ignoring child dead).
Both paths covered; TERM+grace+KILL means KILL fires even for TERM-ignorers.
Previous checkpoint said "partial" but the external SIGTERM behavioral test IS present in
the assertion text.
Verdict: corresponds

### SPEC-3
REQ: each tier verified IN ISOLATION.
ASSERTION: tier-1 (template 7200 beats env 99) — behavioral isolation ✓.
Tier-2 (env beats 5400) — structural (ZBUILD_STAGE_TIMEOUT_S in plugin_hook_call) +
beta-stage behavioral implication.
Tier-3 (5400 default) — structural only (5400 appears anywhere in lifecycle.sh or runner.sh).
No isolation test runs with neither template value nor ZBUILD_STAGE_TIMEOUT_S unset to verify
5400 is used at runtime.
Verdict: partial

### SPEC-4
REQ: reject below router.timeout_s; reject non-integer.
ASSERTION: low (30<600 → rc=1), non-integer "1h" → rc=1, valid >= (1200>=600 → rc=0),
no-router (900 → rc=0), equal (600=600 → rc=0). All rejection and acceptance cases covered.
Verdict: corresponds

### SPEC-5
REQ: retried stage and each map member get fresh independent timer.
ASSERTION: watchdog (zbuild_pg_kill + sleep/timeout) INSIDE plugin_hook_call → each call
spawns a fresh background timer. map.sh and runner.sh both call plugin_hook_call → each
map member and each retry gets its own invocation → fresh timer. Structural proof is sound.
Verdict: corresponds

### SPEC-6
REQ: _runner_dispatch_always_run reads stage_timeout_s; simple.yaml has specific values;
router.timeout_s absent from always_run stages.
ASSERTION: _TPL_STAGE_TIMEOUT_S_* in _ar_body; _check_stage_timeout function called for each
named stage; no router.timeout_s in always_run stages. Prior round confirmed all stage names
covered in full test file.
Verdict: corresponds

### SPEC-7
REQ: removing ZBUILD_ORCH_TIMEOUT means a plan dispatch running >300s but within
stage_timeout_s COMPLETES WITHOUT BEING KILLED.
ASSERTION: ZBUILD_ORCH_TIMEOUT absent in three files; no --timeout in orch calls.
Gap: establishes absence of the known flat ceiling but does not demonstrate a long dispatch
actually completes — other kill mechanisms could still fire.
Verdict: partial

### SPEC-8
REQ: directory absent; guard fails on any reference outside named exclusions; sequential
backend → misconfigured.
ASSERTION: checks directory absent; _bad_refs empty (with exclusions applied elsewhere);
misconfigured signal in output. All three parts covered.
Verdict: corresponds

### SPEC-9
REQ: cannot-be-found OR config-is-unreadable fails as misconfigured NAMING the backend.
ASSERTION: unknown alias → output contains "misconfigured" AND "no-such-backend" (name
present) ✓. Unreadable config (_reported_exit4) → non-zero rc only; the requirement
that it names the backend is not verified for the unreadable-config case.
Verdict: partial

### SPEC-10
REQ: _runner_dispatch_always_run and _orch_local_collect_results kill through zbuild_pg_kill;
no hand-rolled TERM/KILL remains.
ASSERTION: plugin_hook_call has no hand-rolled TERM/KILL; local_engine.sh has zbuild_pg_kill,
no _orch_local_kill_slot; _runner_dispatch_always_run has zbuild_pg_kill, no hand-rolled;
lifecycle.sh has zbuild_pg_kill. If all pass, all named requirements are met.
Verdict: corresponds

### SPEC-11
REQ: ADR-054, ADR-017, ADR-011 each have ## Enforced by section; removed from baseline.txt.
ASSERTION: checks all three ADRs for ## Enforced by; checks none are in baseline.
Verdict: corresponds

### SPEC-18
REQ: both types registered in event-schema.json AND event-schema-emitted-coverage-test passes.
ASSERTION: checks registration of both types only. No check that the coverage test actually
passes. Registration is necessary but not sufficient — other unregistered emitted events
could still fail the coverage test.
Previous checkpoint said "corresponds" but the coverage-test-pass clause is not established.
Verdict: partial

## Final verdicts
SPEC-1: partial
SPEC-2: corresponds
SPEC-3: partial
SPEC-4: corresponds
SPEC-5: corresponds
SPEC-6: corresponds
SPEC-7: partial
SPEC-8: corresponds
SPEC-9: partial
SPEC-10: corresponds
SPEC-11: corresponds
SPEC-18: partial

## Status: complete
