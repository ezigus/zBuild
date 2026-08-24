All non-legacy files that reference `--dangerously-skip-permissions` or the new permission symbols are already in scope or are inert:

- `tests/unit/stage-checkpoint-test.sh:233` — uses the flag in a fixture `_args` array for SPEC-11, but every assertion (lines 241-252) only validates `--max-turns` escalation arithmetic. No assertion pins the presence of `--dangerously-skip-permissions`. Already in scope.
- `plugins/agent/plan/tests/plan-test.sh:147` — comment only, no live assertion.
- `.github/issues/keepers-manifest.yaml:4142` — title string, not a gate.
- `docs/adr/ADR-018-stage-invocation-modes.md` — already in scope; the residual `--dangerously-skip-permissions` occurrences in the body (lines 53, 54, 81, 363, 475) are historical prose that the ADR amendment at lines 9-16 supersedes.

No additional files need to be added to the scope block.
