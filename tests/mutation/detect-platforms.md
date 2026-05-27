## File
`core/detect/platforms.sh` — `detect_platforms` scans plugin manifests and repo indicator files to determine which platforms are active. A broken detector silently returns the wrong platform list, causing all downstream stage/plugin selection to target the wrong runtime.

## Mutation
Invert the fallback floor so the function emits "generic" only when at least one platform was detected, and emits nothing (empty result) when detection finds nothing. Replace the `[[ ${#detected_platforms[@]} -eq 0 ]]` guard with `[[ ${#detected_platforms[@]} -gt 0 ]]`, making the fallback activate on a non-empty result and the empty-result case produce no output.

## Patch
```bash
sed -i.mutbak 's/if \[\[ \${#detected_platforms\[@\]} -eq 0 \]\]; then/if [[ ${#detected_platforms[@]} -gt 0 ]]; then/' core/detect/platforms.sh
```

## Expected failing test
`tests/unit/core-detect-platforms-test.sh` — Test 1 asserts that `detect_platforms` returns a result containing "generic" when no plugins declare a platform and no indicator files are present. With the mutation the condition never fires for the empty case, so the output is empty and `assert_contains "generic"` fails.

## Test
```bash
bash tests/unit/core-detect-platforms-test.sh
```

## Result
The mutation is caught: Test 1 fails because the fallback floor no longer activates for the empty-detection case; the function emits nothing, and `assert_contains "generic"` finds no output to match against.
