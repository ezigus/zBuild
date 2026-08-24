## Plan checkpoint — C10 restrict model write permissions

### Files read
- core/router/route.sh:807 — single-shot path: `_claude_args+=(--dangerously-skip-permissions)`
- core/router/route.sh:1562 — agent-loop path: same flag
- core/router/route.sh:836-866 — `_zbuild_make_fresh_shell` runs in the subshell at spawn time; settings file must be built BEFORE that point
- core/router/route.sh:368-372 — "restate before scrub" pattern for inputs; same pattern applies here
- tests/unit/router-claude-flags-test.sh:86,103 — asserts `--dangerously-skip-permissions` present; must be updated to assert new flags
- tests/integration/router-claude-flags-test.sh:114 — same assertion
- tests/unit/stage-checkpoint-test.sh:259-271 — greps route.sh for `_claude_args[$((_ai + 1))]` and `_turn_cap`; not near :807/:1562, will still pass

### Conclusions
1. New file: core/router/permissions.sh — `_zbuild_build_permissions_settings` writes ${ZBUILD_STAGE_SCRATCH}/claude-settings.json and validates with jq; `_zbuild_permission_args` emits the two --permission-mode / --settings / --add-dir tokens
2. route.sh:807 — replace `--dangerously-skip-permissions` with call to `_zbuild_permission_args` (source permissions.sh first)
3. route.sh:1561-1562 — same replacement in loop path
4. Both test files need `--dangerously-skip-permissions` assertions replaced with `--permission-mode` / `acceptEdits` / `--settings` / `--add-dir` assertions
5. docs/adr/ADR-018-stage-invocation-modes.md — add Amended section

### Next step if stopping now
Emit plan JSON.
