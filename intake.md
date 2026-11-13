build's zero-change warning fires however the call ends, not only done_sentinel; the end-reason comment in route_to_model_loop lists every value it can hold

## Goal

When build's call ends with no files changed, the run says so, whatever the reason the call ended. And the comment listing the values `route_to_model_loop`'s end reason can hold matches the values the code actually produces.

## What is wrong today

- `_build_emit_changed_files_summary` (`plugins/agent/build/lib/summary.sh`) emits `build.discrepancy.detected` and `build.diff.empty_after_done_sentinel` only when the call ended on `done_sentinel`. A call that ends on `no_done_sentinel` or `router_out_of_turns` with zero files changed leaves no trace.
- The comment above `route_to_model_loop` (`core/router/route.sh`) lists `done_sentinel | no_done_sentinel | router_timeout | router_rate_limited | signal | a _router_rc_classify reason`. It leaves out `router_budget_exceeded` and `router_config_error`, and "a `_router_rc_classify` reason" names no values. The values come from two places: the literals `route_to_model_loop` assigns, and the reasons `_router_rc_classify` (`scripts/lib/router-rc-classify.sh`) returns.

## ADR

ADR-054 and its #2366 amendment (one `outcome`; a stage says what it did), as amended by #2439 (one call per try). #2439 removed `no_progress`, `max_iterations`, `hook_failed` and `error` on purpose. The 2026-08-09 comment below predates #2439: where it says `no_progress`, read `no_done_sentinel`.

## Required behavior

Write each as a test first and watch it fail.

- **R1.** Build's call ends on `no_done_sentinel` with zero files changed. `build.discrepancy.detected` is emitted, with the end reason in the event.
- **R2.** The same holds for `router_out_of_turns` with zero files changed.
- **R3.** `done_sentinel` with zero files changed behaves as today. This is a guard.
- **R4.** A test collects every value `route_to_model_loop` assigns as its end reason and every reason `_router_rc_classify` returns, and checks the comment lists exactly that set.
- **R5.** No end-reason value is renamed or added. The only change in `core/router/route.sh` is the comment; `scripts/lib/router-rc-classify.sh` is not changed. `tests/unit/route-one-call-per-try-test.sh` O4 is unchanged.

## Scope

- **Code:** `plugins/agent/build/lib/summary.sh`, `core/router/route.sh` (comment only). `scripts/lib/router-rc-classify.sh` is read, not changed.
- **Tests:**
  - `tests/unit/build-discrepancy-warn-inside-banner-test.sh`
  - `tests/integration/build-changed-files-summary-test.sh`
  - `tests/unit/build-false-completion-guard-test.sh`
  - `tests/golden/full-pipeline/event-sequence.golden` (only if event order changes)
- **Out of scope:** design. It makes one model call per run (#2399), and these end reasons don't apply to it. Renaming or adding end reasons.

## Additional context from issue comments

**Split. The vocabulary half moves to the stage contract; the `design.md` defect stays here.**

| half | where it goes |
|---|---|
| *"an undocumented `terminated_reason` falls through to the default"* — the vocabulary problem | **#1822** (`disposition` is a closed set; an unrecognised value is a structural failure, never a silent default) and **#1832** (moving `did_not_finish` and friends out of `verdict`) |
| *"a `no_progress` build loop reports verdict pass"*, and diagnostics gated on `done_sentinel` | **stays here** |

The half that stays is not a vocabulary problem: a loop that made no progress reporting `pass` is a wrong conclusion, and it stays wrong no matter how the stopping condition is spelled. It is a Phase 1 concern (#1794) — a result that does not matter — and is sequenced with #1798.

The diagnostics being gated on `done_sentinel` also stays: under the contract those belong in the v2 result's `data` block (#1821), available regardless of how the loop terminated. Coordinate with #1833 (build's v2 migration).

Refs #1819, #1822, #1832, #1821, #1794, #1833.
