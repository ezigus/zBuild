# Plan Checkpoint

## Files read and key findings

- `core/pipeline/cycle-orchestrator.sh:2541-2580`: `_iter_did_not_finish` computed at 2541-2548 from ALL members via `disposition_unfinished`. Build-specific suppression at 2575-2580 (`converged=1` when `disposition_unfinished "$_build_disposition"`). Generic suppression for ANY unfinished member goes after `fi` at line 2580.
- `plugins/agent/spec-coverage/plugin.sh:100-116`: `_scv_write` signature is `dir v r u`; hardcodes `disposition: "complete"` at line 108. `route_to_model` at line 187 uses `|| true` swallowing rc. When model returns empty, line 200-203 calls `_scv_write` with verdict `"unreadable"` but still hardcoded `complete` disposition.
- `plugins/agent/spec-correspondence/plugin.sh:120-167`: `route_to_model` at line 121 uses `|| true`. `_sc_write_result` at line 166-168 hardcodes `disposition: "complete"`.
- `plugins/agent/review-report/plugin.sh:167-175`: Reads lens `.rc` files; hardcodes `_disposition="complete"` at 172-174 even when lenses failed, with comment `# #2187: the report ran; each lens reports its own cause` — this is wrong per issue §3/B scope.
- `scripts/lib/router-rc-classify.sh:280`: `router_reason_disposition` confirmed at this line (prior plan said 259, minor discrepancy but same file).
- `tests/integration/cycle-member-unfinished-no-convergence-test.sh`: DOES NOT EXIST — new file.
- `tests/unit/spec-coverage-test.sh`, `tests/unit/spec-correspondence-test.sh`, `tests/unit/review-report-v2-contract-test.sh`: All exist.

## Conclusions

Prior plan is accurate. All 7 steps are confirmed valid. The plan below should proceed as written.

## What to do next

Emit plan JSON — all information gathered.
