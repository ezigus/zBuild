## spec-coverage — uncovered

- Three of the issue's explicit acceptance checkboxes map to no SPEC, and the "every exit path" checkbox is incompletely covered — the normal (non-dry-run) success path and the interruption path are absent.

- NOT COVERED: Checkbox "every exit path — success, failure, and interruption": SPEC-4 through SPEC-9 enumerate only error/edge failure paths and the dry-run pass path
- NOT COVERED: no SPEC covers the normal success exit (non-dry-run, pr-open succeeds, plugin exits verdict=pass), and no SPEC covers the interruption path (SIGTERM/SIGINT) — the issue explicitly names interruption as a required category
- NOT COVERED: Checkbox "Router budgets resolve from the manifest, and the template override still wins where one is set": the design narrative explains the plugin makes no direct LLM calls and therefore adds no router block, but no SPEC records this decision (either as an adoption or as an explicit inapplicable-because-no-LLM-calls record) — the acceptance criterion is unaddressed
- NOT COVERED: Checkbox "Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output": no SPEC requires or covers a behavioral-equivalence assertion for the passing run
- NOT COVERED: the integration-test scope entries are listed but no SPEC binds them to this requirement
