## File
`core/event-bus/event-bus.sh` — `_eb_strip_ansi` is called inside `eb_emit_event` to sanitize every payload value and string envelope field before they are written to the JSONL log. Bypassing these call sites lets raw ANSI escape bytes reach the JSONL writer.

## Mutation
Comment out the `_eb_strip_ansi` call sites inside `eb_emit_event`: replace the stripped `val` assignment with the raw `${arg#*=}` expansion, and replace the three stripped envelope-field assignments with bare environment variable reads so ANSI bytes pass through unfiltered.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/event-bus/event-bus.sh")
src = p.read_text()
new = src.replace(
    'val="$(_eb_strip_ansi "${arg#*=}")"',
    'val="${arg#*=}"',
    1,
).replace(
    'local run_id; run_id="$(_eb_strip_ansi "${ZBUILD_RUN_ID:-}")"',
    'local run_id="${ZBUILD_RUN_ID:-}"',
    1,
).replace(
    'local plugin; plugin="$(_eb_strip_ansi "${ZBUILD_PLUGIN:-}")"',
    'local plugin="${ZBUILD_PLUGIN:-}"',
    1,
).replace(
    'local kind; kind="$(_eb_strip_ansi "${ZBUILD_PLUGIN_KIND:-}")"',
    'local kind="${ZBUILD_PLUGIN_KIND:-}"',
    1,
)
assert new != src, "patch did not match any _eb_strip_ansi call site"
p.write_text(new)
PY
```

## Expected failing test
`tests/unit/event-bus-ansi-strip-test.sh` — With the mutation applied, ANSI escape sequences reach the JSONL writer. The `[SPEC-1]` assertion on `.data.output` fails because the actual value is `$'\e[32mgreen\e[0m'` instead of `green`. The `[SPEC-2]` assertions on `.plugin`, `.run_id`, and `.kind` fail for the same reason. The no-ESC-bytes assertion also fails.

## Test
```bash
bash tests/unit/event-bus-ansi-strip-test.sh
```

## Result
The mutation is caught: ANSI escape bytes appear in the JSONL record, causing the `[SPEC-1]` payload-value assertion and the `[SPEC-2]` envelope-field assertions to fail because the stripped expected values (`green`, `red-plugin`) do not match the raw ANSI-coloured actuals.
