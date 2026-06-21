# Mutation: ANSI stripping in event-bus emit

## What to mutate

In `core/event-bus/event-bus.sh`, comment out the `_eb_strip_ansi` call sites inside
`eb_emit_event` so raw ANSI bytes reach the JSONL writer.

### Payload value call site

```bash
# Before mutation (working):
val="$(_eb_strip_ansi "${arg#*=}")"

# After mutation (broken):
# val="$(_eb_strip_ansi "${arg#*=}")"
val="${arg#*=}"
```

### Envelope field call sites

```bash
# Before mutation (working):
local run_id; run_id="$(_eb_strip_ansi "${ZBUILD_RUN_ID:-}")"
local plugin; plugin="$(_eb_strip_ansi "${ZBUILD_PLUGIN:-}")"
local kind; kind="$(_eb_strip_ansi "${ZBUILD_PLUGIN_KIND:-}")"

# After mutation (broken):
local run_id="${ZBUILD_RUN_ID:-}"
local plugin="${ZBUILD_PLUGIN:-}"
local kind="${ZBUILD_PLUGIN_KIND:-}"
```

## Expected failing test

`tests/unit/event-bus-ansi-strip-test.sh`

With the mutation applied, ANSI escape sequences reach the JSONL writer. The
`[SPEC-1]` assertion comparing `.data.output` to `"green"` fails because the
actual value is `$'\e[32mgreen\e[0m'`. The `[SPEC-2]` assertions on `.plugin`,
`.run_id`, and `.kind` similarly fail. The no-ESC-bytes assertion also fails.

## Why this mutation matters

The `_eb_strip_ansi` call is not decorative — without it, any caller that
passes ANSI-coloured output (e.g. from a subprocess or LLM stream) embeds raw
ESC bytes in the JSONL record. Downstream consumers (`jq`, SQLite grep tools,
dashboards) see corrupt JSON string values or terminal control codes injected
into log output. This mutation test proves the call sites are load-bearing.
