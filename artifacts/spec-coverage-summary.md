## spec-coverage — uncovered

- The issue's acceptance checkbox explicitly requires "Router budgets resolve from the manifest, and the template override still wins where one is set," but SPEC-15 is a guard asserting the manifest has no config.router block and manifest_router_knob returns empty — directly contradicting that requirement.

- NOT COVERED: Router budgets resolve from the manifest, and the template override still wins where one is set
