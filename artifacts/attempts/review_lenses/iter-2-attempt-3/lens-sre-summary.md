## review-lens-sre — fail

- found: medium: The new no_done_sentinel/router_out_of_turns branch emits build.discrepancy.detected with the event bus call fully silenced (>/dev/null 2>&1 || true) and no stderr warn fallback, so if the event bus is unavailable the discrepancy is completely invisible; the done_sentinel branch one block above explicitly defends against this with a warn to stderr that survives an event-bus failure. (plugins/agent/build/lib/summary.sh)

- medium: The new no_done_sentinel/router_out_of_turns branch emits build.discrepancy.detected with the event bus call fully silenced (>/dev/null 2>&1 || true) and no stderr warn fallback, so if the event bus is unavailable the discrepancy is completely invisible; the done_sentinel branch one block above explicitly defends against this with a warn to stderr that survives an event-bus failure. (plugins/agent/build/lib/summary.sh)
- score: 8
