## spec-coverage — uncovered

- Four of the issue's eight acceptance checkboxes map to no SPEC: `valid_verdicts` declared in manifest with a test per verdict, router budgets resolving from manifest (template override wins), a before/after golden diff proving passing-run behaviour is unchanged, and `primary: true` output declared in the manifest.

- NOT COVERED: `valid_verdicts` declared in manifest and every emittable verdict covered by a test
- NOT COVERED: router budgets resolve from manifest with template override taking precedence
- NOT COVERED: before/after golden diff on passing-run output
- NOT COVERED: manifest declares a `primary: true` output (or records why this stage is not dispatched)
