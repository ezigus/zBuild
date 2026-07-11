# CLI Reference

`zbuild <command> [args…]`. Run `zbuild --help` for the built-in summary.

## Session shortcuts
| Flag | Meaning |
|---|---|
| `zbuild --resume <run_id>` | Resume a specific interrupted run (shorthand for `pipeline resume --run-id <id>`). |
| `zbuild --resume-latest` | Resume the most recent interrupted run. |
| `zbuild --attach <run_id>` | Tail (`events.jsonl`) for a running pipeline, filtered to that run. |

## Commands
### `pipeline start`
Start a pipeline.
```
zbuild pipeline start --issue <N> | --goal "<text>"
                      [--dry-run]
                      [--platform-override <p>]
                      [--scope <path>]...        (repeatable; validated: no absolute, no ..)
                      [--no-resume]
                      [--mcp-server <url>]...     (repeatable)
                      [--mcp-transport stdio|sse]
                      [--mcp-timeout <seconds>]
```
- `--issue <N>` / `--goal "<text>"` — pick one: a GitHub issue or a free-text goal.
- `--dry-run` — run without making changes.
- `--scope <path>` — add an allowed path (see [[mechanics/scope-governance]]).
- MCP flags export `ZBUILD_MCP_SERVERS` (newline-delimited), `ZBUILD_MCP_TRANSPORT`, `ZBUILD_MCP_TIMEOUT`.

### `pipeline resume`
```
zbuild pipeline resume [--run-id <id>] [--from-stage <stage>] [--force]
```
Resume the most recent (or a specified) interrupted/in-progress run. `--force` overrides an abort status.

### `pipeline status`
```
zbuild pipeline status [--run-id <id>]
```
Show the resume recommendation for the current (or specified) state file.

### `cleanup`
```
zbuild cleanup [--branches] [--state-dirs] [--stashes] [--tmpdirs]
               [--dry-run|--apply|--force]
               [--age-days N]   (state files; default 14)
               [--age-hours N]  (stashes + tmpdirs; default 1)
               [--restore-stash <N> --apply]
               [--quiet]
```
Prune stale `zbuild/issue-*` branches, old state files, `zb-applycheck-*` stashes, leaked tmpdirs, and worktree orphans. **Default: dry-run, all categories.**

### Other commands
| Command | Purpose |
|---|---|
| `zbuild status` | Pipeline status (JSON). |
| `zbuild doctor` | Validate install + config (bash≥5, gh, jq, sqlite3, …). |
| `zbuild plugin list` | List discovered plugins. |
| `zbuild deferred <sub>` | Deferred-work scanners (`backfill` \| `tracker`). Run `zbuild deferred --help`. |
| `zbuild manifest <sub>` | Manifest YAML drift management (`sync`). Run `zbuild manifest --help`. |
| `zbuild upgrade --from <dir>` | Re-run `install.sh` from a source clone (pulls `main` first). |
| `zbuild --version`, `version` | Print version (reads `$ZBUILD_HOME/version` when set). |
| `zbuild --help`, `help`, `-h` | Show help. |

## Exit codes
`0` success; non-zero indicates failure. The engine also uses internal signal codes between stages (e.g. route-back, blocking-gate halt) — see [[Troubleshooting]] and the [[mechanics/event-bus]] for how to read what happened.
