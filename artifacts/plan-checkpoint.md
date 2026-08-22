## Files read and conclusions

### plugins/agent/build/lib/diff.sh
- `_build_validate_scope_violations` is the gating function (lines 123–245).
- Name-status loop (lines 162–189): for each changed path, calls `_build_path_in_scope`; if OOS adds to `_scope_violations[]`.
- On `_router_rc >= 2` (timeout, #827): reverts OOS paths, preserves in-scope diff. On clean run: reverts all OOS paths and zeroes diff.
- FIX POINT: before calling `_build_path_in_scope`, detect scratch suffixes (`.bak`, `.orig`, `.rej`, `.head`, `.tmp`, `~`); `rm -f` the path and emit `build.scratch.cleaned`; `continue` — do not add to violations.

### plugins/agent/build/lib/prompt.sh
- `_build_compose_instructions` (line 20) builds the INSTRUCTIONS block.
- Rules section (line 69+): says "Touch only files in the scope list above." No mention of sed -i.bak.
- FIX POINT: add a note in the Rules section warning about scratch suffixes being fatal.

### plugins/agent/build/tests/build-test.sh
- 650 lines. T6 (line 323) tests a clean out-of-scope edit → scope_violation=true.
- Mock: `MOCK_LOOP_EDIT_FILE` / `MOCK_LOOP_EDIT_CONTENT` / `MOCK_LOOP_RC`.
- FIX POINT: add a new test section (T_SCRATCH) that simulates a timed-out turn stranding `.bak`/`.head` siblings, verifies in-scope work commits, build.scratch.cleaned event fires, and scope_violation=false.

### plugins/agent/build/lib/summary.sh
- No changes needed. The scope_violation=false path through summary already handles it.

## What I would do next if stopping now
1. Modify diff.sh: in the name-status loop, before scope check, test path suffix against scratch list and handle.
2. Modify prompt.sh: add one rule line about scratch suffixes.
3. Add regression test in build-test.sh: T_SCRATCH section.
