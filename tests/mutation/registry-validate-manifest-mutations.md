## File
`core/plugin-registry/registry.sh`

## Mutation
Invert the `kind: agent => redaction required` guard in `validate_manifest` — change the check so that `kind: agent` plugins are NOT required to declare `requires.core: [redaction]`. This allows an agent plugin to register without the redaction dependency.

## Expected failing test
`tests/unit/core-redaction-test.sh` and `tests/integration/core-plugin-registry-test.sh` — the registry test asserts that a `kind: agent` manifest without `requires.core: [redaction]` is rejected. With this mutation the invalid manifest is accepted.

## Result
The mutation is caught: the plugin registry test fails because the invalid manifest passes validation.
