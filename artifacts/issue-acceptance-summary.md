## issue-acceptance — pass

- All nine SPECs are implemented and verified — abort_when.op and single-condition until.op are refused at template load with well-formed error messages (SPEC-1/2), multi-condition exit_when is updated to the full eight-op set (SPEC-3), all three runtime evaluators implement all eight ops correctly with numeric-type guards and `*)` fallback branches (SPEC-4 through SPEC-8), and ADR-027 gains its `## Enforced by` section while being removed from the enforcement baseline (SPEC-9); the test suite passes all 831 assertions.

- every requirement the issue states is met by the change
