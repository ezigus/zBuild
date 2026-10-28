## issue-acceptance — pass

- Every requirement is satisfied — behavioral tests are falsifiable and passed (821/0), SPEC-5's no-CI-branch property is mechanically enforced by grep-count assertions in `run-limit-precedence-test.sh`, both ADRs carry `## Enforced by` sections citing the new test files, and the issue's "§9" label for the ADR-054 amendment is a draft numbering error (the existing §9 is per-stage router config; the per-run limit correctly landed as §11 with identical content).

- every requirement the issue states is met by the change
