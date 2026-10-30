## build_test_cycle — round 1

- test-author: pass — changed 3 test file(s); acceptance assertions for 6 SPEC(s) from the design contract
- build: pass — build_complete_no_changes
- test: fail — 830 of 830 tests passed; the acceptance check failed: the acceptance check failed — tests/unit/event-schema-emitted-coverage-test.sh was put back to its old version and every test still passed, so it is not what runs the new behaviour — name the file whose code calls it, or write WIRING: none
- issue-acceptance: pass — All five issue requirements are fully implemented — persist.*/hydrate.* are removed from event-schema.json with canonical declarations remaining only in the plugin manifests, plugin.result is removed from both the security-lens and merge manifests and their tests updated, the guard in event-schema-emitted-coverage-test.sh now derives plugin-owned namespaces dynamically from manifests replacing the hardcoded `_PLUGIN_NS_RE`, the `plugin.pr_open.*` exception is handled correctly, ADR-001 carries an Enforced-by section naming the test file, and the enforcement baseline no longer lists ADR-001; the test suite passes with 830 assertions.
