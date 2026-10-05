# Plan checkpoint — issue #2032

## Files read and key findings

- cycle-orchestrator.sh: `_iter_did_not_finish` computed at ~2541-2548 from ALL members. Build-specific suppression at ~2575-2579. No-committed-changes guard at ~2613-2619. Generic suppression (§4/A) must go between build-specific block end and no-committed-changes block start.
- spec-coverage/plugin.sh: `route_to_model ... || true` at ~187; fallback path at ~201 writes `_scv_write` with hardcoded 'complete'. Needs rc capture + router_reason_disposition.
- spec-correspondence/plugin.sh: `route_to_model ... || true` at ~121; `_sc_write_result` hardcodes `disposition: "complete"` at ~167. Needs rc capture + router_reason_disposition.
- review-report/plugin.sh: `_disposition="complete"` hardcoded at ~174 for failed-lens path. Has `_rr_write_v2` that accepts disposition arg. Needs per-lens rc tracking + router_reason_disposition.
- router-rc-classify.sh: `router_reason_disposition` at line 259 — confirmed exists.
- tests/integration/cycle-member-unfinished-no-convergence-test.sh: does NOT exist (net-new).
- tests/unit/{spec-coverage,spec-correspondence,review-report-v2-contract}-test.sh: all exist.
- Integration test reference: tests/integration/cycle-multi-iter-cumulative-test.sh exists.

## Conclusions

Prior plan is accurate and verified. All 7 steps are still needed. No steps have been implemented yet on this branch (branch is clean).

## What to do next

Emit the plan JSON.
