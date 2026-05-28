## File
`core/output/destinations.sh` — `_dest_stdout` dispatches rendered report content to stdout when `ZBUILD_OUTPUT_STDOUT` is enabled. A broken toggle guard silently drops stdout output while appearing to succeed.

## Mutation
Invert the toggle guard in `_dest_stdout` only: change `[[ "$toggle" == "0" ]] && return 0` to `[[ "$toggle" != "0" ]] && return 0` so the function exits early when the destination is enabled rather than disabled. This silences stdout output while returning 0.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/output/destinations.sh")
src = p.read_text()
# Target the guard inside _dest_stdout only: replace the first occurrence
# so _dest_local_report and other functions are unaffected.
old = '    [[ "$toggle" == "0" ]] && return 0\n'
new = '    [[ "$toggle" != "0" ]] && return 0\n'
idx = src.find(old)
assert idx != -1, "toggle guard not found in _dest_stdout"
p.write_text(src[:idx] + new + src[idx + len(old):])
PY
```

## Expected failing test
`tests/unit/core-output-destinations-test.sh` — asserts that `_dest_stdout` writes the report body to stdout when enabled (toggle != "0"). With the mutation the function returns before writing, so the test's grep for the expected report content finds nothing and fails.

## Test
```bash
bash tests/unit/core-output-destinations-test.sh
```

## Result
The mutation is caught: the output-destinations unit test fails because no content is written to stdout when the destination is enabled; the grep assertion returns non-zero.
