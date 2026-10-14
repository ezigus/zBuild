
## File
`core/redaction/scope-redaction.sh`

## Mutation
Stop taking private paths out: make `is_private` in `apply_scope_redaction` always answer "not private", so a key file or a secrets path reaches the model as it is.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/redaction/scope-redaction.sh")
text = p.read_text()
old = "    function is_private(tok,    rel, base, j) {\n"
assert old in text, "anchor not found; mutation patch needs an update"
p.write_text(text.replace(old, old + "        return 0\n", 1))
PY
```

## Expected failing test
`tests/unit/core-redaction-test.sh` — asserts a private path (`.env`, a `*.pem` file, `.zbuild/secrets/…`) is replaced with `<private>`.

## Test
```bash
bash tests/unit/core-redaction-test.sh
```

## Result
The mutation is caught: the private paths are left in the output.
