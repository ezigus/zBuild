All non-legacy files that pin `--dangerously-skip-permissions` as a live assertion are already in the design scope block.

- `plugins/agent/plan/tests/plan-test.sh:147` references the flag only in a comment (historical context for why the "no tool calls" prohibition was lifted); it contains no assertion that will break when the flag is replaced.
- `tests/unit/stage-checkpoint-test.sh:233` uses `--dangerously-skip-permissions` in a base `_args` array, but the test's assertions (SPEC-11) only validate `--max-turns` escalation arithmetic — not the presence of the permission flag. This file is already in scope.
- All remaining references are in `legacy/` (frozen) or `.github/issues/keepers-manifest.yaml` (a title string, not a gate).

No additional files need to be added to the scope block.
