# Plan Checkpoint — Issue #2032

## Files Read and What They Told Me

- `core/pipeline/cycle-orchestrator.sh:2565-2613` — `_iter_did_not_finish` (line 2574) is computed from ALL members' dispositions (lines 2577-2581) via `disposition_unfinished`, but is ONLY used by the exhaustion halt. The convergence suppression at 2608 only checks `_build_disposition`. Comment at 2570-2573 explicitly says "Consumed ONLY by the reason-aware exhaustion halt below". Fix: add a second suppression block after 2613 using `_iter_did_not_finish`, update comment.

- `core/pipeline/disposition.sh` — `disposition_unfinished()` returns rc=0 for `timed_out`, `out_of_turns`, `interrupted`.

- `scripts/lib/router-rc-classify.sh` — `router_reason_disposition()` at line 259 maps reason strings to disposition words. `_router_rc_classify()` at line 118 maps exit codes to verdict+reason.

- `plugins/agent/spec-coverage/plugin.sh:178-179` — calls `route_to_model "$tier" "$_framed" || true`, swallowing router_rc. When no verdict parsed (line 192-195), writes `disposition: "complete"` hardcoded in `_scv_write` (line 106). Fix: capture router_rc, use `_router_rc_classify`+`router_reason_disposition` to get correct disposition.

- `plugins/agent/spec-correspondence/plugin.sh:114-116` — `_sc_call` uses `|| true` and returns only `$_raw`. `_sc_write_result` hardcodes `disposition: "complete"` (line 164). Fix: `_sc_call` accepts optional rc-sink file param; `_sc_write_result` accepts disposition param.

- `plugins/agent/review-report/plugin.sh:167-178` — collects per-lens rc files, but always sets `_disposition="complete"` (lines 172,174). Fix: track worst rc in the failed-lens loop, classify through `_router_rc_classify` + `router_reason_disposition`.

- `docs/adr/ADR-063-budget-disclosure-and-partial-output.md` — Status: Proposed. Still uses `exhausted` vocabulary and `escalate` response. Needs amendment to Accepted, timed_out/out_of_turns, strike escalate, note per-stage helper pattern, dated back-pointer to #2187.

- `plugins/agent/review-lens/plugin.sh:341-345` — correct reference implementation for router_reason_disposition pattern.

- `tests/unit/spec-coverage-test.sh` — 154 lines, existing tests through SPEC-8. SPEC-9 absent.
- `tests/unit/spec-correspondence-test.sh` — 289 lines, existing tests. Router-timeout disposition SPEC absent.
- `tests/unit/review-report-plugin-test.sh` + `review-report-v2-contract-test.sh` — both present; amend for lens-rc → disposition.
- No existing `design_verify_cycle` convergence-suppression test; new integration test needed.
- Integration tests dir: cycle-multi-iter-cumulative-test.sh and cycle-on-max-pipeline-continues-test.sh are reference patterns for fixture construction.

## Plan Summary (7 steps)

1. New test: `tests/integration/cycle-member-unfinished-no-convergence-test.sh` — T1/T2/T3 for §4/A (RED first)
2. Engine fix: `core/pipeline/cycle-orchestrator.sh` — add generic `_iter_did_not_finish` convergence suppression after line 2613, update comment at 2570-2573
3. New/amended unit tests for §3/B (RED first): spec-coverage, spec-correspondence, review-report unit tests
4. Plugin fix: `plugins/agent/spec-coverage/plugin.sh`
5. Plugin fix: `plugins/agent/spec-correspondence/plugin.sh`
6. Plugin fix: `plugins/agent/review-report/plugin.sh`
7. ADR amendment: `docs/adr/ADR-063-budget-disclosure-and-partial-output.md`

## Status
Plan ready to emit.
