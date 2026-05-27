## File
`core/orch/contract.sh`

## Mutation
Disable the `_ZBUILD_ORCH_BACKEND_LOADED` sentinel check in `_orch_load_backend`
so it always attempts to re-load the backend, overwriting any pre-loaded backend
implementation. Replace `[[ "${_ZBUILD_ORCH_BACKEND_LOADED:-0}" -eq 1 ]] && return 0`
with `false && return 0`, which makes the guard never fire and the stubs always
overwrite a real backend.

## Patch
```bash
sed -i.mutbak 's|\[\[ "\${_ZBUILD_ORCH_BACKEND_LOADED:-0}" -eq 1 \]\] && return 0|false \&\& return 0|' core/orch/contract.sh
```

## Expected failing test
`tests/unit/core-orch-contract-test.sh` — asserts that when a backend is
pre-loaded before sourcing contract.sh, the pre-loaded functions are not
overwritten by the stubs. With the sentinel disabled, the stubs replace the
real implementation and orch_spawn returns an error instead of succeeding.

## Test
```bash
bash tests/unit/core-orch-contract-test.sh
```

## Result
The mutation is caught: the orch contract unit test fails because the sentinel
guard no longer protects the pre-loaded mock backend, causing orch_spawn and
orch_dispatch to revert to the not-implemented stubs.
