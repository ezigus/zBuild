# Getting Started

This walks through your first run. It assumes you've completed [[Installation]] and are inside a git repository you want zBuild to work on.

## 1. A dry run (no changes)
Start with a goal and `--dry-run` — this exercises the pipeline without writing code or opening a PR:

```bash
zbuild pipeline start --goal "Add an e2e test for the checkout flow" --dry-run
```

What happens:
- the engine loads a template (default `simple`) and walks its stages;
- each stage's model calls pass through the [[mechanics/redaction-chokepoint]];
- progress is written as events — tail them with `zbuild --attach <run_id>`, or read `~/.zbuild/state/runs/<run_id>/events.jsonl`.

## 2. A real run from an issue
Point zBuild at a GitHub issue; it plans, builds, tests, reviews, and opens a PR:

```bash
zbuild pipeline start --issue 42
```

Useful flags:
- `--scope src/payment --scope tests/` — limit what the run may touch (repeatable).
- `--platform-override <p>` — override platform detection.
- `--no-resume` — start fresh instead of resuming an interrupted run.

## 3. If a run is interrupted
```bash
zbuild --resume-latest            # resume the most recent run
zbuild --resume <run_id>          # resume a specific run
zbuild pipeline status            # what would resume, and from where
```

## 4. Inspect
```bash
zbuild status                     # pipeline status
zbuild --attach <run_id>          # live-tail a running pipeline's events
```

Next: [[Configuration]] to choose models/templates, [[Pipeline-and-Stages]] to understand the flow, and [[CLI-Reference]] for every command.
