## spec-coverage — uncovered

- Two explicit acceptance checkboxes from the issue have no corresponding SPEC.

- NOT COVERED: Issue acceptance checkbox A/3 — "at `max_iterations` with the last iteration unfinished, the cycle takes the existing exhaustion path — not `complete`" — SPEC-1 covers only the "iterates instead" case and says nothing about the max_iterations boundary where iteration is impossible and the exhaustion path must be taken instead of emitting `complete`
- NOT COVERED: Issue acceptance checkbox C — "ADR-063 amended and accepted
- NOT COVERED: no section still prescribes `exhausted` or `escalate`" — no SPEC covers the requirement to advance ADR-063's status and update its vocabulary (strike `exhausted`/`escalate`, record per-stage helpers, add back-pointer to #2187)
