# Troubleshooting

## First: run doctor
```bash
zbuild doctor
```
Validates prerequisites and config (bash ≥ 5, `gh`, `jq`, `sqlite3`, etc.). Fix anything it flags before debugging a run.

## Common issues
- **`command not found: zbuild`** — `~/.local/bin` isn't on `PATH`. Add `export PATH="$HOME/.local/bin:$PATH"`.
- **Bash version error** — macOS `/bin/bash` is 3.2; install Bash 5 (`brew install bash`) and ensure it's first on `PATH`.
- **Timeouts "silently" not firing (macOS)** — install `coreutils` (provides `gtimeout`); see [[Installation]].
- **`flock` missing** — required for the local-fs claim backend (`brew install flock` / `apt install util-linux`).

## Inspect a run
- **Live tail:** `zbuild --attach <run_id>`.
- **Event log:** `~/.zbuild/state/runs/<run_id>/events.jsonl` — every `pipeline.*`, `stage.*`, `plugin.*`, `model.*`, `cycle.*`, `redaction.*` event. See [[mechanics/event-bus]].
- **State:** `~/.zbuild/state/runs/<run_id>/pipeline-state.json` (a `latest` symlink points at the newest run).

## Resume an interrupted run
```bash
zbuild pipeline status         # what would resume, and from where
zbuild --resume-latest         # resume the newest run
zbuild --resume <run_id>       # resume a specific run
zbuild pipeline resume --run-id <id> --force   # override an abort status
```

## Clean up stale artifacts
```bash
zbuild cleanup                 # dry-run: stale branches/state/stashes/tmpdirs
zbuild cleanup --apply         # actually prune
```

## A cycle didn't converge
Cycles are bounded; on hitting the max they follow `on_max` (often `continue`). Look for `cycle.plateau` / `cycle.stalled` / `cycle.unconverged` events to see why. See [[mechanics/convergence]].
