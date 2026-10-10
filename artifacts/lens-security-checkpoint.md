# Security lens checkpoint

## Files read
- core/router/route.sh lines 1280-1334 (_route_call_claude sync path, token extraction, _route_emit_outcome)
- core/router/route.sh lines 880-940 (_route_emit_model_route)
- core/router/route.sh lines 2300-2380 (loop success block, new insertions)
- core/event-bus/event-bus.sh lines 124-203 (eb_emit_event implementation)
- diff.patch (full diff)
- tests/integration/router-loop-emits-model-events-test.sh (new test)

## Key facts established
- `$json_file` is mktemp-created (line 1906); not user-controlled
- `eb_emit_event` uses `jq --arg k "$key" --arg v "$val"` to build the payload — values are safely JSON-encoded regardless of content
- New jq extractions for cache tokens mirror sync-path pattern (lines 1306-1307) exactly
- `|| echo 0` fallback is same pattern as sync path; no SIGPIPE (no pipe from echo)
- test: `| wc -l | tr -d ' '` is safe (both readers consume all input); `| tail -1` is safe (tail reads all input)
- No `| grep -q` or `| head` antipatterns in new code
- No credentials, secrets, or sensitive LLM text flows through the new emit calls
- ZBUILD_* env vars are engine-trusted (per repo facts)

## Conclusions
- No injection vectors: jq --arg escapes all LLM-sourced values
- No path traversal: json_file is mktemp'd
- No credential exposure: model.route/outcome carry metadata, not secrets
- One low pre-existing-pattern finding: cache token values from LLM response are unvalidated integers before placement in shell variables, but safely handled by jq --arg. Consistent with sync path. Introduced=true (loop path didn't do this before), severity low.

## Status: complete, ready to emit JSON
