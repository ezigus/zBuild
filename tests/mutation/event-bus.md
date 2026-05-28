## File
`core/event-bus/event-bus.sh` — `eb_emit_event` constructs an event envelope and writes it to the JSONL log. Omitting the `type` field from the envelope breaks the structured event contract: consumers that read `.type` see null/empty, causing any filter or assertion on event type to fail silently.

## Mutation
Remove the `--arg type "$type"` binding and its usage from the `jq -cn` event-envelope constructor so the emitted JSONL object has no `type` field.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/event-bus/event-bus.sh")
src = p.read_text()
new = src.replace(
    '        --arg type "$type" \\\n',
    "",
    1,
).replace(
    "'{ts: $ts, run_id: $run_id, issue: $issue, type: $type, plugin: $plugin, kind: $kind, data: $data, schema_version: 1}'",
    "'{ts: $ts, run_id: $run_id, issue: $issue, plugin: $plugin, kind: $kind, data: $data, schema_version: 1}'",
    1,
)
assert new != src, "patch did not match the jq type-field binding"
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
