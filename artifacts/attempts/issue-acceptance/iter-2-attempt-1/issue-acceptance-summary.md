## issue-acceptance — fail

- Tests fail across four of six requirements — the lowered fork budget is not met (5111 > 4500), the run-status watcher tests never fire their first PATCH so SPEC-3/SPEC-4 assertions are vacuous, the existing SPEC-8 test enforcing sidecar isolation is broken by the new event-bus-sourcing change, and the event-bus payload-accumulation change introduces a silent-emit regression in the broken-jq scenario.

- NOT MET: R-1: Per-emit cost materially reduced — fork-budget-test.sh fails (5111 > 4500)
- NOT MET: before/after reduction not demonstrated
- NOT MET: R-3: Every stage event carries `stage` — run-status-comment-render-test.sh SPEC-8 now fails ("no eb_emit_event in the sidecar: expected: 0, got: 1"
- NOT MET: "sidecar never sources the event bus: expected: 0, got: 3"), an existing test enforcing the prior isolation invariant was not updated
- NOT MET: R-4: Run-status watcher not re-woken by own events — SPEC-3 and SPEC-4 both fail at setup ("first PATCH fired — no PATCH in GH_LOG"), so the no-spurious-render and unchanged-body-skip assertions are vacuously true and neither behavior is demonstrated
- NOT MET: R-5: Per-emit fork count pinned by test and lower than merge-base — fork-budget-test.sh fails (5111 > 4500)
- NOT MET: R-6: Event contents otherwise unchanged — test-plugin-result-write-fallback-test.sh "forced-fail: test.result_write.fallback event emitted" fails with empty events.jsonl, a regression caused by the new jq dependency in eb_emit_event (broken jq stub used to trigger the write_result fallback now also silences the fallback event emission via 2>/dev/null || true)
