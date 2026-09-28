## spec-coverage — uncovered

- two explicit acceptance checkboxes have no SPEC mapping — the code-side grep assertion and the primary-output declaration.

- NOT COVERED: "The plugin constructs no artifact paths in code — assert by grep over its plugin.sh" (SPEC-12 only covers manifest input shape, not code)
- NOT COVERED: "The manifest declares a primary: true output (or the issue records why this plugin is not dispatched as a stage)" (no SPEC addresses this at all)
