## spec-coverage — uncovered

- The issue's "ALSO LAND HERE" section explicitly requires landing ADR-063 §3 — monitor emitting `disposition: exhausted` when the turn-budget/timeout path fires — but no SPEC commits to that specific mapping (SPEC-21 only proves rc=10 collapses to rc=1, not which disposition value results).

- NOT COVERED: monitor emitting `disposition: exhausted` for the turn-budget-exhaustion path (ADR-063 §3)
