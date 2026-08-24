# Design: C10 — Restrict Model Write Permissions via acceptEdits + Settings File

## Architectural Decision Summary

**Goal.** Replace `--dangerously-skip-permissions` at both `route.sh` spawn sites (single-shot and agent-loop) with `--permission-mode acceptEdits` backed by a jq-validated Claude settings file that grants write access only to the worktree root and the stage scratch directory.

**Context.** `--dangerously-skip-permissions` grants the spawned `claude` process unrestricted write access — it can edit any file reachable from its working directory without prompting. The scope-manifest (`ZBUILD_SCOPE_MANIFEST`) and redaction chokepoint (ADR-043) constrain what the *prompt* says, but the *process* permission boundary is wider than the prompt declares. Issue #1919 tightens the process boundary to match the declared scope: only the worktree and the stage scratch dir are writable, and the `acceptEdits` mode keeps tools available (Read/Edit/Write/Bash) without the blanket bypass.

**Decision.**
1. Create `core/router/permissions.sh` with two exported helpers:
   - `_zbuild_build_permissions_settings` — writes `${ZBUILD_STAGE_SCRATCH:-$(zbuild_engine_tmpdir)}/claude-settings.json` with `allowedDirectories = [ZBUILD_REPO_ROOT, scratch_dir]`; validates with `jq`; returns rc=1 on failure.
   - `_zbuild_permission_args` — emits `--permission-mode acceptEdits --settings <file>` tokens for inline expansion into `_claude_args`.
2. Wire `permissions.sh` into both spawn sites in `route.sh`: call `_zbuild_build_permissions_settings` before the spawn (abort on rc≠0) then replace `_claude_args+=(--dangerously-skip-permissions)` with `_claude_args+=($(_zbuild_permission_args))`.
3. Update unit and integration tests that assert on `--dangerously-skip-permissions`.
4. Amend ADR-018 to record the permission-mode change.

The settings file is built before `_zbuild_make_fresh_shell` runs (mirroring the restate-before-scrub pattern at `route.sh:368–372`). If `ZBUILD_STAGE_SCRATCH` is unset, the helper falls back to `zbuild_engine_tmpdir()` and emits a `router.permissions.scratch_fallback` warning event.

```scope
core/router/permissions.sh
core/router/route.sh
docs/adr/ADR-018-stage-invocation-modes.md
tests/unit/router-claude-flags-test.sh
tests/unit/router-permissions-test.sh
tests/integration/router-claude-flags-test.sh
tests/unit/stage-checkpoint-test.sh
tests/unit/redaction-chokepoint-test.sh
```

```acceptance
SPEC-1[change]: Both route.sh spawn sites pass --permission-mode acceptEdits --settings <file> instead of --dangerously-skip-permissions
SPEC-2[change]: The generated settings file is jq-validated and its allowedDirectories array contains both the repo root and the stage scratch dir
SPEC-3[change]: A missing or jq-unparseable settings file causes the spawn to abort (rc=2), not silently bypass the check
SPEC-4[change]: grep -rn dangerously-skip-permissions core/router/ returns no results
SPEC-5[guard]: --disallowed-tools EnterPlanMode,ExitPlanMode and --max-turns flags are still emitted at both spawn sites after the permission-mode change
SPEC-6[guard]: The redaction chokepoint invariant is unaffected — permissions.sh is inside core/router/ and the settings file is written inside zbuild_engine_tmpdir()
WIRING: core/router/route.sh
TESTFILES:
SPEC-1: tests/unit/router-claude-flags-test.sh tests/integration/router-claude-flags-test.sh
SPEC-2: tests/unit/router-permissions-test.sh
SPEC-3: tests/unit/router-permissions-test.sh
SPEC-4: tests/unit/router-permissions-test.sh
SPEC-5: tests/unit/router-claude-flags-test.sh
SPEC-6: tests/unit/redaction-chokepoint-test.sh
```

LOOP_COMPLETE
