## spec-coverage — uncovered

- Three explicit checklist items from the issue have no matching SPEC — no-path-construction in code, router budgets in the manifest, and `primary: true` output declaration.

- NOT COVERED: The plugin constructs no artifact paths in code — assert by grep over plugin.sh
- NOT COVERED: router budgets resolve from the manifest and the template override still wins where one is set
- NOT COVERED: the manifest declares a `primary: true` output (or the issue records why this plugin is not dispatched as a stage).
