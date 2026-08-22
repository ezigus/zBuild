# Design: Classify scratch suffixes as transient residue in scope validator

## Architectural decision summary

**Goal.** Prevent `.bak`, `.head`, `.orig`, `.rej`, `.tmp`, and `~`-suffix files stranded by
timed-out build turns from voiding the iteration's commit. These files are never
meaningful edits; they are debris from `sed -i.bak`, `git show HEAD:f > f.head`, and
similar idioms.

**Context.** `_build_validate_scope_violations` (diff.sh) treats every changed path not in
`plan.files[]` as an out-of-scope violation. Under `router_rc >= 2` (timeout, #827) the
existing code reverts OOS paths and preserves in-scope work; under `router_rc = 0` it
empties the diff entirely. Either way, a stranded `.bak` sibling triggers scope-violation
bookkeeping, and on a clean run it silently discards real in-scope work that happened to be
committed in the same turn.

**Decision.** Before the `_build_path_in_scope` check, test each changed path against a
scratch-suffix list (`.bak .orig .rej .head .tmp ~`). A match is handled by:
1. `rm -f "$_repo_root/$_p"` — remove the debris from the working tree.
2. `emit_event "build.scratch.cleaned"` — signal that a scratch file was silently deleted.
3. Skip adding the path to `_scope_violations[]` — it is not a scope violation.

This is a pre-filter inside `_build_validate_scope_violations`, applied unconditionally
before the `router_rc` branch, so it works under both clean-run and timeout paths.

Additionally, `_build_compose_instructions` (prompt.sh) gains one rule line warning the
agent that `sed -i.bak`, `git show HEAD:f > f.head`, and similar scratch siblings will be
deleted — nudging the agent toward `sed -i` (no suffix) or explicit cleanup.

The new event `build.scratch.cleaned` is declared in the build manifest's `provides.events`
list (ADR-001 §"Declared events" / #1717); no edit to `config/event-schema.json` is needed.

```scope
plugins/agent/build/lib/diff.sh
plugins/agent/build/lib/prompt.sh
plugins/agent/build/tests/build-test.sh
plugins/agent/build/manifest.yaml
tests/unit/event-schema-emitted-coverage-test.sh
tests/unit/build-timeout-scope-violation-preserves-inscope-test.sh
```

```acceptance
SPEC-1[change]: scratch-suffix file (.bak/.head/.orig/.rej/.tmp/~) stranded after a timed-out turn is deleted from the working tree and does not appear in scope_violations
SPEC-2[change]: build.scratch.cleaned event is emitted when a scratch-suffix file is removed
SPEC-3[change]: diff.patch is non-empty (in-scope work preserved) when the only OOS paths are scratch-suffix files after a timeout
SPEC-4[guard]: a genuine out-of-scope source edit (no scratch suffix) on a clean run still produces scope_violation=true and an empty diff.patch
SPEC-5[guard]: build.scope.violation event is NOT emitted for scratch-suffix paths
WIRING: plugins/agent/build/lib/diff.sh
TESTFILES:
SPEC-1: plugins/agent/build/tests/build-test.sh
SPEC-2: plugins/agent/build/tests/build-test.sh
SPEC-3: plugins/agent/build/tests/build-test.sh
SPEC-4: plugins/agent/build/tests/build-test.sh
SPEC-5: plugins/agent/build/tests/build-test.sh
```

LOOP_COMPLETE
