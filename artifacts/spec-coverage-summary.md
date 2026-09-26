## spec-coverage — uncovered

- Two explicit checklist requirements from the issue have no SPEC: (1) "Router budgets resolve from the manifest, and the template override still wins where one is set" — no SPEC asserts that any of the three manifests carries router budget fields; (2) "The manifest declares a `primary: true` output (or the issue records why this plugin is not dispatched as a stage)" — no SPEC checks for a `primary: true` output in any of the three manifests.

- NOT COVERED: Router budgets declared in manifest (all three plugins)
- NOT COVERED: `primary: true` output declared in manifest (all three plugins)
