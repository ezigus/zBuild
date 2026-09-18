## File
`scripts/lib/run-status-comment.sh` — `rsc_comment_patch` edits the run's ONE comment via `-X PATCH …/issues/comments/<id>`; `scripts/lib/run-status-render.sh` — `rsc_bound_body` keeps the body under `ZBUILD_STATUS_COMMENT_MAX_BYTES` (60,000); `core/pipeline/runner.sh` — `_runner_abort_trap` ends with `_runner_status_comment_reap`.

## Mutation
Three independent mutations, each a plausible regression:
1. Turn the PATCH into a POST (a second comment per update — the defect keeper e-1 exists to prevent).
2. Raise the byte cap tenfold (a 200-row run would then be rejected by GitHub with 422).
3. Drop the reap from the end of the abort trap (the sidecar outlives an aborted run).

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("scripts/lib/run-status-comment.sh"); s = p.read_text()
new = s.replace('-X PATCH -F "body=@${body_file}"', '-F "body=@${body_file}"', 1)
assert new != s, "PATCH site not found"; p.write_text(new)
p = pathlib.Path("scripts/lib/run-status-render.sh"); s = p.read_text()
new = s.replace(': "${ZBUILD_STATUS_COMMENT_MAX_BYTES:=60000}"', ': "${ZBUILD_STATUS_COMMENT_MAX_BYTES:=600000}"', 1)
assert new != s, "cap not found"; p.write_text(new)
p = pathlib.Path("core/pipeline/runner.sh"); s = p.read_text()
new = s.replace('        ( _render_pipeline_end "aborted" ) || true\n        # #2131: abnormal path', '        ( _render_pipeline_end "aborted" ) || true\n        : # reap removed\n        # #2131: abnormal path', 1)
new = new.replace('        _runner_status_comment_reap\n    }\n    # #612 / Wave 15-F', '    }\n    # #612 / Wave 15-F', 1)
assert new != s, "trap reap not found"; p.write_text(new)
PY
```

## Expected failing test
`tests/unit/run-status-comment-gh-test.sh` — `[SPEC-2] two PATCHes to …/issues/comments/4242` fails (0 PATCHes; the POST count climbs instead). `tests/unit/run-status-comment-render-test.sh` — `[SPEC-6] 400-row feed renders under 60,000 bytes` fails (~100 KB, no omission line). `tests/unit/runner-status-comment-hook-test.sh` — `[SPEC-2] reap is the last statement of the abort trap` fails.

## Test
```bash
bash tests/unit/run-status-comment-gh-test.sh
bash tests/unit/run-status-comment-render-test.sh
bash tests/unit/runner-status-comment-hook-test.sh
```

## Result
All three mutations are caught; each by the assertion named above.
