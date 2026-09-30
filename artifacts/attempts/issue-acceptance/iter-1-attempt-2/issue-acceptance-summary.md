## issue-acceptance — fail

- The new test's awk patterns for SPEC-14 (provides.events) and SPEC-17 (valid_verdicts) fail to extract those sections from the modified manifest, leaving 12 assertions failing and npm test not green.

- NOT MET: npm test green (12 assertions fail in impact-v2-result-contract-test.sh — SPEC-14 all nine events not found
- NOT MET: SPEC-17 all three verdicts not found)
