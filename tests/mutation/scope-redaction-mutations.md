## File
`core/redaction/scope-redaction.sh`

## Mutation
Invert the fail-closed check in `apply_scope_redaction` — change the guard that rejects a missing or malformed scope manifest from a hard failure to a silent pass-through. This allows unredacted content to flow to the router when the scope manifest is absent.

## Expected failing test
`tests/unit/core-redaction-test.sh` — asserts that `apply_scope_redaction` returns non-zero when the scope manifest is missing. With this mutation the function returns 0 and the test fails.

## Result
The mutation is caught: the redaction unit test fails because the function no longer rejects missing manifests.
