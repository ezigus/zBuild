# CLI Reference

The `zbuild` command-line tool is the main way you interact with zBuild. You use it to start pipelines, resume interrupted runs, check status, and maintain your installation.

**Basic pattern:** `zbuild <command> [args…]`

Run `zbuild --help` at any time for a built-in summary.

---

## Start here — the everyday commands

If you're new to zBuild, these five commands cover most of what you'll do day-to-day:

1. **Start a pipeline on a GitHub issue:**
   ```
   zbuild pipeline start --issue 42
   ```

2. **Start a pipeline with a plain-text goal:**
   ```
   zbuild pipeline start --goal "Add pagination to the search results page"
   ```

3. **Resume a pipeline that was interrupted:**
   ```
   zbuild --resume-latest
   ```

4. **Check the status of the current pipeline:**
   ```
   zbuild status
   ```

5. **Validate your installation (run this if something seems broken):**
   ```
   zbuild doctor
   ```

---

## Session shortcuts

These flags can be used directly without a subcommand:

| Flag | What it does |
|---|---|
| `zbuild --resume <run_id>` | Resume a specific interrupted run (shorthand for `pipeline resume --run-id <id>`) |
| `zbuild --resume-latest` | Resume the most recent interrupted run |
| `zbuild --attach <run_id>` | Follow live output (`events.jsonl`) for a running pipeline, filtered to that run |

---

## Commands

### `pipeline start`

Start a new pipeline run. You must provide either `--issue` or `--goal`.

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

- `--issue <N>` — run the pipeline against GitHub issue number N.
- `--goal "<text>"` — run the pipeline against a free-text goal (use this if you don't have a GitHub issue).
- `--dry-run` — plan and evaluate without making any changes to files or branches.
- `--scope <path>` — add an allowed path for file access (see [[mechanics/scope-governance]]). Repeatable.
- `--mcp-server`, `--mcp-transport`, `--mcp-timeout` — configure MCP (Model Context Protocol) connections. These export `ZBUILD_MCP_SERVERS`, `ZBUILD_MCP_TRANSPORT`, and `ZBUILD_MCP_TIMEOUT` respectively.

### `pipeline resume`

Resume the most recent interrupted or in-progress run, or a specific run by id.

```
zbuild pipeline resume [--run-id <id>] [--from-stage <stage>] [--force]
```

- `--run-id <id>` — target a specific run (omit to resume the most recent).
- `--from-stage <stage>` — restart from a specific stage instead of where the run left off.
- `--force` — override an abort status and resume anyway.

### `pipeline status`

Show the resume recommendation for the current (or specified) state file.

```
zbuild pipeline status [--run-id <id>]
```

### `cleanup`

Prune stale artifacts left behind by previous runs: old branches, state files, git stashes, temp directories, and worktree orphans.

**Default behavior: dry-run, all categories.** Nothing is deleted unless you pass `--apply` or `--force`.

```
zbuild cleanup [--branches] [--state-dirs] [--stashes] [--tmpdirs]
               [--dry-run|--apply|--force]
               [--age-days N]   (state files; default 14)
               [--age-hours N]  (stashes + tmpdirs; default 1)
               [--restore-stash <N> --apply]
               [--quiet]
```

### Other commands

| Command | Purpose |
|---|---|
| `zbuild status` | Pipeline status (JSON) |
| `zbuild doctor` | Validate install + config (checks bash≥5, gh, jq, sqlite3, and more) |
| `zbuild plugin list` | List all discovered plugins |
| `zbuild deferred <sub>` | Deferred-work scanners (`backfill` \| `tracker`). Run `zbuild deferred --help`. |
| `zbuild manifest <sub>` | Manifest YAML drift management (`sync`). Run `zbuild manifest --help`. |
| `zbuild upgrade --from <dir>` | Re-run `install.sh` from a source clone (pulls `main` first) |
| `zbuild --version`, `version` | Print version — semver from `config/VERSION`; sha/branch from install metadata when set |
| `zbuild --help`, `help`, `-h` | Show help |

---

## Exit codes

`0` means success. Any non-zero value indicates failure.

The engine also uses internal signal codes between pipeline stages — for example, a route-back signal (rc=11) or a blocking-gate halt. See [[Troubleshooting]] and [[mechanics/event-bus]] for how to read what happened when something non-obvious occurs.
