## spec-coverage — uncovered

- The issue's acceptance checkbox requires `valid_verdicts` declared in the manifest (with every emittable verdict listed), but no SPEC asserts a `valid_verdicts` field in the manifest — SPEC-9 checks only `result_contract: 2` in the provides block, and SPEC-17 checks only `provides.role` and `provides.events`.

- NOT COVERED: `valid_verdicts` declared in the manifest with every verdict the plugin can emit listed — no SPEC checks for this manifest field
