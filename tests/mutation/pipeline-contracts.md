## File
`core/pipeline/runner.sh` — after each stage succeeds, `_update_stage_status` is called with the string `"complete"` (ADR-006 enum). Changing this string breaks the completed-stage detection used by resume logic and the integration test's state assertions.

## Mutation
Replace the success status token `"complete"` with `"done"` in the post-stage success call so the stage state written to disk is `done` instead of `complete`.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/pipeline/runner.sh")
src = p.read_text()
new = src.replace(
    '_update_stage_status "$state_file" "$stage" "complete"',
    '_update_stage_status "$state_file" "$stage" "done"',
    1,
)
assert new != src, "patch did not match _update_stage_status complete call"
p.write_text(new)
PY
```

## Expected failing test
`tests/integration/core-pipeline-runner-test.sh` — asserts `assert_eq "intake stage_status=complete (ADR-006 enum)" "complete" "$intake_status"`. With the mutation, the state file records `done` instead of `complete` for the intake stage, and the equality check fails.

## Test
```bash
bash tests/integration/core-pipeline-runner-test.sh
```

## Result
The mutation is caught: the pipeline runner integration test fails at `assert_eq "intake stage_status=complete (ADR-006 enum)"` because the recorded status is `done` rather than `complete`.
