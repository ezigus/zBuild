## File
`core/event-bus/event-bus.sh` — `eb_emit_event` constructs an event envelope and writes it to the JSONL log. Omitting the `type` field from the envelope breaks the structured event contract: consumers that read `.type` see null/empty, causing any filter or assertion on event type to fail silently.

## Mutation
Drop the `type` field from the envelope the shell writes for a plain-ASCII event (nearly every event since ADR-065 round 5; other bytes still go through `jq`), so the emitted JSONL object has no `type` field.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/event-bus/event-bus.sh")
src = p.read_text()
new = src.replace(
    '''        _eb_json_str_v _j "$type";   event_json+=",\\"type\\":$_j"\n''',
    "",
    1,
)
assert new != src, "patch did not match the shell-written type field"
p.write_text(new)
PY
```

## Expected failing test
`tests/unit/core-event-bus-test.sh` — asserts `assert_eq "event has type=pipeline.start" "pipeline.start" "$type_field"`. With the mutation the emitted JSON has no `type` key, `jq -r .type` returns `null`, and the equality check fails.

## Test
```bash
bash tests/unit/core-event-bus-test.sh
```

## Result
The mutation is caught: the event-bus unit test fails at the `type` field assertion because `jq -r .type` returns `null` instead of `pipeline.start`.
