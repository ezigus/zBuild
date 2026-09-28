## spec-coverage — uncovered

- Three acceptance checkboxes and two "What this plugin adopts" items have no SPEC counterpart.

- NOT COVERED: Acceptance checkbox 3 — "the plugin constructs no artifact paths in code" (name-matched inputs via #1825/#1826
- NOT COVERED: no SPEC requires removal of path construction or name-matched input adoption)
- NOT COVERED: acceptance checkbox 4 partial — "the template override still wins where one is set" (SPEC-7 covers only manifest declaration, not override precedence)
- NOT COVERED: `provides.events` and `provides.role` declared in the manifest (#1717, #1704)
- NOT COVERED: `cleanup` hook — whether the hook is present or absent and recorded (#1829).
