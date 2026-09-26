## spec-coverage — covered

- All eight acceptance checkboxes map to a SPEC — SPEC-14 (v2 result on every exit path), SPEC-19 (valid_verdicts + test per verdict), SPEC-16 (no artifact paths in code), SPEC-20 (router budget posture — validate has no LLM calls so the correct behaviour is no config.router block, which SPEC-20 asserts), SPEC-21 (before/after golden diff via dry-run happy-path shape), SPEC-22 (primary: true), with the two process requirements (npm green, reddens at merge-base) excluded as pipeline-proven rather than behavioural gaps.

- every requirement the issue states maps to a declared SPEC
