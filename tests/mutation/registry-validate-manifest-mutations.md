## File
`core/plugin-registry/registry.sh`

## Mutation
Disable the `kind: agent ⇒ requires.core: [redaction]` guard in `validate_manifest`. Replace the grep check with `false`, so an agent plugin without the redaction dependency would pass validation.

## Patch
```bash
sed -i.mutbak 's|if ! grep -qE .*redaction.* "\$manifest"; then|if false; then|' core/plugin-registry/registry.sh
```

## Expected failing test
`tests/integration/core-plugin-registry-test.sh` — asserts that a `kind: agent` manifest without `requires.core: [redaction]` is rejected by `validate_manifest`.

## Test
```bash
bash tests/integration/core-plugin-registry-test.sh
```

## Result
The mutation is caught: the registry test fails because an invalid manifest (no redaction declaration) silently passes validation.
