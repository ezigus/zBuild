## File
`core/output/destinations.sh` — `emit_output` dispatches rendered report content to all enabled output destinations (stdout, local-report, gh-comment, gh-check-run, step-summary). A broken dispatch silently drops output without surfacing an error.

## Mutation
Invert the stdout toggle guard in `_dest_stdout`: replace the early-return condition so the function returns 0 (skips writing) when `ZBUILD_OUTPUT_STDOUT` is *not* `"0"` — i.e., when the destination is supposed to be active. This silences stdout output while appearing to succeed.

## Patch
```bash
sed -i.mutbak 's/\[\[ "$toggle" == "0" \]\] && return 0/_ZBUILD_DEST_STDOUT_MUT=1; [[ "$toggle" != "0" ]] \&\& return 0/' core/output/destinations.sh
```

## Expected failing test
`tests/unit/core-output-destinations-test.sh` — Test 1 asserts that `_dest_stdout` writes the report body to stdout when the destination is enabled (default). With the mutation, the function returns before writing, so `grep -qF "zBuild Report"` finds nothing and the test fails.

## Test
```bash
bash tests/unit/core-output-destinations-test.sh
```

## Result
The mutation is caught: Test 1 fails because no content is written to stdout when the destination is enabled; `grep` for the expected report header returns non-zero.
