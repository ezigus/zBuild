## File
`core/event-bus/event-bus.sh`

## Mutation
Remove the `flock` guard in `eb_emit_event` so the JSONL write is no longer
serialized. Replace the flock-protected subshell block with a bare `echo`
append — this allows concurrent writers to interleave lines and corrupt the
event log, breaking the single-writer contract.

## Patch
```bash
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("core/event-bus/event-bus.sh")
text = p.read_text()
new = re.sub(
    r'\(\s*\n\s*flock -w 5 9 \|\| exit 1\s*\n\s*echo "\$event_json" >> "\$ZBUILD_EVENTS_JSONL"\s*\n\s*\) 9>"\$\{ZBUILD_EVENTS_JSONL\}\.lock"',
    'echo "$event_json" >> "$ZBUILD_EVENTS_JSONL"',
    text,
)
assert new != text, "regex did not match; mutation patch needs an update"
p.write_text(new)
PY
```

## Expected failing test
`tests/unit/core-event-bus-test.sh` — asserts that after concurrent emits the
JSONL file contains the correct number of events, one per line, each valid JSON.
The flock removal allows lines to interleave so the count or JSON-validity check
fails.

## Test
```bash
bash tests/unit/core-event-bus-test.sh
```

## Result
The mutation is caught: the event-bus unit test fails because concurrent emits
are no longer serialized, producing malformed or missing JSONL lines that fail
the JSON-validity and event-count assertions.
