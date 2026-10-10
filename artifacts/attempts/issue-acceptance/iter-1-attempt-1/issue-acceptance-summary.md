## issue-acceptance — fail

- Two tests broken by the change were not updated — `tests/unit/impact-max-turns-test.sh` (3 assertions on impact's router config in simple.yaml, now empty after removal) and `tests/unit/template-always-run-test.sh` (pins simple.yaml flow count at 20, now 19) — leaving the test suite failing.

- NOT MET: R-2: `impact-max-turns-test.sh` (an `impact-*-test.sh` file the issue classified as "verified not affected") reads `_TPL_STAGE_ROUTER_MAX_TURNS_impact` and `_TPL_STAGE_ROUTER_TIMEOUT_impact` from simple.yaml, both now empty, causing 3 failures — impact's tests do not all pass
- NOT MET: R-5: dogfood cannot be confirmed with a failing test suite
