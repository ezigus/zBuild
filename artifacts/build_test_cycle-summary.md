## build_test_cycle — round 2

- test-author: pass — changed 1 test file(s); acceptance assertions for 5 SPEC(s) from the design contract
- build: error — scope_request_pending
- test: fail — 2 of 320 tests failed; the shape floor failed: missing_floor_files;the acceptance check failed: the acceptance check failed — tests/unit/event-schema-emitted-coverage-test.sh was put back to its old version and every test still passed, so it is not what runs the new behaviour — name the file whose code calls it, or write WIRING: none
- issue-acceptance: fail — The test suite exits non-zero, and `_PLUGIN_NS_RE` (R5) is not removed by the diff.
