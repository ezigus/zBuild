# event bus

Every meaningful thing a run does is emitted as a **structured event**, giving you a complete, replayable trace.

- **Dual sink:** events are written to SQLite (queryable) and `events.jsonl` (streamable/tailable).
- **Schema-validated, warn-not-block:** known event types are enumerated in `config/event-schema.json`; unknown types are logged but never block a run. New emitted events must be added to the schema.
- **What you'll see:** `pipeline.*`, `stage.*`, `plugin.*`, `model.route` / `model.outcome`, `cycle.*`, `redaction.*`, `claim.*`, and more.
- **Tail a live run:** `zbuild --attach <run_id>`.

See [[mechanics/state-and-resume]], [[Troubleshooting]], [[Architecture]].
