# Acceptance checkpoint — issue #1806 (final)

## Files read
- test-results.json — 5 test files fail (116 pass, 5 fail files); TEST VERDICT: fail
- docs/adr/ADR-065-process-budget.md (lines 110-131) — confirmed `## Enforced by` present, names fork-budget-test.sh §1 and event-bus-timestamp-test.sh §5; ADR-065 removed from baseline
- plugins/tool/test/plugin.sh — emit_event("test.result_write.fallback") at line 1206, with `2>/dev/null || true`; event-bus sourced at line 24-25
- tests/unit/test-plugin-result-write-fallback-test.sh (grep) — ZBUILD_EVENTS_JSONL truncated at test line 175; broken jq stub triggers fallback; empty events.jsonl means emit_event failed silently

## Conclusions per requirement

**R-1 (per-emit cost materially reduced):** UNMET. fork-budget-test.sh fails: 5111 > 4500. Fork count reduced but budget set too aggressively; measured 5111 still above 4500.

**R-2 (no malformed timestamps, regression test reddens):** MET. _eb_host_is_mac() uses OSTYPE not ZBUILD_PLATFORM. SPEC-1 NEGCTL PASS.

**R-3 (every stage event carries `stage`; redaction.applied attributed):** UNMET. SPEC-5 passes (sidecar emits with stage=run-status-comment). BUT run-status-comment-render-test.sh SPEC-8 now fails ("no eb_emit_event in the sidecar: expected: 0, got: 1"; "sidecar never sources event bus: expected: 0, got: 3") — old test enforcing the opposite invariant was not updated.

**R-4 (watcher not re-woken; no PATCH on unchanged body):** UNMET. SPEC-3 and SPEC-4 both fail at "first PATCH fired — no PATCH in GH_LOG". First PATCH never fires, so meaningful assertions pass vacuously. Requirement not demonstrated.

**R-5 (fork count pinned by test, lower than merge-base):** UNMET. fork-budget-test.sh fails 5111 > 4500. SPEC-7 (ADR Enforced-by section) IS MET.

**R-6 (event contents otherwise unchanged):** UNMET. test-plugin-result-write-fallback-test.sh fails: "forced-fail: test.result_write.fallback event emitted / events.jsonl: " (empty). New eb_emit_event requires successful jq for payload; broken-jq test stub causes silent emit failure (2>/dev/null || true). Regression: test was passing before, now fails.

## Final verdict
VERDICT: fail
