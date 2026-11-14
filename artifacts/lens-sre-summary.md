## review-lens-sre — fail

- found: medium: The new no_done_sentinel / router_out_of_turns branch emits build.discrepancy.detected but omits a warn call, so if the events JSONL is unavailable the discrepancy is completely silent; the done_sentinel branch one block above defends against this with an explicit warn to stderr. (plugins/agent/build/lib/summary.sh) (and 1 more)

- medium: The new no_done_sentinel / router_out_of_turns branch emits build.discrepancy.detected but omits a warn call, so if the events JSONL is unavailable the discrepancy is completely silent; the done_sentinel branch one block above defends against this with an explicit warn to stderr. (plugins/agent/build/lib/summary.sh)
- low: The _route_reasons grep scans the entire route.sh rather than only the body of route_to_model_loop, so a _ROUTE_LOOP_TERMINATED_REASON= assignment in any helper (e.g. _route_signal_handler already contributes 'signal' this way) is counted as a required comment token even if route_to_model_loop never reaches it, enforcing slightly more than the stated invariant. (tests/unit/route-loop-terminated-reasons-test.sh)
- score: 8
