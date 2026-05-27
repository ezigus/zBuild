## File
`core/memory/contract.sh`

## Mutation
Remove the required-functions verification loop in `memory_init` — replace the
loop body that checks each required function with `: # check removed by mutation`.
This lets `memory_init` succeed and set `_ZBUILD_MEMORY_INITIALIZED=1` even when
the backend plugin fails to define one or more of the six required functions
(`memory_put`, `memory_get`, `memory_search`, `memory_list_namespaces`,
`memory_namespace_exists`, `memory_namespace_clear`).

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/memory/contract.sh")
text = p.read_text()
new = text.replace(
    '        if ! declare -F "$fn" >/dev/null 2>&1; then\n            warn "memory_init: backend \'$_ZBUILD_MEMORY_BACKEND\' did not define required function: $fn" >&2 || true\n            missing_count=$((missing_count + 1))\n        fi',
    '        : # required-function check removed by mutation',
    1,
)
assert new != text, "patch did not match the required-function loop body"
p.write_text(new)
PY
```

## Expected failing test
`tests/unit/core-memory-contract-test.sh` — asserts that `memory_init` returns
non-zero when the sourced backend plugin is missing one or more required
functions. With the verification loop neutralized, `memory_init` returns 0
(success) for an incomplete backend and the test's exit-code assertion fails.

## Test
```bash
bash tests/unit/core-memory-contract-test.sh
```

## Result
The mutation is caught: the memory contract unit test fails because `memory_init`
no longer rejects an incomplete backend; it reports success even when required
functions are absent, violating the six-function completeness invariant.
