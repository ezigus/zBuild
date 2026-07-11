# state & resume

Runs are **atomic and crash-safe**: state is persisted as it advances, so an interrupted run resumes where it stopped. (ADR-006)

- **Layout:** per-run state lives under `~/.zbuild/state/runs/<run_id>/` (with a `latest` pointer); events in `events.jsonl`.
- **Persisted vs reconstructed:** some state is persisted (advances the pipeline); some is reconstructed on resume (e.g. a git diff). Each plugin declares which in its manifest `state:` block.
- **Resume:** `zbuild pipeline resume [--run-id <id>]`, or the shortcuts `zbuild --resume <id>` / `--resume-latest`. `zbuild --attach <id>` tails a live run's events.
- **Isolation (#887):** runs are rooted per-run by default so concurrent runs don't collide.

See [[CLI-Reference]], [[mechanics/event-bus]], [[Troubleshooting]].
