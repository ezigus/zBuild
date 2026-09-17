## spec-coverage — uncovered

- The issue has an explicit acceptance checkbox — "Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output" — but no SPEC guards the passing run's output; SPEC-8 guards only the advisory degrade path.

- NOT COVERED: behaviour unchanged for a passing run, verified by a before/after golden diff on the stage's own output
