# Design notes — issue #1769

## Goal
Emit `build.discrepancy.detected` for two additional end-reason cases where
zero files were changed: `no_done_sentinel` (LLM gave up without saying done)
and `router_out_of_turns` (budget exhausted). The `done_sentinel` path is
unchanged. Also update the route.sh comment to enumerate all end reasons
concretely (no "a _router_rc_classify reason" shorthand).

## Files to change

### plugins/agent/build/lib/summary.sh — _build_emit_changed_files_summary
Current guard (in base-code):
```bash
if [[ "$terminated_reason" == "done_sentinel" && "$files_count" -eq 0 \
      && "$scope_violation_mode" != "true" ]]; then
```
Needs to be: also emit for no_done_sentinel and router_out_of_turns when
files_count == 0. The existing done_sentinel branch already fires
build.diff.empty_after_done_sentinel; the new branches don't (that event is
specific to done_sentinel). The event payload must include
`terminated_reason=$terminated_reason`.

### core/router/route.sh — comment only (RQLOCK-2)
The comment near _ROUTE_LOOP_TERMINATED_REASON in base-code uses the shorthand
"a _router_rc_classify reason". Must become an exhaustive list.
Full set from code:
- Assigned directly in route_to_model_loop: done_sentinel, no_done_sentinel,
  router_timeout, router_rate_limited, signal, router_budget_exceeded,
  router_config_error, router_rc_nonzero
- Returned by _router_rc_classify (via _fail_reason): router_timeout,
  router_oom_kill, router_config_error, router_rc_nonzero, router_rate_limited,
  router_out_of_turns
Deduped full set:
  done_sentinel | no_done_sentinel | router_timeout | router_rate_limited |
  router_oom_kill | router_out_of_turns | router_budget_exceeded |
  router_config_error | router_rc_nonzero | signal

## SPEC ids used
DSDIFF-1[code], DSDIFF-2[code], DSDIFF-3[done], DSEND-1[code],
DSLOCK-1[done], DSLOCK-2[done], DSLOCK-3[done]

## Wiring
WIRING: none

Rationale: `plugins/agent/build/plugin.sh` already calls
`_build_emit_changed_files_summary` before this change and is NOT modified
by this PR. The pipeline WIRING check verifies the named file is actually
changed; since plugin.sh is not changed, the check failed with
REACHABILITY FAIL wiring_not_on_path. The only changed non-comment file is
summary.sh (the implementation), which is not the caller. The route.sh
change is comment-only (REACHABILITY SKIP no_code). Hence WIRING: none.

## Locks verified
- RQLOCK-1: no_done_sentinel and router_out_of_turns already exist in base-code
- RQLOCK-2: only the comment in route.sh changes (design enforced); covered by DSEND-1
- RQLOCK-3: router-rc-classify.sh not touched; DSLOCK-2 proves it via observable call behavior
- RQLOCK-4: O4 in route-one-call-per-try-test.sh not touched

## Round history
- Round 2: Fixed DSLOCK-2 to describe observable function behavior instead of file contents
- Round 3: Fixed WIRING from plugins/agent/build/plugin.sh to none — plugin.sh
  already calls summary.sh and is not changed by this PR; pipeline's reachability
  check confirmed it was not on the change path.
