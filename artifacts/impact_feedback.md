All files referenced or invalidated by the change are already in scope.

- `build.scratch.cleaned` is a brand-new event with no pre-existing emit sites or references anywhere in the repo — no unlisted file pins it.
- `_build_compose_instructions` (prompt.sh) is called directly in `tests/unit/build-prompt-loop-complete-rule-test.sh`, but that test uses `assert_contains` on specific substrings; adding one new rule line does not invalidate any of its assertions (R1–R6). Not a scope gap.
- `_build_path_in_scope` / `_build_validate_scope_violations` are called from `plugins/agent/build/lib/scope.sh` and `plugin.sh` respectively, but neither file's behaviour changes — the new scratch pre-filter is purely additive inside `diff.sh`. No other test file calls `_build_validate_scope_violations` directly except the two already in scope.
- The `.bak` references in `tests/integration/concurrent-state-test.sh` relate to `atomic_write` file-rotation backups — a completely different mechanism from sed-i scratch siblings. Not a gap.
- `tests/golden/build-summary-artifact.golden` captures only the JSON schema shape of `build-summary.json`, not the manifest event list or prompt text. Not invalidated.
- No test pins a count of entries in `provides.events` or a line-count of `_build_compose_instructions` output.

Scope is complete as specified.
