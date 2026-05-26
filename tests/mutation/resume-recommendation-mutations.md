## File
`core/state/resume.sh`

## Mutation
Flip the `interrupted) echo "auto_resume"` branch in `get_resume_recommendation` to return `manual_resume_only` instead. With this mutation, freshly-interrupted pipelines would never be auto-resumed.

(The 24-hour boundary at `age_seconds -lt 86400` is on the `in_progress` branch which is currently not exercised by the state-machine test; tracking that coverage gap separately.)

## Patch
```bash
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("core/state/resume.sh")
text = p.read_text()
new = re.sub(
    r'(\s*interrupted\)\n\s*echo )"auto_resume"',
    r'\1"manual_resume_only"',
    text,
)
assert new != text, "regex did not match; mutation patch needs an update"
p.write_text(new)
PY
```

## Expected failing test
`tests/integration/resume-state-machine-test.sh` — asserts that an interrupted pipeline gets the `auto_resume` recommendation (line ~113).

## Test
```bash
bash tests/integration/resume-state-machine-test.sh
```

## Result
The mutation is caught: the state-machine test fails because the interrupted-status recommendation is `manual_resume_only` instead of `auto_resume`.
