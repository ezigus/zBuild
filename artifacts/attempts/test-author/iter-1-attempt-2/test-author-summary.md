## test-author — pass

- tests for DSDIFF-1, DSDIFF-2, DSDIFF-3, DSEND-1, DSLOCK-1, DSLOCK-2, DSLOCK-3

- the test files, and the requirements each covers:
- plugins/agent/build/tests/build-test.sh — DSDIFF-1, DSDIFF-2, DSDIFF-3
- tests/unit/route-loop-terminated-reasons-test.sh — DSEND-1, DSLOCK-1
- tests/unit/router-rc-classify-test.sh — DSLOCK-2
- tests/unit/route-one-call-per-try-test.sh — DSLOCK-3
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: DSLOCK-1 When: the test does something else: the code placed under the When heading runs static `grep -c` counts on source files; `_build_emit_changed_files_summary` is never called in this test section: done — restructured the DSLOCK-1 section in `tests/unit/route-loop-terminated-reasons-test.sh`: added sourcing of `event-bus.sh`, `numstat-format.sh`, and `plugins/agent/build/lib/summary.sh`; the When section now creates a clean git repo and calls `_build_emit_changed_files_summary` with `no_done_sentinel` and `router_out_of_turns`; the Then section's static analysis assertions are unchanged and still pass.
- not answered: test-author finding 1
