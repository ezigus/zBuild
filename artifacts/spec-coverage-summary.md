## spec-coverage — uncovered

- Four issue requirements have no corresponding SPEC: router budgets in the manifest, the interruption exit path, the manifest inputs-section structure, and the before/after golden diff.

- NOT COVERED: Router budgets declared in the manifest rather than only from the template, with the template override still winning — explicitly required by the "Router budgets" adoption item and the acceptance checklist ("Router budgets resolve from the manifest, and the template override still wins where one is set") — no SPEC covers this
- NOT COVERED: Interruption exit path — the issue acceptance checklist requires a conformant v2 result on "every exit path — success, failure, and interruption" but no SPEC tests a signal/trap interruption path
- NOT COVERED: Manifest inputs section structure — the issue requires the manifest declare inputs with only `id` and `required:` (no producer stage, no path, no type) but SPEC-11 only asserts plugin.sh contains no hardcoded input path strings, not that the manifest inputs section is restructured to name-matched format
- NOT COVERED: Before/after golden diff for a passing run — the issue acceptance checklist requires "Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output", golden test files are in scope, but no SPEC maps to that test or requires the comparison.
