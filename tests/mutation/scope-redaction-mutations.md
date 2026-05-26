## File
`core/redaction/scope-redaction.sh`

## Mutation
Invert the fail-closed guard in `apply_scope_redaction` — replace the `return 1` on a missing/empty scope manifest with `return 0`, so the function silently succeeds even when no manifest exists. This allows unredacted content to flow downstream.

## Patch
```bash
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("core/redaction/scope-redaction.sh")
text = p.read_text()
new = re.sub(
    r'(emit_event "redaction\.refused" "reason=missing_scope_manifest" "input=\$input" "cycle=\$cycle_id"\n\s*)return 1',
    r'\1return 0',
    text,
)
assert new != text, "regex did not match; mutation patch needs an update"
p.write_text(new)
PY
```

## Expected failing test
`tests/unit/core-redaction-test.sh` — asserts `apply_scope_redaction` returns non-zero when the scope manifest is missing, empty, or unreadable.

## Test
```bash
bash tests/unit/core-redaction-test.sh
```

## Result
The mutation is caught: the redaction unit test fails because the function returns 0 (success) for all three "missing manifest" cases instead of refusing.
