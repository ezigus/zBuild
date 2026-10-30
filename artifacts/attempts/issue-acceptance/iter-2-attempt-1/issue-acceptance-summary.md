## issue-acceptance — fail

- The test suite exits non-zero, and `_PLUGIN_NS_RE` (R5) is not removed by the diff.

- NOT MET: R5: `_PLUGIN_NS_RE` is gone — the diff for `tests/unit/event-schema-emitted-coverage-test.sh` is a pure append starting at the original line 157; the earlier SPEC-1717-2 block that defines and uses `_PLUGIN_NS_RE` as a hardcoded plugin-namespace list falls entirely before that hunk and is untouched. The hardcoded enumeration the issue requires eliminated is still present in the file.
- NOT MET: R4 (test suite passes): Removing `plugin.result` from the security-lens and merge manifests is correct, but two pre-existing tests that pin the old manifest state now fail — `plugins/agent/security-lens/tests/security-lens-test.sh` [SPEC-16] asserts that `plugin.result` *is* in the security-lens manifest, and `tests/unit/merge-v2-result-test.sh` [SPEC-1] asserts it is in the merge manifest. Both assertions are now false and both tests fail. The issue's scope omitted these files; the build stage flagged them as out-of-scope needs. The test suite exits non-zero, so the change cannot be shipped as-is.
