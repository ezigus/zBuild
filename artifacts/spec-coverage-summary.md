## spec-coverage — uncovered

- Four of the issue's explicit acceptance checkboxes have no corresponding SPEC — `valid_verdicts` declared in the manifest and each verdict driven by a test; the plugin constructs no artifact paths in code (grep assertion); `primary: true` output declared in the manifest; and `provides.events`/`provides.role` declared — and two further requirements from "What this plugin adopts" (name-matched inputs with engine-resolved paths, `cleanup` hook absent-and-recorded) are also absent from the SPEC list.

- NOT COVERED: `valid_verdicts` declared in manifest with every emittable verdict covered by a test
- NOT COVERED: plugin constructs no artifact paths in code (grep-asserted)
- NOT COVERED: manifest declares `primary: true` output
- NOT COVERED: `provides.events` and `provides.role` declared
- NOT COVERED: name-matched inputs (manifest declares only `id`+`required`, no producer/path/type, no path construction in code)
- NOT COVERED: `cleanup` hook absent-and-recorded
- NOT COVERED: `disposition: exhausted` emitted on budget/timeout exhaustion (ADR-063 §3)
